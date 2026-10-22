import CFFmpeg
import Foundation

/// Adaptive bitrate for HLS while reading ahead (`AdaptiveBitrateLogic` decides). The read-ahead thread measures the
/// throughput: FFmpeg's HLS demuxer downloads segments inside `av_read_frame`, so a read that waits on the network
/// transfers at its rate. Reads served from what the socket buffered while the thread idled return at once and would
/// count at memory speed: measuring starts with the first read that waits (`networkWait`) after an idle spell and
/// runs while the thread keeps reading. The switch it asks for is spliced like a manual one
/// (`MediaDemuxer+Variants.swift`), at the read position.
extension MediaDemuxer {
    /// Transfer of the current reading spell, behind `lock`.
    struct TransferWindow {
        /// A read waited on the network during this spell.
        var isNetworkBound = false
        var bytes = 0
        var seconds = 0.0
    }

    /// A read taking this long waited on the network.
    static let networkWait = 0.002
    /// Seconds of transfer per throughput sample.
    static let sampleSeconds = 0.5
    /// Seconds between decisions.
    static let decisionInterval = 0.5

    /// Whether the variant follows the network (the default for a stream with variants). `selectVariant(id:)` turns
    /// it off; it only acts while reading ahead.
    public var isAdaptiveBitrateEnabled: Bool {
        variantSelection.withLock { $0.isAutomatic }
    }

    public func setAdaptiveBitrate(_ enabled: Bool) {
        variantSelection.withLock { $0.isAutomatic = enabled }
    }

    var adaptiveTime: Double {
        (ContinuousClock.now - adaptiveEpoch) / .seconds(1)
    }

    /// A read of a live stream this long, at most this many bits a second, waited at the live edge: FFmpeg's HLS
    /// demuxer sleeps inside `av_read_frame` until the playlist it reloads lists a new segment (up to a segment's
    /// length), and downloads only the playlist meanwhile.
    static let liveEdgeWait = (seconds: 0.5, bitsPerSecond: 16_000.0)
    /// Seconds a wait at the live edge counts as a full read-ahead for.
    static let liveEdgeMemory = 10.0

    static func isLiveEdgeWait(bytes: Int, seconds: Double) -> Bool {
        seconds >= liveEdgeWait.seconds && Double(bytes) * 8 / seconds < liveEdgeWait.bitsPerSecond
    }

    /// Where a read of the read-ahead thread starts: `ioBytes`' totals, and how far reading had got.
    struct ReadMark {
        let time = ContinuousClock.now
        let bytes: Int64
        let openSeconds: Double
        let readAhead: Double
        let isSwitchingVariant: Bool
    }

    /// Behind `lock` and `queueLock`.
    var readMark: ReadMark {
        ReadMark(
            bytes: ioBytes.total, openSeconds: ioBytes.openSeconds, readAhead: readAheadState.withLock { $0 },
            isSwitchingVariant: variantSwitch != nil)
    }

    /// A read of the read-ahead thread from `mark` on. Behind `lock` and `queueLock`.
    ///
    /// The time it spent opening inputs is the requests' latency (connection, TLS, the server's answer, which a CDN
    /// fetching from its origin takes most of a second for), not the link's rate: counted as transfer it capped the
    /// estimate at a segment's size over it, so the low variants' small segments measured a fraction of the network,
    /// and a start on a cold cache next to nothing. It is measured apart instead, per second of media read
    /// (`AdaptiveBitrateLogic.latencyShare`), which holds for every variant: a server slower to answer than the
    /// segments last still brings the variant down. Not while a variant switch catches the new variant up, from the
    /// start of a segment to the splice: a cost of the switch, read without media, not of the variant.
    ///
    /// A live stream read up to its edge waits for the next segment, which is neither: counted, it would bring the
    /// estimate down to nothing. The wait comes before the read asks for that segment, but for the playlist reloads
    /// it took (a few hundred bytes, after a request's latency of their own); the segment's request and transfer
    /// after, in the same read. The wait counts as a full read-ahead instead (`adaptBitrateIfDue`), which a live
    /// stream never reaches otherwise: the edge is a few segments ahead of playback. Of a stream with a duration, a
    /// long read without data is the network failing, and counts.
    func noteRead(from mark: ReadMark) {
        let end = ContinuousClock.now
        let bytesAfter = ioBytes.total
        let media = max(readAheadState.withLock { $0 } - mark.readAhead, 0)
        let countsLatency = !mark.isSwitchingVariant && variantSwitch == nil
        if durationSeconds <= 0, let opened = ioBytes.lastOpen, opened.asked > mark.time,
            Self.isLiveEdgeWait(
                bytes: Int(opened.total - mark.bytes),
                seconds: (opened.asked - mark.time) / .seconds(1) - (opened.openSeconds - mark.openSeconds))
        {
            liveEdgeReachedAt = adaptiveTime
            transferWindow.isNetworkBound = false
            // The reloads while waiting are no cost of reading: only the segment's request counts.
            noteTransfer(
                bytes: Int(bytesAfter - opened.total), seconds: (end - opened.opened) / .seconds(1),
                latency: countsLatency ? ioBytes.openSeconds - opened.openSeconds : 0, media: media)
            return
        }
        let opening = ioBytes.openSeconds - mark.openSeconds
        noteTransfer(
            bytes: Int(bytesAfter - mark.bytes), seconds: max((end - mark.time) / .seconds(1) - opening, 0),
            latency: countsLatency ? opening : 0, media: media)
    }

