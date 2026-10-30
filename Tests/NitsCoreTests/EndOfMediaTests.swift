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

    /// `wideGOPH264`: 60 s at 24 fps, a keyframe every 5 s, the last at 55 s.
    private func loadPausedWideGOP(at seconds: Double) async throws -> PlayerEngine? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return nil }
        let engine = PlayerEngine.makeForTesting()
        engine.playlist.setRepeatMode(.off)
        engine.exactSeekOnSinglePress = false
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        engine.pause()
        engine.seek(to: seconds)
        try #require(await engine.waitForSeekToSettle())
        return engine
    }

    @Test("A keyframe seek forward past the last keyframe lands on its target, not back on that keyframe")
    func forwardSeekPastLastKeyframe() async throws {
        guard let engine = try await loadPausedWideGOP(at: 56) else { return }
        defer { engine.stop() }

        engine.seekRelative(by: 2)
        #expect(await engine.waitForSeekToSettle())
        #expect(abs(engine.currentTime - 58) < 0.05, "Landed at \(engine.currentTime)s")
        #expect(engine.playbackState == .paused)
        // An exact landing seeds the window paused steps go back through, as any exact seek does.
        #expect(engine.frameStep.cache.count > 10, "Step cache holds \(engine.frameStep.cache.count) frames")
    }

    @Test("Seeking forward at the end of media that played to it leaves it ended")
    func seekAfterCompletionStaysCompleted() async throws {
        guard let engine = try await loadPausedWideGOP(at: 59) else { return }
        defer { engine.stop() }
        engine.play()
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.playbackState == .completed })

        engine.seekRelative(by: 5)
        #expect(await engine.waitForSeekToSettle())
        #expect(engine.playbackState == .completed)
    }

    @Test("A seek to the target of the seek in flight leaves that one running")
    func sameTargetDoesNotSupersede() async throws {
        guard let engine = try await loadPausedWideGOP(at: 30) else { return }
        defer { engine.stop() }

        // The seek is in flight from the call on: its work on `seekQueue` reports back on the main actor, after.
        engine.seek(to: 58)
        #expect(engine.isSeeking)
        let seekId = engine.seekGeneration.current
        engine.seek(to: 58)
        #expect(engine.seekGeneration.current == seekId, "The same target superseded the seek")
        engine.seek(to: 59)
        #expect(engine.seekGeneration.current != seekId, "A new target did not supersede the seek")
        #expect(await engine.waitForSeekToSettle())
        #expect(abs(engine.currentTime - 59) < 0.05, "Landed at \(engine.currentTime)s")
    }

    @Test("Seeking forward past the end while paused stays on the last frame")
    func pausedSeekPastEnd() async throws {
        guard let engine = try await loadPausedWideGOP(at: 58) else { return }
        defer { engine.stop() }
        let lastFrame = engine.media.duration - 1.0 / 24

        engine.seekRelative(by: 5)
        #expect(await engine.waitForSeekToSettle())
        #expect(engine.currentTime > lastFrame - 0.01, "Landed at \(engine.currentTime)s")
        #expect(engine.playbackState == .paused && !engine.isPlaying)

        // At the end already, another press has nothing to seek to.
        let seekId = engine.seekGeneration.current
        engine.seekRelative(by: 5)
        #expect(engine.seekGeneration.current == seekId, "The press at the end seeked")
        #expect(engine.currentTime > lastFrame - 0.01 && engine.playbackState == .paused)
    }

    @Test("Seeking forward past the end while playing completes there", arguments: [false, true])
    func playingSeekPastEndCompletes(exactFirstPress: Bool) async throws {
        guard let engine = try await loadPausedWideGOP(at: 56.5) else { return }
        defer { engine.stop() }
        engine.exactSeekOnSinglePress = exactFirstPress
        engine.play()
        try #require(await engine.waitForPlayback())

        engine.seekRelative(by: 5)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.playbackState == .completed })
        #expect(engine.currentTime > engine.media.duration - 0.25, "Ended at \(engine.currentTime)s")
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

@Suite("Forward keyframe seeks")
struct ForwardKeyframeSeekTests {
    /// Keyframes every 5 s, the last at 55 s (see `EndOfMediaTests`). In MPEG-TS the seek bisects and searches on for
    /// the keyframe, landing near the target rather than on it: still a keyframe seek.
    @Test(
        "A forward keyframe seek goes exactly only when no keyframe follows its target",
        arguments: [SyntheticTestMediaFactory.Preset.wideGOPH264, .wideGOPH264TS])
    func exactOnlyPastLastKeyframe(preset: SyntheticTestMediaFactory.Preset) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))

        #expect(!demuxer.seek(to: 22, exact: false, forward: true))
        let landed = try #require(demuxer.nextVideoSample()).presentationTimeStamp.seconds
        #expect(abs(landed - 25) < 0.05, "Landed at \(landed)s")

        #expect(demuxer.seek(to: 57, exact: false, forward: true))
        #expect(demuxer.seek(to: 60, exact: false, forward: true))
        #expect(!demuxer.seek(to: 57, exact: false, forward: false), "A backward keyframe seek stays one")
    }
}
