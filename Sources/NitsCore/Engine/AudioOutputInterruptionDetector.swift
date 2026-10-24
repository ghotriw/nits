import Foundation

/// Decides when the audio output device stopping its IO under a started clock calls for re-anchoring the clock.
///
/// A Bluetooth device the Mac does not own yet when playback starts (AirPods last used by an iPhone) first runs its
/// IO on a placeholder, so the renderer's audio queue starts at once and its timeline begins. 0.1–0.3 s later the
/// device switches to its real stream: its IO stops for most of a second and starts again. The queue stays that far
/// behind the clock for good, discarding every buffer as late, which is heard as choppy audio; a pause and resume
/// heals it. A device already running for another client and restarted by it does the same.
///
/// Whether the clock is moving yet tells nothing: the synchronizer can hold it for a while after the queue has started.
/// What tells is how long the device ran before stopping. Healthy starts that restart the IO stop it within ~10 ms of
/// starting it, while the queue start still waits for it; the switch from a placeholder comes after 100 ms or more.
/// The engine's own stops (pause, seek, track switch) stop the clock first, through `cancelPreroll()`.
///
/// Only a run that began after the clock started counts, one the renderer's queue started: the device is shared, so
/// the stop of a previous media's queue (or of another player's in the process) can arrive after the clock started.
/// That leaves out a device already running for another client and restarted by it; `AudioLagDetector` remains.
struct AudioOutputInterruptionDetector: Sendable {
    /// Minimum time between re-anchors, so a device that keeps restarting its IO does not stutter playback in a loop.
    static let cooldown: Duration = .seconds(5)
    /// How long the device must have run for its IO stop to count: shorter runs stop within the queue start, which
    /// waits for the device and so starts the queue's timeline on the real stream.
    static let minimumRunDuration: Duration = .milliseconds(50)

    /// When the clock was started; `nil` while it is stopped. A rate change keeps it.
    private var clockStartedAt: ContinuousClock.Instant?
    /// Bumped whenever the clock stops (and with it every re-anchor) and on `reset()`, so a recovery decided for one
    /// clock start is not carried out on a later one.
    private(set) var clockGeneration: UInt64 = 0
    /// When the device's current run began; `nil` while it is stopped or not seen starting.
    private var runningSince: ContinuousClock.Instant?
    /// The device stopped its IO under the started clock, and has not run again since.
    private(set) var isInterrupted = false
    private var lastRecovery: ContinuousClock.Instant?

    /// The clock was set to run at `now`. A clock already running (a rate change) keeps its start and interruption.
    mutating func clockStarted(at now: ContinuousClock.Instant) {
        guard clockStartedAt == nil else { return }
        clockStartedAt = now
        isInterrupted = false
    }

    /// The clock was stopped or re-anchored: an interruption seen before it no longer counts.
    mutating func clockStopped() {
        clockStartedAt = nil
        clockGeneration &+= 1
        isInterrupted = false
    }

    /// The renderer moved to another output device: what was seen of the previous one's runs doesn't apply.
    mutating func outputDeviceChanged() {
        runningSince = nil
        isInterrupted = false
    }

    /// The engine flushed the renderer (a seek, an audio delay change, a new output device): its audio queue restarts,
    /// stopping and starting the device's IO under a clock that may keep running. The current run's stop is its own.
    mutating func rendererFlushed() {
        runningSince = nil
        isInterrupted = false
    }

    /// New media loads: forgets everything, the cooldown too, and drops a recovery still on its way for the old one.
    mutating func reset() {
        let generation = clockGeneration
        self = AudioOutputInterruptionDetector()
        clockGeneration = generation &+ 1
    }

    /// Records the output device starting or stopping its IO, with the clock's rate at that moment. Returns the clock
    /// generation to re-anchor when the device runs again after an interruption; the re-anchor is then for
    /// `confirmRecovery` to allow.
    mutating func deviceRunningChanged(isRunning: Bool, rate: Double, at now: ContinuousClock.Instant) -> UInt64? {
        guard isRunning else {
            // The HAL repeats notifications: a stop of a device already stopped is not another one.
            if let clockStartedAt, let runningSince, rate > 0, runningSince >= clockStartedAt,
                now - runningSince >= Self.minimumRunDuration
            {
                isInterrupted = true
            }
            runningSince = nil
            return nil
        }
        if runningSince == nil {
            runningSince = now
        }
        guard isInterrupted else { return nil }
        isInterrupted = false
        return clockGeneration
    }

    /// Whether the re-anchor decided for `generation` is to go ahead at `now`: the clock has not been stopped or
    /// re-anchored since, and none went ahead within the cooldown. Records it when it does.
    mutating func confirmRecovery(generation: UInt64, at now: ContinuousClock.Instant) -> Bool {
        guard generation == clockGeneration, clockStartedAt != nil else { return false }
        if let lastRecovery, now - lastRecovery < Self.cooldown { return false }
        lastRecovery = now
        return true
    }
}
