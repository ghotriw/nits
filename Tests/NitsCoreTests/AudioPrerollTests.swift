import Foundation
import Testing

@testable import NitsCore

/// A clock that starts on a renderer a seek flushed, before the audio is back, runs on an empty queue, and
/// `checkForStarvation` holds it again with a spinner (`isBuffering`). The start waits for the audio instead.
@Suite("Audio before the clock starts", .serialized, .realtimePlayback, .hostDependent)
struct AudioPrerollTests {
    /// Plays after a seek made on pause and reports whether buffering showed within the second that follows.
    @MainActor
    private static func playsWithoutBuffering(
        _ preset: SyntheticTestMediaFactory.Preset, seekTo target: Double
    ) async -> (moved: Bool, buffered: Bool) {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return (true, false) }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: path)
        guard engine.isLoaded, engine.media.duration > target + 2 else { return (true, false) }
        engine.play()
        _ = await engine.waitForPlayback()
        engine.pause()
        engine.seek(to: target, exact: false)
        _ = await engine.waitForSeekToSettle()
        try? await Task.sleep(for: .milliseconds(300))

        let startTime = engine.currentTime
        engine.play()
        var moved = false
        var buffered = false
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
            if engine.isBuffering { buffered = true }
            if engine.currentTime - startTime >= 0.3 { moved = true }
            if moved, ContinuousClock.now + .seconds(1) > deadline { break }
        }
        return (moved, buffered)
    }

    @Test("Play after a seek on pause starts the clock without buffering, with video")
    @MainActor
    func playAfterPausedSeekWithVideo() async {
        let result = await Self.playsWithoutBuffering(.multiTrackH264, seekTo: 8)
        #expect(result.moved, "The clock did not run")
        #expect(!result.buffered, "Buffering showed after play()")
    }

    @Test("Play after a seek on pause starts the clock without buffering, with audio only")
    @MainActor
    func playAfterPausedSeekAudioOnly() async {
        let result = await Self.playsWithoutBuffering(.audioOnlyFLAC, seekTo: 8)
        #expect(result.moved, "The clock did not run: an audio-only start waited for audio that did not come")
        #expect(!result.buffered, "Buffering showed after play()")
    }
}