    /// `bytes` came in `seconds` of a read's transfer, past its requests' `latency`, and `media` seconds were read. The
    /// latency counts for every read: reads served from what the socket buffered read media too, whose requests waited
    /// before. Only the transfer tells a wait on the network: a request answered, the media read may still come from
    /// what the socket buffered (a playlist reloaded, then the segment read on).
    private func noteTransfer(bytes: Int, seconds: Double, latency: Double, media: Double) {
        adaptiveBitrate.addLatency(latency, media: media.isFinite ? media : 0)
        if seconds >= Self.networkWait { transferWindow.isNetworkBound = true }
        guard transferWindow.isNetworkBound else { return }
        transferWindow.bytes += bytes
        transferWindow.seconds += seconds
        if transferWindow.seconds >= Self.sampleSeconds {
            adaptiveBitrate.addSample(bytes: transferWindow.bytes, seconds: transferWindow.seconds, at: adaptiveTime)
            transferWindow = TransferWindow(isNetworkBound: true)
        }
    }

    /// The read-ahead thread stopped reading (at its limit or the end): the next spell starts on what the socket
    /// buffered meanwhile, which doesn't count until a read waits again. The window carries over: with the
    /// read-ahead near its limit, spells are short.
    func noteReadAheadIdle() {
        transferWindow.isNetworkBound = false
    }

    /// Asks for the variant `AdaptiveBitrateLogic` chooses, every `decisionInterval`. Behind `lock` and `queueLock`.
    func adaptBitrateIfDue() {
        let now = adaptiveTime
        guard now >= nextAdaptiveDecision, variants.count > 1, variantSwitch == nil, !readAheadEnded else { return }
        nextAdaptiveDecision = now + Self.decisionInterval
        let selection = variantSelection.withLock { $0 }
        guard selection.isAutomatic, selection.requested == nil, let current = selection.selected else { return }
        var readAhead = readAheadState.withLock { $0 } - consumedSeconds
        guard readAhead.isFinite else { return }
        var atLiveEdge = false
        if let edge = liveEdgeReachedAt, now - edge <= Self.liveEdgeMemory,
            readAhead < adaptiveBitrate.config.highBuffer
        {
            readAhead = adaptiveBitrate.config.highBuffer
            atLiveEdge = true
        }
        let ladder = variants.filter(\.isSwitchable).map {
            AdaptiveBitrateLogic.Variant(id: $0.id, bandwidth: $0.bandwidth)
        }
        guard
            let chosen = adaptiveBitrate.choose(
                current: current, among: ladder, readAhead: readAhead, atLiveEdge: atLiveEdge, at: now)
        else { return }
        let estimate = adaptiveBitrate.estimate.map { "\(Int($0 / 1000)) kbit/s" } ?? "none"
        let latency = adaptiveBitrate.latencyShare.map { "\(Int($0 * 1000)) ms/s" } ?? "none"
        AppLog.info(
            .demuxer,
            "ABR: read-ahead \(String(format: "%.1f", readAhead)) s, throughput \(estimate), latency \(latency)")
        variantSelection.withLock { $0.requested = chosen }
    }
}
