import Foundation
import NitsCore

/// What a timeline bar spans now: the media's duration, or a live stream's window. Shared by the control bar's timeline
/// and the mini player's progress bar, so both map the bar to the same times.
struct TimelineSpan {
    /// The live stream's window now; `nil` for other media.
    let liveWindow: LiveWindow?
    let start: Double
    let length: Double

    @MainActor
    init(engine: PlayerEngine) {
        liveWindow = engine.live.isLive ? engine.live.window() : nil
        start = liveWindow?.start ?? 0
        length = liveWindow?.length ?? engine.media.duration
    }

    /// The time at `ratio` (0…1) of the bar.
    func time(atRatio ratio: Double) -> Double {
        start + min(max(ratio, 0), 1) * max(length, 0)
    }

    /// Where `time` falls on the bar, 0…1; 0 while there is nothing to span.
    func ratio(of time: Double) -> Double {
        guard length > 0 else { return 0 }
        return min(max((time - start) / length, 0), 1)
    }

    /// The position as the bar's label reads it: the time, or how far behind the live edge a live stream's picture is
    /// (0:00 at the edge, unless `isDragging`: then it shows where the drop lands, near the edge too).
    @MainActor
    func positionText(_ position: Double, engine: PlayerEngine, isDragging: Bool = false) -> String {
        guard let window = liveWindow else { return TimeParser.format(seconds: position) }
        // A stream that ended is a recording: the time into it.
        if window.hasEnded { return TimeParser.format(seconds: max(0, position - window.start)) }
        if !isDragging && engine.live.isAtEdge(position) { return "0:00" }
        return "−" + TimeParser.format(seconds: engine.live.secondsBehindEdge(at: position))
    }
}
