import AVFoundation
import Foundation
import NitsTestSupport

@testable import NitsCore

extension PlayerEngine {
    /// Waits until the master clock passes `seconds`.
    ///
    /// After `play()` the synchronizer holds the clock until the audio device is running. A device that was idle
    /// (notably a Bluetooth route such as AirPods) takes several hundred milliseconds to start, so tests must not
    /// assume the clock moves a fixed time after `play()`.
    @MainActor
    func waitForClock(toPass seconds: Double, timeout: Duration = PlayerEngine.testWaitTimeout) async -> Bool {
        await waitUntil(timeout: timeout) { synchronizer.currentTime().seconds > seconds }
    }

    /// Waits until no seek is in flight and none is waiting to resume playback (the chase-settle debounce).
    @MainActor
    func waitForSeekToSettle(timeout: Duration = PlayerEngine.testWaitTimeout) async -> Bool {
        await waitUntil(timeout: timeout) { !isSeeking && pendingSeekTime == nil }
    }

    /// Waits until playback runs: seeks have settled, the engine is playing, its clock has started after preroll
    /// and has advanced by `seconds` since.
    @MainActor
    func waitForPlayback(advancingBy seconds: Double = 0.1, timeout: Duration = PlayerEngine.testWaitTimeout) async
        -> Bool
    {
        let started = await waitUntil(timeout: timeout) {
            !isSeeking && pendingSeekTime == nil && isPlaying && !isPrerolling
        }
        guard started else { return false }
        return await waitForClock(toPass: synchronizer.currentTime().seconds + seconds, timeout: timeout)
    }

    /// Steps one frame forward and waits until the step has moved the frame and finished decoding.
    ///
    /// The frame can change while the step pump is still decoding, and a step in flight drops further presses
    /// (key-repeat throttling), so a following step must wait for this one to finish, not just for the new frame.
    @MainActor
    func stepFrameForwardAndWait(timeout: Duration = PlayerEngine.testWaitTimeout) async -> Bool {
        let before = currentFramePTS
        stepFrameForward()
        return await waitUntil(timeout: timeout) { currentFramePTS > before && !isStepInFlight }
    }

    /// Polls `condition` until it holds or `timeout` expires; returns its final value.
    @MainActor
    func waitUntil(timeout: Duration = PlayerEngine.testWaitTimeout, _ condition: @MainActor () -> Bool) async -> Bool {
        await NitsTestSupport.waitUntil(timeout: timeout, condition)
    }
}
