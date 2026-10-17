import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("Backward Frame-Stepping Window", .hostDependent)
@MainActor
struct BackwardFrameSteppingTests {
    /// Regression guard: a paused exact seek into the middle of a long GOP must seed the step cache with a
    /// backward window (not just the forward over-read), so subsequent backward steps are instant cache
    /// hits instead of each triggering a full-GOP re-seek. The window frames below the target arrive
    /// flagged `doNotDisplay` (exact-seek preroll); they must still populate the cache.
    @Test("Backward steps are instant cache hits after a mid-GOP paused seek", .realtimePlayback)
    func backwardStepsAreCacheHits() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        #expect(engine.isLoaded)

        // Pause only once load's asynchronous autoplay has started; a seek while playing is a resuming seek and
        // skips seeding the step cache.
        #expect(await engine.waitUntil { engine.isPlaying }, "Load did not autoplay")
        engine.pause()
        #expect(
            await engine.waitUntil { !engine.isPlaying && !engine.isSeeking && engine.pendingSeekTime == nil },
            "Pause did not settle")

        // Keyframes every 5s → 3.5s is deep inside a GOP (~84 frames from the keyframe at 0s).
        engine.seek(to: 3.5)
        #expect(await engine.waitForSeekToSettle())

        // The seek must seed a real backward window, not just the handful of forward over-read frames.
        #expect(
            engine.stepFrameCache.count > 10,
            "Step cache holds \(engine.stepFrameCache.count) frames (playing: \(engine.isPlaying), frame \(engine.currentFramePTS)s)"
        )

        // Each backward step from the window updates currentFramePTS synchronously (cache hit). A full
        // re-seek would be asynchronous and leave currentFramePTS unchanged immediately after the call.
        for step in 1...5 {
            let before = engine.currentFramePTS
            engine.stepFrameBackward()
            let afterSync = engine.currentFramePTS
            #expect(afterSync < before, "backward step \(step) was not an instant cache hit")
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        engine.stop()
    }
}
