import Foundation
import Testing

@testable import NitsCore

/// `SubtitleController` on its own, against a host without media: what it does with subtitle files needs no engine.
@Suite("SubtitleController")
@MainActor
struct SubtitleControllerTests {
    @MainActor
    final class FakeHost: SubtitleHost {
        var demuxer: MediaDemuxer? { nil }
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
        #expect(preferences.subtitleDelay == -0.5)

        controller.timeDidChange(to: 2, .tick)
        controller.reset()
        #expect(controller.tracks.isEmpty && controller.selectedTrackId == nil && controller.cues.isEmpty)
    }
}
