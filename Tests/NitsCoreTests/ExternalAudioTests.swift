import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// Audio from a file added to the media, read on an input of its own (`PlaybackInputs`).
@Suite("External audio", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct ExternalAudioTests {
    /// Where the audio fed after the last start of feeding begins, in media seconds.
    private func firstFedAudio(_ engine: PlayerEngine) async throws -> Double {
        #expect(await engine.waitUntil(timeout: .seconds(3)) { engine.firstFedAudioPTS.withLock { $0 } != nil })
        return try #require(engine.firstFedAudioPTS.withLock { $0 }?.seconds)
    }

    @Test("A track of an added file plays from the current frame, and the media's own plays again once chosen back")
    func playsAddedFileAndBack() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        let own = engine.audioTracks

        // The media's own audio, read again on an input of its own: its tracks line up with the picture exactly.
        let added = await engine.attachExternalAudio(url: URL(fileURLWithPath: path))
        try #require(added.count == own.count)
        #expect(engine.audioTracks.count == own.count * 2)
        #expect(added.allSatisfy { $0.id >= PlaybackInputs.firstExternalTrackId && $0.externalURL != nil })
        #expect(engine.selectedAudioTrackId == own.first?.id, "Adding a file selected one of its tracks")

        let external = try #require(added.first)
        engine.selectAudioTrack(id: external.id)
        #expect(engine.selectedAudioTrackId == external.id)
        #expect(engine.inputs?.isAudioSeparate == true)
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        let clock = engine.synchronizer.currentTime().seconds
        let fed = try await firstFedAudio(engine)
        #expect(abs(fed - clock) < 1, "The file's audio started at \(fed)s with the clock at \(clock)s")
        #expect(!engine.isBuffering)

        let ownTrack = try #require(own.first)
        engine.selectAudioTrack(id: ownTrack.id)
        #expect(engine.inputs?.isAudioSeparate == false)
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        let ownFed = try await firstFedAudio(engine)
        #expect(abs(ownFed - engine.synchronizer.currentTime().seconds) < 1)
    }

    @Test("A keyframe seek starts the file's audio where the picture landed, not at the target")
    func keyframeSeekFollowsLanding() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let external = try #require(await engine.attachExternalAudio(url: URL(fileURLWithPath: path)).first)
        engine.selectAudioTrack(id: external.id)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))

        // Keyframes every 5 s: a backward keyframe seek to 12 s lands on the one at 10 s.
        engine.seek(to: 12, exact: false)
        try #require(await engine.waitForSeekToSettle())
        let landed = engine.currentTime
        #expect(abs(landed - 10) < 0.5, "Landed at \(landed)s")
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let fed = try await firstFedAudio(engine)
        #expect(abs(fed - landed) < 0.3, "The file's audio started at \(fed)s, the picture at \(landed)s")
    }

    @Test("Choosing a file's track keeps the track chosen before in the history")
    func historyKeepsChoiceOverFileTrack() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let own = try #require(engine.audioTracks.last)
        engine.selectAudioTrack(id: own.id)
        try #require(await engine.waitForSeekToSettle())

        let external = try #require(await engine.attachExternalAudio(url: URL(fileURLWithPath: path)).first)
        engine.selectAudioTrack(id: external.id)
        try #require(await engine.waitForSeekToSettle())
        engine.saveCurrentPlaybackProgress()
        // Its id numbers the files added this time; opened again without the file, it would match nothing.
        #expect(engine.historyStore.savedPreferences(for: path)?.audioTrackId == own.id)
    }

    @Test("Media without a picture plays a file's track, and seeks position the file alone")
    func audioOnlyMediaPlaysFileTrack() async throws {
        guard let media = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC),
            let file = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264)
        else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: media)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let external = try #require(await engine.attachExternalAudio(url: URL(fileURLWithPath: file)).first)
        engine.selectAudioTrack(id: external.id)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))

        engine.seek(to: 6, exact: true)
        try #require(await engine.waitForSeekToSettle())
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let fed = try await firstFedAudio(engine)
        #expect(abs(fed - 6) < 0.3, "The file's audio started at \(fed)s for a seek to 6 s")
        #expect(engine.inputs?.isEOF == false, "Nothing selected in the media, yet it counts as ended")
        #expect(engine.bufferedTime > engine.currentTime, "Read ahead of playback: \(engine.bufferedTime)s")
    }

    @Test("A file shorter than the picture ends and the picture plays on, without buffering")
    func shorterFileEnds() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: video)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let external = try #require(await engine.attachExternalAudio(url: URL(fileURLWithPath: audio)).first)
        engine.selectAudioTrack(id: external.id)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))

        // The 15 s of audio end a second in; the 20 s picture goes on.
        engine.seek(to: 14, exact: true)
        try #require(await engine.waitForSeekToSettle())
        #expect(await engine.waitForClock(toPass: 16.5, timeout: .seconds(10)))
        #expect(engine.inputs?.isAudioEOF == true)
        #expect(engine.isPlaying && !engine.isBuffering)
    }
}
