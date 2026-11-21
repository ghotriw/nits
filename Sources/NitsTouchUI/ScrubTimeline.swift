#if os(iOS)
    import Foundation

    /// The span the scrub bar covers and where a time or a touch stands in it: the media's length, or for a live stream
    /// the window its playlist lists.
    struct ScrubTimeline: Equatable {
        var start: Double
        var end: Double

        init(duration: Double, liveWindow: (start: Double, end: Double)? = nil) {
            if let liveWindow {
                start = liveWindow.start
                end = max(liveWindow.end, liveWindow.start)
            } else {
                start = 0
                end = max(duration, 0)
            }
        }

        var length: Double { end - start }
        var isEmpty: Bool { !(length > 0) }

        /// Where `time` is, 0...1 (0 for an empty span).
        func fraction(of time: Double) -> Double {
            guard !isEmpty else { return 0 }
            return min(max((time - start) / length, 0), 1)
        }

        /// The time at `fraction` of the span, clamped into it.
        func time(at fraction: Double) -> Double {
            start + min(max(fraction, 0), 1) * length
        }

        /// `m:ss`, or `h:mm:ss` from an hour on; `--:--` for what is not a time.
        static func clock(_ seconds: Double) -> String {
            guard seconds.isFinite else { return "--:--" }
            let total = Int(max(seconds, 0).rounded(.down))
            let hours = total / 3600
            let minutes = total % 3600 / 60
            let secs = total % 60
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
        }
    }
#endif
