import Foundation
import Testing

@testable import NitsCore

/// `SubtitleController` on its own, against a host without media: what it does with subtitle files needs no engine.
@Suite("SubtitleController")
@MainActor
struct SubtitleControllerTests {
    @MainActor
    final class FakeHost: SubtitleHost {
        var demuxer: MediaDemuxer?
        var currentSourcePath: String?
        var currentHeaders: [String: String] = [:]
        var currentTime: Double = 0
        var clockSeconds: Double { currentTime }
        var subtitleVideo = SubtitleVideo()
        var isPresentingContinuously = false
        var isPlaying = false
        var saves = 0
        var reports = 0
        private var deferral = 0
        private var hasDeferred = false

        func saveCurrentPlaybackProgress() { saves += 1 }
        func rereadFromCurrentFrame() {}
        func tracksDidChange() {
            if deferral > 0 { hasDeferred = true } else { reports += 1 }
        }
        func deferringTracksChanged(_ body: () -> Void) {
            deferral += 1
            body()
            deferral -= 1
            if deferral == 0, hasDeferred {
                hasDeferred = false
                reports += 1
            }
        }
    }

    private func subtitleFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("episode.uk.srt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("An added file becomes the selected track, reported once, and shows its cues as time moves")
    func addsAndShowsFile() async throws {
        let url = try subtitleFile(
            "1\n00:00:01,000 --> 00:00:03,000\nПривіт\n\n2\n00:00:05,000 --> 00:00:06,000\nДругий\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host

        await controller.addExternal(url: url)
        let track = try #require(controller.tracks.first)
        #expect(controller.selectedTrackId == track.id && track.language == "uk")
        #expect(host.reports == 1)
        #expect(host.saves == 1, "Choosing a track saves it")

        controller.timeDidChange(to: 2, .tick)
        #expect(controller.cues.map(\.text) == ["Привіт"])
        controller.timeDidChange(to: 4, .tick)
        #expect(controller.cues.isEmpty)

        // A delay of 3 s shows the second line at 8 s.
        host.currentTime = 8
        controller.setDelay(3)
        #expect(controller.cues.map(\.text) == ["Другий"])
    }

    @Test("A file added while media opens in the background doesn't outlive the load")
    func fileAddedDuringLoadIsDropped() async throws {
        let url = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nПривіт\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        await controller.addExternal(url: url)
        try #require(controller.selectedTrackId != nil)

        // Media without subtitles of its own or next to it, and nothing that chooses a track.
        controller.mediaDidLoad(
            tracks: [], readFiles: MediaSubtitleFiles(), saved: nil, requestedTrack: nil, audioLanguage: nil)
        controller.timeDidChange(to: 2, .tick)
        #expect(controller.tracks.isEmpty)
        #expect(controller.selectedTrackId == nil)
        #expect(controller.cues.isEmpty && controller.loadedDocuments.isEmpty)
    }

    @Test("History saves an added file by its path and the delay; a reset forgets the media's tracks")
    func writesPreferencesAndResets() async throws {
        let url = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nПривіт\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        await controller.addExternal(url: url)
        controller.setDelay(-0.5)

        var preferences = PlaybackPreferences()
        controller.writePreferences(into: &preferences)
        #expect(preferences.subtitleTrackId == PlaybackRecord.externalSubtitle)
        #expect(preferences.externalSubtitlePath == url.standardizedFileURL.path)
        #expect(preferences.subtitleDelays?.values.first == -0.5)

        controller.timeDidChange(to: 2, .tick)
        controller.reset()
        #expect(controller.tracks.isEmpty && controller.selectedTrackId == nil && controller.cues.isEmpty)
    }

    @Test("A second track shows at the top and moves the selected track's cues to the bottom")
    func secondTrackPlacesBothTracks() async throws {
        let first = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nПривіт\n")
        let second = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nHello\n")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let host = FakeHost()
        host.currentTime = 2
        let controller = SubtitleController()
        controller.host = host
        await controller.addExternal(url: first)
        let firstId = try #require(controller.selectedTrackId)
        let secondId = try #require(controller.addExternalFile(url: second).first)

        controller.secondary.select(trackId: firstId)
        #expect(controller.secondary.selectedTrackId == nil, "The selected track can't be second too")
        controller.secondary.select(trackId: secondId)
        #expect(controller.secondary.selectedTrackId == secondId)

        controller.timeDidChange(to: 2, .tick)
        // Cues carrying a position of their own (the top) lose it while there are two tracks.
        let placed = controller.textCues
        #expect(placed.map(\.text) == ["Привіт", "Hello"])
        #expect(placed.map(\.alignment) == [.bottomCenter, .topCenter])
        #expect(Set(placed.map(\.id)).count == 2)

        controller.secondary.select(trackId: nil)
        #expect(controller.textCues.map(\.text) == ["Привіт"])
    }

    @Test("Choosing a second track as the selected one drops it from the second")
    func selectingTheSecondTrackFreesIt() async throws {
        let first = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nПривіт\n")
        let second = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nHello\n")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        await controller.addExternal(url: first)
        let secondId = try #require(controller.addExternalFile(url: second).first)
        controller.secondary.select(trackId: secondId)

        controller.select(trackId: secondId)
        #expect(controller.secondary.selectedTrackId == nil)
        #expect(controller.selectedTrackId == secondId)
    }

    @Test("Choosing an encoding reads the added files again in it")
    func encodingReadsFilesAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // "Привіт" in KOI8-U: no detector is sure of it.
        let koi8u = try #require(TextFileEncoding.encoding(named: "koi8-u"))
        let url = directory.appendingPathComponent("episode.srt")
        let text = "1\n00:00:01,000 --> 00:00:03,000\nПривіт\n"
        try #require(text.data(using: koi8u)).write(to: url)

        let host = FakeHost()
        host.currentTime = 2
        let controller = SubtitleController()
        controller.host = host
        await controller.addExternal(url: url)
        let id = try #require(controller.selectedTrackId)
        controller.setEncoding(koi8u, ofTrack: id)
        #expect(controller.encoding(ofTrack: id) == koi8u)
        #expect(controller.settings.encoding == nil, "The choice is the track's, not the default")
        for _ in 0..<100 where controller.cues.map(\.text) != ["Привіт"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.cues.map(\.text) == ["Привіт"])
    }

    @Test("Each track keeps its own delay, saved for the file and restored with the track")
    func delaysAreKeptPerTrack() async throws {
        let first = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nПривіт\n")
        let second = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nHello\n")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        await controller.addExternal(url: first)
        let firstId = try #require(controller.selectedTrackId)
        let secondId = try #require(controller.addExternalFile(url: second).first)
        controller.setDelay(1.5)
        controller.secondary.select(trackId: secondId)
        #expect(controller.secondary.delay == 0, "The second track doesn't take the main track's delay")
        controller.secondary.setDelay(-0.5)
        #expect(controller.delay == 1.5 && controller.secondary.delay == -0.5)

        // Switching tracks takes the delay of the one chosen.
        controller.select(trackId: secondId)
        #expect(controller.delay == -0.5)
        controller.select(trackId: firstId)
        #expect(controller.delay == 1.5)

        var preferences = PlaybackPreferences()
        controller.writePreferences(into: &preferences)
        #expect(preferences.subtitleDelays?.count == 2)
        #expect(Set((preferences.subtitleDelays ?? [:]).values) == [1.5, -0.5])

        // A track back at 0 keeps nothing.
        controller.setDelay(0)
        controller.writePreferences(into: &preferences)
        #expect(preferences.subtitleDelays?.count == 1)
    }

    @Test("The second track is saved for the file and shown again when the media loads")
    func secondTrackIsRemembered() throws {
        let host = FakeHost()
        // Reading it fails later; the test doesn't wait for that.
        host.currentSourcePath = "/nonexistent/film.mkv"
        let controller = SubtitleController()
        controller.host = host
        let tracks = [
            SubtitleTrack(id: 0, streamIndex: 2, title: "English", language: "en"),
            SubtitleTrack(id: 1, streamIndex: 3, title: "Українська", language: "uk"),
        ]
        controller.mediaDidLoad(
            tracks: tracks, readFiles: MediaSubtitleFiles(), saved: nil, requestedTrack: "0", audioLanguage: nil)
        controller.secondary.select(trackId: 1)
        #expect(host.saves > 0)

        var preferences = PlaybackPreferences()
        controller.writePreferences(into: &preferences)
        #expect(preferences.secondarySubtitle == tracks[1].persistenceKey)

        // The next load restores it, beside the main track.
        controller.mediaDidLoad(
            tracks: tracks, readFiles: MediaSubtitleFiles(), saved: preferences, requestedTrack: nil,
            audioLanguage: nil)
        #expect(controller.secondary.selectedTrackId == 1)

        controller.secondary.select(trackId: nil)
        controller.writePreferences(into: &preferences)
        #expect(preferences.secondarySubtitle == "")
    }

    @Test(
        "An embedded second track chosen after playback read it shows its cue, from the packets and not a read of the file"
    )
    func embeddedSecondTrackShowsReadPackets() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .uhdHDRSubtitles) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        while demuxer.nextVideoSample() != nil {}
        let host = FakeHost()
        host.demuxer = demuxer
        host.currentSourcePath = path
        host.currentTime = 1
        let controller = SubtitleController()
        controller.host = host
        let tracks = demuxer.subtitleTracks
        controller.mediaDidLoad(
            tracks: tracks, readFiles: MediaSubtitleFiles(), saved: nil, requestedTrack: "0", audioLanguage: nil)
        controller.secondary.select(trackId: tracks[1].id)
        #expect(controller.secondary.isActive)

