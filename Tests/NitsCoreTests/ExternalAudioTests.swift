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

    @Test("A file's track is saved by the file's path and stream, not by its id")
    func historySavesFileByPath() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let own = try #require(engine.audioTracks.last)
        engine.selectAudioTrack(id: own.id)
        try #require(await engine.waitForSeekToSettle())

        let added = await engine.attachExternalAudio(url: URL(fileURLWithPath: path))
        let external = try #require(added.last)
        engine.selectAudioTrack(id: external.id)
        try #require(await engine.waitForSeekToSettle())
        engine.saveCurrentPlaybackProgress()
        // Its id numbers the files added this time; opened again, the file's tracks may number otherwise.
        let saved = try #require(engine.historyStore.savedPreferences(for: path))
        #expect(saved.audioTrackId == PlaybackRecord.externalAudio)
        #expect(saved.externalAudioPath == URL(fileURLWithPath: path).standardizedFileURL.path)
        #expect(saved.externalAudioStreamIndex == external.streamIndex)
        #expect(own.streamIndex == external.streamIndex, "The same file: the same stream")
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

    /// A folder with a copy of `media` named `Clip` and copies of `audio` named `Clip.<tag>`.
    private func folder(media: String, audio: String, audioNames: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = URL(fileURLWithPath: media)
        try FileManager.default.copyItem(
            at: mediaURL, to: directory.appendingPathComponent("Clip.\(mediaURL.pathExtension)"))
        for name in audioNames {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: audio), to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test("A dub next to the media is a track of it, chosen by the audio language over the media's own")
    func sidecarDubChosenByLanguage() async throws {
        guard let media = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264),
            let dub = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let directory = try folder(media: media, audio: dub, audioNames: ["Clip.pl.flac", "Clip.uk.flac"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Clip.mkv").path

        var configuration = PlayerConfiguration(resumePlayback: false)
        configuration.trackLanguages = TrackLanguagePreferences(audioLanguages: ["pl"])
        let engine = PlayerEngine.makeForTesting(configuration: configuration)
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        #expect(engine.audioTracks.count == 4, "\(engine.audioTracks.map(\.title))")
        let polish = try #require(engine.audioTracks.first { $0.externalURL?.lastPathComponent == "Clip.pl.flac" })
        #expect(polish.language == "pl" && polish.title == "Clip.pl (External)")
        #expect(!polish.isDefault, "A file's own default flag would beat the media's tracks on a tie")
        #expect(engine.selectedAudioTrackId == polish.id && engine.inputs?.isAudioSeparate == true)
        let fed = try await firstFedAudio(engine)
        #expect(fed < 1, "The dub started at \(fed)s")

        // The same language in the media and in a file: the media's own track.
        var ukrainian = configuration
        ukrainian.trackLanguages = TrackLanguagePreferences(audioLanguages: ["uk"])
        engine.applyConfiguration(ukrainian)
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let own = try #require(engine.audioTracks.first { $0.language == "ukr" && $0.externalURL == nil })
        #expect(engine.selectedAudioTrackId == own.id)
    }

    @Test("Media without a picture takes no files named as it: they are other copies, not its audio")
    func audioMediaTakesNoSidecars() async throws {
        guard let song = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC) else { return }
        let directory = try folder(media: song, audio: song, audioNames: ["Clip.uk.flac"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: directory.appendingPathComponent("Clip.flac").path)
        try #require(await engine.waitForPlayback(advancingBy: 0.1))
        #expect(engine.audioTracks.allSatisfy { $0.externalURL == nil }, "\(engine.audioTracks.map(\.title))")
    }

    @Test("Choosing another track drops the file saved before from the history")
    func otherTrackDropsSavedFile() {
        let saved = PlaybackPreferences(
            audioTrackId: PlaybackRecord.externalAudio, externalAudioPath: "/dubs/Clip.uk.mka",
            externalAudioStreamIndex: 1)
        let mediaTrack = PlaybackPreferences(audioTrackId: 1).merged(over: saved)
        #expect(mediaTrack.audioTrackId == 1)
        #expect(mediaTrack.externalAudioPath == nil && mediaTrack.externalAudioStreamIndex == nil)
        // Nothing chosen this time: the file stays.
        #expect(PlaybackPreferences(audioDelay: 0.2).merged(over: saved).externalAudioPath == "/dubs/Clip.uk.mka")
    }

    @Test("A file chosen from elsewhere is opened and chosen again the next time the media opens")
    func historyRestoresFile() async throws {
        guard let media = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let dub = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: media)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        var reports = 0
        engine.onTracksChanged = { reports += 1 }
        await engine.loadExternalAudio(urls: [URL(fileURLWithPath: dub)])
        try #require(await engine.waitUntil { engine.inputs?.isAudioSeparate == true })
        #expect(reports == 1, "Adding a file and choosing it reported \(reports) times")
        try #require(await engine.waitForSeekToSettle())
        engine.stop()

        engine.load(path: media)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let selected = try #require(engine.audioTracks.first { $0.id == engine.selectedAudioTrackId })
        #expect(selected.externalURL?.path == URL(fileURLWithPath: dub).standardizedFileURL.path)
    }

    @Test("A file over HTTP plays, read ahead on its own input")
    func playsFileOverHTTP() async throws {
        guard let media = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let dub = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let dubURL = URL(fileURLWithPath: dub)
        let server = try TestHTTPServer(root: dubURL.deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: media)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))

        let remote = try #require(URL(string: server.url(dubURL.lastPathComponent)))
        let external = try #require(await engine.attachExternalAudio(url: remote).first)
        engine.selectAudioTrack(id: external.id)
        try #require(await engine.waitForPlayback(advancingBy: 1))
        #expect(engine.inputs?.selectedExternal?.readsAhead == true)
        #expect(!engine.isBuffering)
        // The track names no file to open again: not saved.
        engine.saveCurrentPlaybackProgress()
        #expect(engine.historyStore.savedPreferences(for: media)?.externalAudioPath == nil)
    }

    @Test("Stopping aborts a file still opening on a server that doesn't answer")
    func stopAbortsOpening() async throws {
        guard let media = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let dub = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let dubURL = URL(fileURLWithPath: dub)
        let server = try TestHTTPServer(root: dubURL.deletingLastPathComponent())
        defer { server.stop() }
        server.setDefaultBehavior(.init(failure: .hang))
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: media)
        try #require(await engine.waitForPlayback(advancingBy: 0.1))
        let inputs = try #require(engine.inputs)

        let remote = try #require(URL(string: server.url(dubURL.lastPathComponent)))
        let opening = Task { await inputs.openExternalAudio(url: remote) }
        try await Task.sleep(for: .milliseconds(300))
        let stoppedAt = ContinuousClock.now
        engine.stop()
        #expect(await opening.value.isEmpty)
        #expect(ContinuousClock.now - stoppedAt < .seconds(3), "The opening waited for FFmpeg's own timeout")
    }

    @Test("Audio that stops coming over its own input holds playback until it comes again, the picture ready or not")
    func holdsWhileFileStalls() async throws {
        guard let media = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return }
        let mediaURL = URL(fileURLWithPath: media)
        let server = try TestHTTPServer(root: mediaURL.deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: media)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        let remote = try #require(URL(string: server.url(mediaURL.lastPathComponent)))
        let external = try #require(await engine.attachExternalAudio(url: remote).first)
        engine.selectAudioTrack(id: external.id)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))

        // The network stops; the picture, local, keeps coming. Far past what was read ahead, nothing is queued.
        let name = mediaURL.lastPathComponent
        server.setBehavior(.init(bytesPerSecond: 1), forPaths: { $0 == name })
        engine.seek(to: 50, exact: true)
        #expect(await engine.waitUntil(timeout: .seconds(10)) { engine.isBuffering }, "No buffering without audio")
        let heldAt = engine.synchronizer.currentTime().seconds
        // Without audio coming in, it doesn't resume into silence (and buffer again) once the picture is ready.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            #expect(engine.isBuffering, "Resumed with no audio coming")
        }
        #expect(engine.synchronizer.currentTime().seconds - heldAt < 0.3)

        server.setBehavior(.init(), forPaths: { $0 == name })
        #expect(await engine.waitUntil(timeout: .seconds(10)) { !engine.isBuffering }, "Didn't resume once data came")
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
