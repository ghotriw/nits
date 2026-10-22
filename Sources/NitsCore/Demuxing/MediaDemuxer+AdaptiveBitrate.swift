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

    /// A read of the read-ahead thread started at `start`, with `ioBytes.total` at `bytesBefore`. Behind `lock`.
    ///
    /// A live stream read up to its edge waits for the next segment, which is no transfer: counted, it would bring the
    /// estimate down to nothing. The wait comes before the read opens that segment (the playlist reloads it took are a
    /// few hundred bytes), and the segment's transfer after, in the same read: only what follows the opening counts.
    /// The wait counts as a full read-ahead instead (`adaptBitrateIfDue`), which a live stream never reaches otherwise:
    /// the edge is a few segments ahead of playback. Of a stream with a duration, a long read without data is the
    /// network failing, and counts.
    func noteRead(from start: ContinuousClock.Instant, bytesBefore: Int64) {
        let end = ContinuousClock.now
        let bytesAfter = ioBytes.total
        if durationSeconds <= 0, let opened = ioBytes.lastOpen, opened.time > start,
            Self.isLiveEdgeWait(bytes: Int(opened.total - bytesBefore), seconds: (opened.time - start) / .seconds(1))
        {
            liveEdgeReachedAt = adaptiveTime
            transferWindow.isNetworkBound = false
            noteTransfer(bytes: Int(bytesAfter - opened.total), seconds: (end - opened.time) / .seconds(1))
            return
        }
        noteTransfer(bytes: Int(bytesAfter - bytesBefore), seconds: (end - start) / .seconds(1))
    }

    /// `bytes` came in `seconds` of a read.
    private func noteTransfer(bytes: Int, seconds: Double) {
        if seconds >= Self.networkWait { transferWindow.isNetworkBound = true }
        guard transferWindow.isNetworkBound else { return }
        transferWindow.bytes += bytes
        transferWindow.seconds += seconds
        if transferWindow.seconds >= Self.sampleSeconds {
            adaptiveBitrate.addSample(bytes: transferWindow.bytes, seconds: transferWindow.seconds, at: adaptiveTime)
            transferWindow.bytes = 0
            transferWindow.seconds = 0
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
        if let edge = liveEdgeReachedAt, now - edge <= Self.liveEdgeMemory {
            readAhead = max(readAhead, adaptiveBitrate.config.highBuffer)
        }
        let ladder = variants.filter(\.isSwitchable).map {
            AdaptiveBitrateLogic.Variant(id: $0.id, bandwidth: $0.bandwidth)
        }
        guard let chosen = adaptiveBitrate.choose(current: current, among: ladder, readAhead: readAhead, at: now)
        else { return }
        let estimate = adaptiveBitrate.estimate.map { "\(Int($0 / 1000)) kbit/s" } ?? "none"
        AppLog.info(.demuxer, "ABR: read-ahead \(String(format: "%.1f", readAhead)) s, throughput \(estimate)")
        variantSelection.withLock { $0.requested = chosen }
    }
}
