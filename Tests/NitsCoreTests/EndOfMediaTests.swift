import Foundation
import Testing

@testable import NitsCore

@Suite("End of media", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct EndOfMediaTests {
    @Test("Playing to the end completes")
    func playingToEndCompletes() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.playlist.setRepeatMode(.off)
        engine.load(path: path)
        try #require(await engine.waitForPlayback())

        engine.seek(to: engine.media.duration - 1.0)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.playbackState == .completed })
    }

    @Test("Repeat-one restarts without completing, so the host sees no end")
    func repeatOneDoesNotComplete() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.playlist.setRepeatMode(.one)
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        var states: [PlaybackState] = []
        engine.onPlaybackStateChanged = { states.append($0) }

        engine.seek(to: engine.media.duration - 1.0)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.isPlaying && engine.currentTime < 3.0 })
        #expect(!states.contains(.completed), "States: \(states)")
    }
}
