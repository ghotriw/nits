import Foundation

/// Turns the playback clock projected to the display link's target vsync into the time frames are picked for: with
/// the per-tick jitter filtered out, and phase-locked so frame boundaries stay clear of vsyncs.
///
/// The display link picks a frame once its PTS is within the lead window of the clock at the target vsync. When
/// content and link rates are not whole multiples (25 fps on 60 Hz), frame boundaries fall on a lattice of phases
/// against vsync (tick / 5 apart for 2.4 ticks per frame), and as the audio clock drifts against the display, a
/// lattice point passes right over a vsync every few tens of seconds. Read raw, the projected clock wobbles by about a
/// millisecond from tick to tick, so the frame at that point flips between two vsyncs for seconds at a time: shown a
/// tick late, the next one held a single tick.
///
/// Two stages fix that:
/// - **Smoothing.** In steady playback `content time − host time × rate` only drifts slowly, so it is low-pass
///   filtered. A step larger than any jitter (seek, clock restart, rate change, a gap in ticks) restarts the filter
///   from the raw value instead of easing towards it, and is reported. A stopped clock is returned raw.
/// - **Phase lock.** A small bias, added to the smoothed time, keeps the lattice centred between vsyncs: each pick
///   nudges it towards the centre, so it follows the drift. When it would exceed half a lattice step it moves by a
///   whole step, which shifts one frame boundary across a vsync once, cleanly. The bias is the only A/V offset this
///   adds: at most half a step (±1.7 ms for 25 fps on 60 Hz, ±8.3 ms for whole multiples on 60 Hz). It carries over
///   discontinuities: after one the clock's phase against vsync is arbitrary, so any bias, zero included, is as good a
///   start, and the lock re-centres the lattice within about a second.
struct DisplayClockSmoother: Sendable {
    /// Why the smoothed clock restarted from the raw one.
    enum Discontinuity: Sendable, Equatable, CustomStringConvertible {
        case rateChange(from: Double, to: Double)
        case tickGap(seconds: Double)
        case jump(seconds: Double)

        var description: String {
            switch self {
            case .rateChange(let from, let to):
                return "clock rate changed \(String(format: "%.2f", from))× → \(String(format: "%.2f", to))×"
            case .tickGap(let seconds):
                return "\(String(format: "%.0f", seconds * 1000)) ms without display-link ticks"
            case .jump(let seconds):
                return "clock jumped \(String(format: "%+.1f", seconds * 1000)) ms against the display"
            }
        }
    }

    /// Time constant of the offset filter: long enough to average out the jitter, short enough to follow clock drift
    /// (tens of ppm, microseconds per time constant).
    static let timeConstant: Double = 0.5
    /// An offset step beyond this is a clock discontinuity, not jitter.
    static let discontinuityThreshold: Double = 0.008
    /// A gap between ticks beyond this (paused link, hidden window) restarts the filter.
    static let maxTickGap: CFTimeInterval = 0.25
    /// Share of a pick's distance from the lattice centre corrected per pick (time constant ≈ 20 frames).
    static let phaseLockGain: Double = 0.05
    /// Lattices with more points than this (rates with no small common multiple) are not phase-locked: their points
    /// are too close together for a bias to keep any of them clear of vsyncs.
    static let maxLatticePoints = 12

    private var offset: Double?
    private var rate: Double = 0
    private var lastHostTime: CFTimeInterval = 0
    /// Content seconds added to the smoothed clock to keep frame boundaries centred between vsyncs.
    private(set) var phaseBias: Double = 0
    private var latticeStep: Double = 0

    /// Returns the time to pick frames for at `hostTime` (the target vsync), and the discontinuity that made it take
    /// the raw clock, if any.
    /// - Parameters:
    ///   - rawTime: The synchronizer clock projected to `hostTime`, in content seconds.
    ///   - rate: The clock's current rate.
    mutating func pickTime(rawTime: Double, hostTime: CFTimeInterval, rate: Double) -> (
        time: Double, discontinuity: Discontinuity?
    ) {
        let rawOffset = rawTime - hostTime * rate
        let elapsed = hostTime - lastHostTime
        let previousRate = self.rate
        defer { lastHostTime = hostTime }
        // A stopped clock has no jitter to filter, and any change of it is a deliberate move (seek, frame step).
        guard rate != 0 else {
            offset = nil
            self.rate = 0
            return (rawTime, nil)
        }
        guard let current = offset else {
            offset = rawOffset
            self.rate = rate
            return (rawTime + phaseBias, nil)
        }
        let discontinuity: Discontinuity? =
            if rate != previousRate {
                .rateChange(from: previousRate, to: rate)
            } else if elapsed <= 0 || elapsed >= Self.maxTickGap {
                .tickGap(seconds: elapsed)
            } else if abs(rawOffset - current) >= Self.discontinuityThreshold {
                .jump(seconds: rawOffset - current)
            } else {
                nil
            }
        if let discontinuity {
            offset = rawOffset
            self.rate = rate
            return (rawTime + phaseBias, discontinuity)
        }
        let updated = current + (rawOffset - current) * min(1, elapsed / Self.timeConstant)
        offset = updated
        return (hostTime * rate + updated + phaseBias, nil)
    }

    /// Nudges the phase bias after a frame was picked `slack` content seconds past its pick threshold.
    mutating func recordPick(slack: Double, tickInterval: CFTimeInterval, frameDuration: Double, playbackRate: Double) {
        let step = Self.latticeStep(tickInterval: tickInterval, frameDuration: frameDuration, rate: playbackRate)
        guard let step, slack.isFinite else {
            phaseBias = 0
            latticeStep = 0
            return
        }
        if abs(step - latticeStep) > step * 0.01 {
            phaseBias = 0
            latticeStep = step
        }
        // Distance of the pick from the centre of its lattice cell, in [−step/2, step/2): positive when picks land past
        // the centre, which less bias moves back.
        var fromCentre = slack.truncatingRemainder(dividingBy: step)
        if fromCentre < 0 { fromCentre += step }
        fromCentre -= step / 2
        phaseBias -= fromCentre * Self.phaseLockGain
        if phaseBias > step / 2 {
            phaseBias -= step
        } else if phaseBias < -step / 2 {
            phaseBias += step
        }
    }

    /// Spacing, in content seconds, of the phases frame boundaries take against vsync: tick / q for p/q ticks per
    /// frame. Nil when no lattice of at most `maxLatticePoints` points fits.
    static func latticeStep(tickInterval: CFTimeInterval, frameDuration: Double, rate: Double) -> Double? {
        guard tickInterval > 0, frameDuration > 0, rate > 0 else { return nil }
        let contentTick = tickInterval * rate
        let ticksPerFrame = frameDuration / contentTick
        for points in 1...maxLatticePoints {
            let scaled = ticksPerFrame * Double(points)
            // Lattice points drift by this share of a tick every `points` frames. Up to 1% the lock follows with a lag well
            // inside half a step; NTSC rates (23.976 on 60 Hz: 2.5025 → 0.5%) still lock.
            if abs(scaled - scaled.rounded()) < 0.01 {
                return contentTick / Double(points)
            }
        }
        return nil
    }
}
