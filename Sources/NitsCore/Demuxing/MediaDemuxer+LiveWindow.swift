import Foundation

/// The part of a live HLS stream that can be played: from the first segment its playlist lists to the end of the last,
/// in seconds on the timeline of the packets. Both ends move with real time, as the playlist slides.
public struct LiveWindow: Equatable, Sendable {
    /// Start of the oldest segment listed: the farthest back a seek goes.
    public var start: Double
    /// End of the newest segment listed: the live edge.
    public var end: Double
    /// The playlist had slid when it was read (its first segment is not the stream's first): its start moves on with
    /// time, from the first load on. One that grows from the beginning of the stream keeps its start until it slides.
    public var hasSlid: Bool
    /// The playlist ended (`EXT-X-ENDLIST`): this is its last window, a recording that no longer grows or slides.
    public var hasEnded: Bool

    public init(start: Double, end: Double, hasSlid: Bool = false, hasEnded: Bool = false) {
        self.start = start
        self.end = end
        self.hasSlid = hasSlid
        self.hasEnded = hasEnded
    }

    public var length: Double { end - start }
}

/// A window and when the playlist it is of was loaded: the demuxer, which reads on, tells it at its leisure.
public struct LiveReport: Equatable, Sendable {
    public var window: LiveWindow
    public var loadedAt: ContinuousClock.Instant
}

extension MediaDemuxer {
    /// Publishes the window the input tells of its live playlist (`DemuxerInput.liveWindow()`). On the thread that reads:
    /// the input reloads the playlist inside its reads. Once the playlist ended the last window stays, marked so; for a
    /// stream that was never live there is none.
    func publishLiveWindow() {
        guard let window = input.liveWindow() else { return }
        // Called after every packet: the time stays that of the first read that saw the window, which is the load's
        // (the playlist is reloaded inside the read), not that of the last packet.
        liveWindowState.withLock { state in
            if state?.window != window { state = LiveReport(window: window, loadedAt: .now) }
        }
    }

    /// The window of a live stream's history after the gate found something (`LiveSegmentGate.Change`): the end further on,
    /// or the end of the stream. The start has slid since the report was told, as the engine slides it (by the time that
    /// has passed, `LiveStream.window`); a window told again with the start it began with would take the slide back to the
    /// first load, and let a seek into segments the server has dropped.
    static func applying(
        _ change: LiveSegmentGate.Change, to report: LiveReport, origin: Double, now: ContinuousClock.Instant
    ) -> LiveReport {
        var window = report.window
        if window.hasSlid { window.start += max(0, (now - report.loadedAt) / .seconds(1)) }
        switch change {
        case .headAdvanced(let head):
            window.end = max(window.end, head.startTime + LiveSegmentGate.nominalSegmentDuration - origin)
        case .ended(_, let endTime):
            window.end = max(window.end, endTime - origin)
            window.hasEnded = true
        }
        window.start = min(window.start, window.end)
        return LiveReport(window: window, loadedAt: now)
    }
}
