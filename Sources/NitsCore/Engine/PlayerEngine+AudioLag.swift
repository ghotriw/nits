import CoreMedia
import Foundation

/// Re-anchors the clock when the audio renderer has fallen behind it for good.
///
/// Starting playback on a Bluetooth route, the device can stop its IO for most of a second while the audio queue
/// starts (seen with spatial audio being switched on). The renderer then anchors its timebase back in time, so the
/// clock leaps ahead while its audio queue stays that far behind for the rest of playback. Its backpressure releases
/// audio at the queue's pace, so every buffer arrives already late: the renderer discards it and resyncs the queue
/// several times a second, which is heard as choppy audio. It never recovers by itself; a pause and resume does.
///
/// The symptom the engine sees is the feeder waiting for the renderer to take audio that is already due. A healthy
/// renderer takes audio about a second ahead of the clock, and a real shortage of data leaves the feeder waiting on
/// the demuxer, not on the renderer (see `PlayerEngine+Buffering`).
extension PlayerEngine {
    /// Re-anchors the clock once `audioLagDetector` says the renderer has held back due audio for long enough.
    /// Called by the periodic time observer, which fires only while the clock runs.
    func checkForAudioRendererLag() {
        let clock = synchronizer.currentTime()
        let pending = audioSink.pendingStart
        // Audio about to play counts as due: the renderer needs it in its queue well before the clock reaches it.
        let dueBy = clock.seconds + Self.bufferingAudioLowWatermark * playbackRate
        let isPendingDue = pending.map { $0.isNumeric && $0.seconds < dueBy } ?? false
        let isLagging =
            isPlaying && !isBuffering && !isSeeking && chaseTargetTime == nil && !isPrerolling
            && synchronizer.rate > 0 && clock.isNumeric && isPendingDue
        guard let heldFor = audioLagDetector.observe(isLagging: isLagging, at: .now), let pending else { return }

        AppLog.warning(
            .engine,
            "Audio renderer behind the clock: holding back audio from \(String(format: "%.3f", pending.seconds))s at "
                + "\(String(format: "%.3f", clock.seconds))s for \(heldFor); re-anchoring the clock"
        )
        // What a pause and resume does, without touching the user-facing playback state.
        haltPlaybackPipeline()
        startFeeding()
        startSynchronizerClockAfterPreroll(at: synchronizer.currentTime(), alignWithBufferedAudio: true)
        displayLink?.isPaused = !media.hasVideo
    }
}

/// Decides when the audio renderer has held back due audio long enough for the clock to be re-anchored.
struct AudioLagDetector {
    /// How long the renderer must keep holding back due audio; shorter holds come and go with the renderer taking
    /// audio in bursts.
    static let recoveryDelay: Duration = .milliseconds(500)
    /// Minimum time between re-anchors, so a renderer that keeps falling behind does not stutter playback in a loop.
    static let cooldown: Duration = .seconds(5)

    /// Since when the renderer has held back due audio; `nil` while it takes audio in time.
    private(set) var lagSince: ContinuousClock.Instant?
    private var lastRecovery: ContinuousClock.Instant?

    /// Records whether the renderer holds back due audio at `now`. Returns how long it has, when the clock is to be
    /// re-anchored now; `nil` otherwise.
    mutating func observe(isLagging: Bool, at now: ContinuousClock.Instant) -> Duration? {
        guard isLagging else {
            lagSince = nil
            return nil
        }
        guard let lagSince else {
            self.lagSince = now
            return nil
        }
        let heldFor = now - lagSince
        guard heldFor >= Self.recoveryDelay else { return nil }
        if let lastRecovery, now - lastRecovery < Self.cooldown { return nil }
        self.lagSince = nil
        lastRecovery = now
        return heldFor
    }

    /// The clock was stopped or re-anchored: a hold seen before it no longer counts. The cooldown stays.
    mutating func clockRestarted() {
        lagSince = nil
    }
}
