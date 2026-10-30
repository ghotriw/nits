import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore
@testable import NitsKit

@Suite("Picture in Picture controller")
@MainActor
struct PictureInPictureControllerTests {
    @Test("Follows the engine's playback state without the host forwarding it")
    func followsEngine() async {
        let engine = PlayerEngine.makeForTesting()
        let pip = PictureInPictureController(engine: engine)

        engine.media.duration = 100
        engine.currentTime = 5
        engine.isPlaying = true
        #expect(await waitUntil { pip.playbackSnapshot.isPlaying && pip.playbackSnapshot.mediaTime == 5 })
        #expect(pip.playbackSnapshot.duration == 100)

        // Still observing after the first change.
        engine.isPlaying = false
        engine.currentTime = 42
        engine.setPlaybackRate(2)
        #expect(
            await waitUntil {
                !pip.playbackSnapshot.isPlaying && pip.playbackSnapshot.mediaTime == 42
                    && pip.playbackSnapshot.rate == 2
            })
    }

    @Test("Created with media already loaded, it starts from the engine's state")
    func startsFromCurrentState() {
        let engine = PlayerEngine.makeForTesting()
        engine.media.duration = 100
        engine.currentTime = 30

        let pip = PictureInPictureController(engine: engine)
        #expect(pip.playbackSnapshot.mediaTime == 30)
        #expect(pip.playbackSnapshot.duration == 100)
    }

    @Test("The position alone is followed only while Picture in Picture is active")
    func followsPositionOnlyWhileActive() async {
        let engine = PlayerEngine.makeForTesting()
        let pip = PictureInPictureController(engine: engine)
        engine.currentTime = 10
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pip.playbackSnapshot.mediaTime == 0)

        engine.isPictureInPictureActive = true
        defer { engine.isPictureInPictureActive = false }
        #expect(await waitUntil { pip.playbackSnapshot.mediaTime == 10 })
        // Only a jump makes PiP re-read, but the snapshot follows every update.
        engine.currentTime = 10.05
        #expect(await waitUntil { pip.playbackSnapshot.mediaTime == 10.05 })
    }
}