        // The packets playback read are merged in the background.
        for _ in 0..<100 where controller.secondary.cues.isEmpty {
            controller.updateShown(at: 1)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(controller.secondary.cues.map(\.text) == ["Subtitle 1"])
        #expect(controller.cues.map(\.text) == ["Subtitle 0"])

        controller.secondary.select(trackId: nil)
        #expect(demuxer.subtitleSelection(of: .secondary).streamIndex == -1)
        #expect(controller.secondary.cues.isEmpty)
    }

    @Test("Network tracks of one language and title keep their own delays and second-track choice")
    func identicalNetworkTracksAreTold() throws {
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        let url = { (name: String) in URL(string: "https://example.com/\(name).vtt")! }
        let tracks = [
            SubtitleTrack(id: 1000, title: "", language: "uk", externalURL: url("a")),
            SubtitleTrack(id: 1001, title: "", language: "uk", externalURL: url("b")),
        ]
        controller.mediaDidLoad(
            tracks: tracks, readFiles: MediaSubtitleFiles(), saved: nil, requestedTrack: "1000", audioLanguage: nil)
        controller.secondary.select(trackId: 1001)
        controller.secondary.setDelay(2)
        #expect(controller.delay == 0 && controller.secondary.delay == 2)

        var preferences = PlaybackPreferences()
        controller.writePreferences(into: &preferences)
        #expect(preferences.subtitleDelays?.count == 1)
        controller.mediaDidLoad(
            tracks: tracks, readFiles: MediaSubtitleFiles(), saved: preferences, requestedTrack: "1000",
            audioLanguage: nil)
        #expect(controller.secondary.selectedTrackId == 1001 && controller.secondary.delay == 2)
    }

