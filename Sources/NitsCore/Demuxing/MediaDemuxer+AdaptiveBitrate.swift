import Foundation

/// Adaptive bitrate for HLS while reading ahead (`AdaptiveBitrateLogic` decides). The requests go through
/// `HTTPSessionTransport`, whose meter measures each one's transfer apart from its answer: the read-ahead thread feeds
/// the logic those, and the latency and media of its reads. The switch it asks for is spliced like a manual one
/// (`MediaDemuxer+Variants.swift`), at the read position.
extension MediaDemuxer {
    /// What the read-ahead thread measures and decides with: the read-ahead thread's alone from its start on (behind
    /// `lock` and `queueLock` there).
    struct AdaptiveBitrateState {
        /// Set up by `startReadAhead` for its limit.
        var logic = AdaptiveBitrateLogic()
        var nextDecision = 0.0
        /// `adaptiveTime` the read-ahead thread last waited at the live edge, for a playlist reload.
        var liveEdgeReachedAt: Double?
        let epoch = ContinuousClock.now
    }

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
        (ContinuousClock.now - adaptiveBitrate.epoch) / .seconds(1)
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
        /// `NetworkTransferMeter.oneTimeWaitSeconds`.
        let oneTimeWaits: Double
    }

    /// Behind `lock` and `queueLock`.
    var readMark: ReadMark {
        ReadMark(
            bytes: ioBytes.total, openSeconds: ioBytes.openSeconds, readAhead: readAheadState.withLock { $0 },
            isSwitchingVariant: variantSwitch != nil,
            oneTimeWaits: ioBytes.transport?.meter.oneTimeWaitSeconds ?? 0)
    }

    /// A read of the read-ahead thread from `mark` on. Behind `lock` and `queueLock`.
    ///
    /// The transfers are the requests' own (`NetworkTransferMeter`), a sample each, whatever the read waited for:
    /// weighed by the media their bytes are at the variant's bandwidth, so a segment's counts by its share of the
    /// stream (an audio segment's, a twentieth of a 4K video one's), slow or not, and the first estimate waits for a
    /// second of the variant's media measured.
    ///
    /// The time the read spent opening inputs is the requests' latency (connection, TLS, the server's answer, which a
    /// CDN fetching from its origin takes most of a second for), not the link's rate. It is measured apart, per second
    /// of media read (`AdaptiveBitrateLogic.latencyShare`), which holds for every variant: a server slower to answer
    /// than the segments last still brings the variant down. Not the answers paid once
    /// (`HTTPSessionTransport.oneTimeRequestBytes`), nor while a variant switch catches the new variant up, from the
    /// start of a segment to the splice: a cost of the switch, read without media, not of the variant.
    ///
    /// A live stream read up to its edge waits for the next segment: FFmpeg sleeps inside the read, reloading the
    /// playlist, until it lists one. The wait counts as a full read-ahead instead (`adaptBitrateIfDue`), which a live
    /// stream never reaches otherwise: the edge is a few segments ahead of playback. The reloads while waiting are no
    /// cost of reading: only the segment's request, after them in the same read, counts. Of a stream with a duration,
    /// a long read without data is the network failing.
    func noteRead(from mark: ReadMark) {
        guard let meter = ioBytes.transport?.meter else { return }
        let media = max(readAheadState.withLock { $0 } - mark.readAhead, 0)
        let countsLatency = !mark.isSwitchingVariant && variantSwitch == nil
        let edgeOpen = ioBytes.lastOpen.flatMap { opened in
            durationSeconds <= 0 && opened.asked > mark.time
                && Self.isLiveEdgeWait(
                    bytes: Int(opened.total - mark.bytes),
                    seconds: (opened.asked - mark.time) / .seconds(1) - (opened.openSeconds - mark.openSeconds))
                ? opened : nil
        }
        if edgeOpen != nil { adaptiveBitrate.liveEdgeReachedAt = adaptiveTime }
        let oneTime = meter.oneTimeWaitSeconds - mark.oneTimeWaits
        let opened = ioBytes.openSeconds - (edgeOpen?.openSeconds ?? mark.openSeconds)
        let latency = edgeOpen != nil ? opened : max(opened - oneTime, 0)
        adaptiveBitrate.logic.addLatency(countsLatency ? latency : 0, media: media.isFinite ? media : 0)
        let transfers = meter.take()
        guard !transfers.isEmpty else { return }
        // While a switch catches the new variant up, what comes is the new variant's.
        let selected = variantSwitch?.target.id ?? variantSelection.withLock { $0.selected }
        let bandwidth = variants.first { $0.id == selected }.map { Double($0.bandwidth) } ?? 0
        for transfer in transfers {
            adaptiveBitrate.logic.addSample(
                bytes: transfer.bytes, seconds: transfer.seconds,
                media: bandwidth > 0 ? Double(transfer.bytes) * 8 / bandwidth : 0, at: adaptiveTime)
        }
    }

    /// Asks for the variant `AdaptiveBitrateLogic` chooses, every `decisionInterval`. Behind `lock` and `queueLock`.
    func adaptBitrateIfDue() {
        let now = adaptiveTime
        guard now >= adaptiveBitrate.nextDecision, variants.count > 1, variantSwitch == nil, !readAheadEnded else {
            return
        }
        adaptiveBitrate.nextDecision = now + Self.decisionInterval
        let selection = variantSelection.withLock { $0 }
        guard selection.isAutomatic, selection.requested == nil, let current = selection.selected else { return }
        var readAhead = readAheadState.withLock { $0 } - consumedSeconds
        guard readAhead.isFinite else { return }
        if let edge = adaptiveBitrate.liveEdgeReachedAt, now - edge <= Self.liveEdgeMemory {
            readAhead = max(readAhead, adaptiveBitrate.logic.config.highBuffer)
        }
        let ladder = variants.filter(\.isSwitchable).map {
            AdaptiveBitrateLogic.Variant(id: $0.id, bandwidth: $0.bandwidth)
        }
        guard let chosen = adaptiveBitrate.logic.choose(current: current, among: ladder, readAhead: readAhead, at: now)
        else { return }
        let estimate = adaptiveBitrate.logic.estimate.map { "\(Int($0 / 1000)) kbit/s" } ?? "none"
        let latency = adaptiveBitrate.logic.latencyShare.map { "\(Int($0 * 1000)) ms/s" } ?? "none"
        AppLog.info(
            .demuxer,
            "ABR: read-ahead \(String(format: "%.1f", readAhead)) s, throughput \(estimate), latency \(latency)")
        variantSelection.withLock { $0.requested = chosen }
    }
}
