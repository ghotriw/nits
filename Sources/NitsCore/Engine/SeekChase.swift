/// The position a seek, or a burst of them, is chasing: the latest one asked for. A burst's seeks that come while one
/// runs on `seekQueue` only move it; the running one then goes on to it (Apple QA1820 / mpv `queue_seek`).
struct ChaseTarget: Equatable {
    var seconds: Double
    var exact: Bool
    /// Keyframe-seek direction: forward seeks land on the next keyframe at/after the target.
    var forward: Bool
    /// A forward frame step: the frame landed on must be at or past it, so the step advances (`SeekPreview`).
    var minFramePTS: Double?

    /// The target once the seek landed at `seconds`, waiting there to resume: no frame step to complete any more.
    func landed(at seconds: Double) -> ChaseTarget {
        ChaseTarget(seconds: seconds, exact: exact, forward: forward, minFramePTS: nil)
    }
}

/// A run of relative seeks in quick succession (a held or repeated arrow key). Its first seek may be exact
/// (`exactSeekOnSinglePress`), the rest go keyframe to keyframe; each lands reports how far the run has moved.
struct RelativeSeekBurst {
    /// One of its seeks hasn't landed yet.
    private(set) var isInFlight = false
    /// Where the burst started: the position its offset is reported from. `nil` before its first seek.
    private(set) var startTime: Double?

    /// A relative seek from `baseTime`; returns whether it starts the burst.
    mutating func press(at baseTime: Double) -> Bool {
        let isFirst = startTime == nil
        if isFirst {
            startTime = baseTime
        }
        isInFlight = true
        return isFirst
    }

    /// The seek in flight landed (or was dropped); returns whether one was in flight.
    @discardableResult
    mutating func seekLanded() -> Bool {
        defer { isInFlight = false }
        return isInFlight
    }

    /// How far a seek landing at `seconds` has moved from the burst's start, if there is a burst.
    func offset(landingAt seconds: Double) -> Double? {
        startTime.map { seconds - $0 }
    }
}