    @Test("A saved second track the media can't show is kept in what is saved until another is chosen")
    func unrestoredSecondaryIsKept() throws {
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        let tracks = [SubtitleTrack(id: 0, streamIndex: 2, title: "English", language: "en")]
        var saved = PlaybackPreferences(secondarySubtitle: "file:/moved/away.srt#-1")
        controller.mediaDidLoad(
            tracks: tracks, readFiles: MediaSubtitleFiles(), saved: saved, requestedTrack: "0", audioLanguage: nil)
        #expect(!controller.secondary.isActive)
        controller.writePreferences(into: &saved)
        #expect(saved.secondarySubtitle == "file:/moved/away.srt#-1")
    }

    @Test("A second track that can't be read is given up, so the main track keeps its place")
    func unreadableSecondaryIsDropped() async throws {
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).srt")
        controller.mediaDidLoad(
            tracks: [
                SubtitleTrack(id: 0, streamIndex: 2, title: "English", language: "en"),
                SubtitleTrack(id: 1, title: "Missing", language: "uk", externalURL: missing),
            ], readFiles: MediaSubtitleFiles(), saved: nil, requestedTrack: "0", audioLanguage: nil)
        controller.secondary.select(trackId: 1)
        for _ in 0..<100 where controller.secondary.isActive {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.secondary.isActive)
    }

    @Test("A restored second track whose read fails later stays in what is saved")
    func restoredSecondaryFailingLaterIsKept() async throws {
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).srt")
        let tracks = [
            SubtitleTrack(id: 0, streamIndex: 2, title: "English", language: "en"),
            SubtitleTrack(id: 1, title: "Missing", language: "uk", externalURL: missing),
        ]
        var saved = PlaybackPreferences(secondarySubtitle: tracks[1].persistenceKey)
        controller.mediaDidLoad(
            tracks: tracks, readFiles: MediaSubtitleFiles(), saved: saved, requestedTrack: "0", audioLanguage: nil)
        try #require(controller.secondary.isActive)
        for _ in 0..<100 where controller.secondary.isActive {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.secondary.isActive)
        controller.writePreferences(into: &saved)
        #expect(saved.secondarySubtitle == tracks[1].persistenceKey)
    }

    @Test("The encoding is chosen per track, saved with it, and the default doesn't override it")
    func encodingIsPerTrack() async throws {
        let first = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nПривіт\n")
        let second = try subtitleFile("1\n00:00:01,000 --> 00:00:03,000\nHello\n")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let host = FakeHost()
        let controller = SubtitleController()
        controller.host = host
        await controller.addExternal(url: first)
        let firstId = try #require(controller.selectedTrackId)
        let secondId = try #require(controller.addExternalFile(url: second).first)
        let cp1251 = try #require(TextFileEncoding.encoding(named: "windows-1251"))
        let cp1250 = try #require(TextFileEncoding.encoding(named: "windows-1250"))

        controller.setEncoding(cp1251, ofTrack: firstId)
        controller.setEncoding(cp1250, ofTrack: secondId)
        #expect(controller.encoding(ofTrack: firstId) == cp1251 && controller.encoding(ofTrack: secondId) == cp1250)

        var preferences = PlaybackPreferences()
        controller.writePreferences(into: &preferences)
        #expect(Set((preferences.subtitleEncodings ?? [:]).values) == ["windows-1251", "windows-1250"])

        // A new default doesn't touch a track with a choice of its own.
        controller.setDefaultEncoding(.isoLatin2)
        #expect(controller.effectiveEncoding(of: try #require(controller.tracks.first)) == cp1251)

        // Back to the default.
        controller.setEncoding(nil, ofTrack: firstId)
        #expect(controller.effectiveEncoding(of: try #require(controller.tracks.first)) == .isoLatin2)
        controller.writePreferences(into: &preferences)
        #expect(preferences.subtitleEncodings?.count == 1)
    }

    @Test("Only a text file has an encoding to choose")
    func embeddedTracksHaveNoEncoding() {
        let controller = SubtitleController()
        let host = FakeHost()
        controller.host = host
        controller.mediaDidLoad(
            tracks: [SubtitleTrack(id: 0, streamIndex: 2, title: "English", language: "en")],
            readFiles: MediaSubtitleFiles(), saved: nil, requestedTrack: "0", audioLanguage: nil)
        #expect(!controller.canSetEncoding(ofTrack: 0))
        controller.setEncoding(.windowsCP1251, ofTrack: 0)
        #expect(controller.encoding(ofTrack: 0) == nil)
    }
}
