import Foundation
import Testing
import os

@testable import NitsCore

/// Pages resolved into streams before the media opens (`PlayerEngine.mediaResolver`).
@Suite("Media resolver", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct MediaResolverTests {
    /// Resolves the pages under `/watch` into `resolved`, asked `order`; counts the pages it was asked for.
    final class StubResolver: MediaResolver {
        let resolved: Result<ResolvedMedia?, MediaResolutionError>
        let resolutionOrder: MediaResolutionOrder
        private let asked = OSAllocatedUnfairLock(initialState: [URL]())

        init(_ resolved: Result<ResolvedMedia?, MediaResolutionError>, order: MediaResolutionOrder = .beforeOpening) {
            self.resolved = resolved
            self.resolutionOrder = order
        }

        var pages: [URL] { asked.withLock { $0 } }

        func order(for url: URL) -> MediaResolutionOrder? { url.path == "/watch" ? resolutionOrder : nil }

        func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
            asked.withLock { $0.append(url) }
            return try resolved.get()
        }
    }

    @Test(
        "A page plays its streams, each with its headers, and the history and title go by the page, which is resolved again on each load"
    )
    func playsResolvedPage() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let videoURL = URL(fileURLWithPath: video)
        let audioURL = URL(fileURLWithPath: audio)
        try #require(videoURL.deletingLastPathComponent() == audioURL.deletingLastPathComponent())
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        // The host's own dub, beside the page's audio.
        let audioContents = try Data(contentsOf: audioURL)
        server.setResponder(forPath: "dub") { audioContents }
        let remoteAudio = try #require(URL(string: server.url(audioURL.lastPathComponent)))
        let resolver = StubResolver(
            .success(
                ResolvedMedia(
                    path: server.url(videoURL.lastPathComponent), headers: ["User-Agent": "NitsTest"],
                    audioFiles: [
                        .init(
                            url: remoteAudio, title: "Ukrainian, original", language: "ukr",
                            headers: ["User-Agent": "NitsAudio"], isRequired: true)
                    ],
                    title: "A page's video", historyKey: "video.example:nits")))
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.mediaResolver = resolver
        let page = "https://video.example/watch?v=nits"
        let dub = try #require(URL(string: server.url("dub")))

        // From the playlist, where the page was before its title was known.
        let pageURL = try #require(URL(string: page))
        engine.playlist.replaceAll(items: [PlaylistItem(url: pageURL)])
        engine.load(
            MediaLoadRequest(path: page, headers: ["User-Agent": "NitsHost"], audioFiles: [.init(url: dub)]))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        #expect(engine.currentPath == page)
        #expect(engine.mediaTitle == "A page's video")
        #expect(engine.playlist.currentItem?.title == "A page's video")
        let selected = try #require(engine.audioTracks.first { $0.id == engine.selectedAudioTrackId })
        #expect(selected.externalURL == remoteAudio)
        #expect(selected.title == "Ukrainian, original")
        #expect(selected.language == "ukr")
        #expect(engine.audioTracks.contains { $0.externalURL == dub }, "The host's file isn't a track")
        #expect(!engine.isBuffering)
        let agents = { (path: String) in Set(server.requests.filter { $0.path == path }.map(\.userAgent)) }
        #expect(agents(videoURL.lastPathComponent) == ["NitsTest"])
        #expect(agents(audioURL.lastPathComponent) == ["NitsAudio"])
        #expect(agents("dub") == ["NitsHost"], "The host's file wasn't read with the request's headers")

        // Saved under the resolver's name, not the page's URL (whose query the history drops) or the stream's.
        engine.setAudioDelay(0.1)
        engine.saveCurrentPlaybackProgress()
        #expect(
            engine.historyStore.savedPreferences(for: MediaHistoryIdentity(historyKey: "video.example:nits"))?
                .audioDelay == 0.1)
        #expect(engine.historyStore.savedPreferences(for: MediaHistoryIdentity(historyKey: page)) == nil)
        #expect(
            engine.historyStore.savedPreferences(
                for: MediaHistoryIdentity(historyKey: server.url(videoURL.lastPathComponent))) == nil)

        engine.load(MediaLoadRequest(path: page))
        await engine.waitForPendingLoad()
        #expect(resolver.pages.count == 2)
        #expect(engine.audioDelay == 0.1, "The history wasn't read by the resolver's name")
    }

    @Test("A page's streams are read in HTTP requests of the size it gives each, which the host's files don't take")
    func readsInRequestsOfResolvedSize() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let videoURL = URL(fileURLWithPath: video)
        let audioURL = URL(fileURLWithPath: audio)
        try #require(videoURL.deletingLastPathComponent() == audioURL.deletingLastPathComponent())
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let audioContents = try Data(contentsOf: audioURL)
        server.setResponder(forPath: "dub") { audioContents }
        let (videoSize, audioSize) = (64 << 10, 32 << 10)
        let resolver = StubResolver(
            .success(
                ResolvedMedia(
                    path: server.url(videoURL.lastPathComponent),
                    audioFiles: [
                        .init(
                            url: try #require(URL(string: server.url(audioURL.lastPathComponent))), isRequired: true,
                            httpRequestSize: audioSize)
                    ],
                    httpRequestSize: videoSize)))
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.mediaResolver = resolver

        let dub = try #require(URL(string: server.url("dub")))
        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=nits", audioFiles: [.init(url: dub)]))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.5))

        /// The lengths of the ranges asked for `path`; `nil` for one open to the end of the file.
        let lengths = { (path: String) in
            server.requests.filter { $0.path == path }.map { request -> Int? in
                guard let range = request.range?.replacingOccurrences(of: "bytes=", with: ""),
                    let dash = range.firstIndex(of: "-"), let start = Int(range[..<dash]),
                    let end = Int(range[range.index(after: dash)...])
                else { return nil }
                return end - start + 1
            }
        }
        let videoLengths = lengths(videoURL.lastPathComponent)
        #expect(videoLengths.count > 1, "Read in \(videoLengths.count) request(s)")
        #expect(videoLengths.allSatisfy { $0 != nil && $0! <= videoSize }, "Asked for \(videoLengths)")
        let audioLengths = lengths(audioURL.lastPathComponent)
        #expect(!audioLengths.isEmpty && audioLengths.allSatisfy { $0 != nil && $0! <= audioSize })
        #expect(lengths("dub").contains { $0 == nil }, "The host's file was read in the page's requests")
    }

    @Test("An audio file declared with its stream is listed unopened and opened when its track is selected")
    func opensDeclaredAudioWhenSelected() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let audioContents = try Data(contentsOf: URL(fileURLWithPath: audio))
        server.setResponder(forPath: "dub") { audioContents }
        server.setResponder(forPath: "original") { audioContents }
        let dub = try #require(URL(string: server.url("dub")))
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }

        engine.load(
            MediaLoadRequest(
                path: server.url(videoURL.lastPathComponent),
                audioFiles: [
                    .init(url: try #require(URL(string: server.url("original"))), language: "uk", isRequired: true),
                    .init(
                        url: dub, title: "FLAC, dubbed", language: "en",
                        declaredStream: .init(codecName: "flac", channels: 2, sampleRate: 48000)),
                ]))
        await engine.waitForPendingLoad()
        let track = try #require(engine.audioTracks.first { $0.externalURL == dub })
        #expect(track.language == "en" && track.title == "FLAC, dubbed")
        #expect(server.requests.filter { $0.path == "dub" }.isEmpty, "The file was opened to list its track")

        engine.selectAudioTrack(id: track.id)
        for _ in 0..<100 where engine.selectedAudioTrackId != track.id {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.selectedAudioTrackId == track.id)
        #expect(!server.requests.filter { $0.path == "dub" }.isEmpty)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
    }

    @Test("A declared file in the preferred language is opened before the media starts")
    func opensDeclaredAudioInPreferredLanguage() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let audioContents = try Data(contentsOf: URL(fileURLWithPath: audio))
        server.setResponder(forPath: "dub") { audioContents }
        server.setResponder(forPath: "original") { audioContents }
        let engine = PlayerEngine.makeForTesting(
            configuration: PlayerConfiguration(
                resumePlayback: false, trackLanguages: TrackLanguagePreferences(audioLanguages: ["en"])))
        defer { engine.stop() }

        engine.load(
            MediaLoadRequest(
                path: server.url(videoURL.lastPathComponent),
                audioFiles: [
                    .init(url: try #require(URL(string: server.url("original"))), language: "uk", isRequired: true),
                    .init(
                        url: try #require(URL(string: server.url("dub"))), language: "en",
                        declaredStream: .init(codecName: "flac")),
                ]))
        await engine.waitForPendingLoad()
        let selected = try #require(engine.audioTracks.first { $0.id == engine.selectedAudioTrackId })
        #expect(selected.language == "en")
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
    }

    @Test(
        "Another picture of the page plays from the position it was left at, its audio kept, without asking the resolver again"
    )
    func switchesVideoFormat() async throws {
        guard let first = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let second = SyntheticTestMediaFactory.ensureMedia(preset: .vp9SDR),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let (firstURL, secondURL) = (URL(fileURLWithPath: first), URL(fileURLWithPath: second))
        try #require(firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent())
        let server = try TestHTTPServer(root: firstURL.deletingLastPathComponent())
        defer { server.stop() }
        let audioContents = try Data(contentsOf: URL(fileURLWithPath: audio))
        server.setResponder(forPath: "audio") { audioContents }
        let (firstPath, secondPath) = (server.url(firstURL.lastPathComponent), server.url(secondURL.lastPathComponent))
        let resolver = StubResolver(
            .success(
                ResolvedMedia(
                    path: firstPath,
                    audioFiles: [.init(url: try #require(URL(string: server.url("audio"))), isRequired: true)],
                    videoFormats: [
                        VideoFormat(id: "a", url: firstPath, width: 640, height: 360, codec: "H.264"),
                        VideoFormat(id: "b", url: secondPath, width: 320, height: 180, codec: "VP9"),
                    ], selectedVideoFormatID: "a")))
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.mediaResolver = resolver

        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=nits"))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        #expect(engine.videoFormats.map(\.id) == ["a", "b"] && engine.selectedVideoFormatId == "a")
        let audioFile = try #require(engine.audioTracks.first { $0.externalURL != nil }).externalURL

        engine.selectVideoFormat(id: "b")
        await engine.waitForPendingLoad()
        #expect(engine.selectedVideoFormatId == "b")
        #expect(engine.currentSourcePath == secondPath)
        #expect(engine.currentPath == "https://video.example/watch?v=nits")
        #expect(engine.audioTracks.contains { $0.externalURL == audioFile }, "The page's audio was lost")
        #expect(resolver.pages.count == 1, "The page was resolved again")
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
    }

    /// Asked for a page again, tells `answers` in turn (the last one for any later).
    final class SequenceResolver: MediaResolver {
        private let answers: [ResolvedMedia]
        private let asked = OSAllocatedUnfairLock(initialState: 0)

        init(_ answers: [ResolvedMedia]) { self.answers = answers }

        var count: Int { asked.withLock { $0 } }

        func order(for url: URL) -> MediaResolutionOrder? { url.path == "/watch" ? .beforeOpening : nil }

        func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
            let index = asked.withLock { count -> Int in
                defer { count += 1 }
                return count
            }
            return answers[min(index, answers.count - 1)]
        }
    }

    @Test("Resolved streams that don't open are asked for once more, on the first load and when switching formats")
    func asksResolverAgainWhenFormatExpired() async throws {
        guard let first = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let second = SyntheticTestMediaFactory.ensureMedia(preset: .vp9SDR)
        else { return }
        let (firstURL, secondURL) = (URL(fileURLWithPath: first), URL(fileURLWithPath: second))
        try #require(firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent())
        let server = try TestHTTPServer(root: firstURL.deletingLastPathComponent())
        defer { server.stop() }
        let (firstPath, secondPath) = (server.url(firstURL.lastPathComponent), server.url(secondURL.lastPathComponent))
        let expired = server.url("expired.mp4")
        let formats = { (secondURL: String) in
            [
                VideoFormat(id: "a", url: firstPath, width: 640, height: 360, codec: "H.264"),
                VideoFormat(id: "b", url: secondURL, width: 320, height: 180, codec: "VP9"),
            ]
        }
        // The first resolution's stream doesn't open, so the load asks again; the second's link for format "b" has
        // expired by the time it is chosen, so switching formats asks again too. After that, only expired links are
        // returned: the next load asks once more (2 calls for that load) and fails without looping.
        let resolver = SequenceResolver([
            ResolvedMedia(path: expired, videoFormats: formats(expired), selectedVideoFormatID: "a"),
            ResolvedMedia(path: firstPath, videoFormats: formats(expired), selectedVideoFormatID: "a"),
            ResolvedMedia(path: firstPath, videoFormats: formats(secondPath), selectedVideoFormatID: "a"),
            ResolvedMedia(path: expired, videoFormats: formats(expired), selectedVideoFormatID: "a"),
        ])
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.mediaResolver = resolver

        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=nits"))
        await engine.waitForPendingLoad()
        #expect(resolver.count == 2, "The resolver was asked \(resolver.count) time(s) on the first load")
        #expect(engine.currentSourcePath == firstPath)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))

        engine.selectVideoFormat(id: "b")
        await engine.waitForPendingLoad()
        #expect(resolver.count == 3, "The resolver was asked \(resolver.count) time(s)")
        #expect(engine.selectedVideoFormatId == "b" && engine.currentSourcePath == secondPath)
        #expect(engine.playbackState != .failed(engine.loadError ?? ""))
        try #require(await engine.waitForPlayback(advancingBy: 0.3))

        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=nits"))
        await engine.waitForPendingLoad()
        #expect(resolver.count == 5, "The resolver was asked \(resolver.count - 3) time(s) when both answers failed")
        #expect(engine.loadError != nil && engine.playbackState == .failed(engine.loadError ?? ""))
    }

    @Test("A declared audio file that can't be opened is dropped from the tracks, the one playing staying")
    func dropsDeclaredAudioThatWontOpen() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let audioContents = try Data(contentsOf: URL(fileURLWithPath: audio))
        server.setResponder(forPath: "original") { audioContents }
        let gone = try #require(URL(string: server.url("gone.mka")))
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }

        engine.load(
            MediaLoadRequest(
                path: server.url(videoURL.lastPathComponent),
                audioFiles: [
                    .init(url: try #require(URL(string: server.url("original"))), language: "uk", isRequired: true),
                    .init(url: gone, language: "en", declaredStream: .init(codecName: "flac")),
                ]))
        await engine.waitForPendingLoad()
        let playing = engine.selectedAudioTrackId
        let declared = try #require(engine.audioTracks.first { $0.externalURL == gone })

        engine.selectAudioTrack(id: declared.id)
        for _ in 0..<100 where engine.audioTracks.contains(where: { $0.externalURL == gone }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!engine.audioTracks.contains { $0.externalURL == gone }, "The track stayed offered")
        #expect(engine.selectedAudioTrackId == playing)
    }

    @Test("Choosing the track playing while another's file opens cancels that choice")
    func laterChoiceCancelsAwaitedTrack() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let audioContents = try Data(contentsOf: URL(fileURLWithPath: audio))
        server.setResponder(forPath: "original") { audioContents }
        server.setResponder(forPath: "dub") { audioContents }
        server.setBehavior(TestHTTPServer.Behavior(delay: .seconds(1)), forPaths: { $0 == "dub" })
        let dub = try #require(URL(string: server.url("dub")))
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }

        engine.load(
            MediaLoadRequest(
                path: server.url(videoURL.lastPathComponent),
                audioFiles: [
                    .init(url: try #require(URL(string: server.url("original"))), language: "uk", isRequired: true),
                    .init(url: dub, language: "en", declaredStream: .init(codecName: "flac")),
                ]))
        await engine.waitForPendingLoad()
        let playing = engine.selectedAudioTrackId
        let declared = try #require(engine.audioTracks.first { $0.externalURL == dub })

        engine.selectAudioTrack(id: declared.id)
        engine.selectAudioTrack(id: playing)
        try await Task.sleep(for: .seconds(2.5))
        #expect(
            engine.selectedAudioTrackId == playing, "The file's opening switched the sound after the choice was undone")
    }

    @Test("A page with nothing to play fails the load with the resolver's reason; other URLs aren't resolved")
    func failsWithReason() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let resolver = StubResolver(.failure(MediaResolutionError("Video unavailable")))
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.mediaResolver = resolver

        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=gone"))
        await engine.waitForPendingLoad()
        #expect(engine.playbackState == .failed("Video unavailable"))
        #expect(engine.loadError == "Video unavailable")

        engine.load(MediaLoadRequest(path: video))
        try #require(await engine.waitForPlayback(advancingBy: 0.2))
        #expect(resolver.pages.count == 1)
    }

    @Test("A URL the resolver declines opens as it is, under its own name")
    func opensDeclinedURL() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let contents = try Data(contentsOf: videoURL)
        server.setResponder(forPath: "watch") { contents }
        let resolver = StubResolver(.success(nil))
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.mediaResolver = resolver
        let stream = server.url("watch")

        engine.load(MediaLoadRequest(path: stream))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        #expect(resolver.pages.count == 1)
        #expect(engine.currentPath == stream)
        #expect(engine.currentSourcePath == stream)
    }

    @Test("A URL resolved after opening fails is asked only once it didn't open as media")
    func resolvesAfterOpeningFails() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let contents = try Data(contentsOf: videoURL)
        let isPage = OSAllocatedUnfairLock(initialState: false)
        server.setResponder(forPath: "watch") {
            isPage.withLock { $0 } ? Data("<!doctype html><html><body>A page</body></html>".utf8) : contents
        }
        let resolver = StubResolver(
            .success(ResolvedMedia(path: server.url(videoURL.lastPathComponent), title: "Found in the page")),
            order: .afterOpeningFails)
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.mediaResolver = resolver
        let url = server.url("watch")

        // Media itself (a media server's stream): opened without the resolver.
        engine.load(MediaLoadRequest(path: url))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.2))
        #expect(resolver.pages.isEmpty)

        isPage.withLock { $0 = true }
        engine.load(MediaLoadRequest(path: url))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.2))
        #expect(resolver.pages.count == 1)
        #expect(engine.mediaTitle == "Found in the page")
        #expect(engine.currentSourcePath == server.url(videoURL.lastPathComponent))
    }

    @Test("A page's own audio that can't be read fails the load; a file the host adds is left out")
    func failsWithoutRequiredAudio() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let missing = try #require(URL(string: server.url("missing-audio")))
        let page = "https://video.example/watch?v=nits"
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }

        engine.mediaResolver = StubResolver(
            .success(
                ResolvedMedia(
                    path: server.url(videoURL.lastPathComponent), audioFiles: [.init(url: missing, isRequired: true)])))
        engine.load(MediaLoadRequest(path: page))
        await engine.waitForPendingLoad()
        guard case .failed(let reason) = engine.playbackState else {
            Issue.record("Played without its audio: \(engine.playbackState)")
            return
        }
        #expect(reason.contains("audio"))
        // Opened again before giving up, as the media is.
        #expect(server.requests.filter { $0.path == "missing-audio" }.count >= 3)

        engine.mediaResolver = StubResolver(
            .success(ResolvedMedia(path: server.url(videoURL.lastPathComponent), audioFiles: [.init(url: missing)])))
        engine.load(MediaLoadRequest(path: page))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.2))
    }

    @Test("Asked once the URL failed to open, a resolver that only failed to read it too leaves the demuxer's reason")
    func keepsDemuxerReasonAfterOpeningFails() async throws {
        let root = FileManager.default.temporaryDirectory
        let server = try TestHTTPServer(root: root)
        defer { server.stop() }
        server.setResponder(forPath: "watch") { Data("<!doctype html><html><body>A page</body></html>".utf8) }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        let url = server.url("watch")

        let unreadable = MediaResolutionError("HTTP Error 401: Unauthorized", isAboutPage: false)
        engine.mediaResolver = StubResolver(.failure(unreadable), order: .afterOpeningFails)
        engine.load(MediaLoadRequest(path: url))
        await engine.waitForPendingLoad()
        guard case .failed(let reason) = engine.playbackState else {
            Issue.record("Didn't fail: \(engine.playbackState)")
            return
        }
        #expect(reason != unreadable.message)

        let unavailable = MediaResolutionError("Video unavailable")
        engine.mediaResolver = StubResolver(.failure(unavailable), order: .afterOpeningFails)
        engine.load(MediaLoadRequest(path: url))
        await engine.waitForPendingLoad()
        #expect(engine.playbackState == .failed("Video unavailable"))
    }

    @Test("A resolved page's chapters and action buttons apply when the container stream has none")
    func appliesResolvedChaptersAndActionButtons() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let chapters = [
            MediaChapter(id: 0, title: "Intro", start: 0, end: 1),
            MediaChapter(id: 1, title: "Outro", start: 1, end: 2),
        ]
        let buttons = [
            PlaybackActionButton(id: "sponsorblock-0", title: "Skip Sponsor", start: 0.5, end: 1.5, seeksToEnd: true)
        ]
        let resolver = StubResolver(
            .success(
                ResolvedMedia(
                    path: server.url(videoURL.lastPathComponent),
                    chapters: chapters,
                    actionButtons: buttons
                )
            )
        )
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.mediaResolver = resolver
        let page = "https://video.example/watch?v=ch-test"

        let hostButton = PlaybackActionButton(id: "host-next", title: "Next Episode", start: 2.0)
        engine.load(MediaLoadRequest(path: page, actionButtons: [hostButton]))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.2))

        #expect(engine.media.chapters.count == 2)
        #expect(engine.media.chapters.map(\.title) == ["Intro", "Outro"])
        #expect(engine.actionButtons.contains { $0.id == "host-next" })
        #expect(engine.actionButtons.contains { $0.id == "sponsorblock-0" })
    }

    @Test("seeksToEnd button triggers seek in engine even when host has onActionButton handler")
    func seeksToEndButtonSeeksEvenWhenHostSetsHandler() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let button = PlaybackActionButton(
            id: "sponsorblock-0", title: "Skip Sponsor", start: 0.5, end: 1.5, seeksToEnd: true)
        let resolver = StubResolver(
            .success(ResolvedMedia(path: server.url(videoURL.lastPathComponent), actionButtons: [button]))
        )
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.mediaResolver = resolver

        var hostPressed: [String] = []
        engine.onActionButton = { hostPressed.append($0) }
        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=seek-test"))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.2))

        engine.performActionButton(button)
        #expect(await engine.waitForSeekToSettle())
        #expect(engine.currentTime >= 1.45)
        #expect(hostPressed.isEmpty, "Host handler should not receive buttons handled directly by the engine")
    }

    @Test("Host action button without seeksToEnd dispatches to onActionButton and does not seek")
    func hostButtonWithoutSeeksToEndDispatchesToHostHandler() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let hostButton = PlaybackActionButton(id: "host-next", title: "Next Episode", start: 0.5, end: 2.0)
        let resolver = StubResolver(.success(ResolvedMedia(path: server.url(videoURL.lastPathComponent))))
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.mediaResolver = resolver

        var hostPressed: [String] = []
        engine.onActionButton = { hostPressed.append($0) }
        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=host-test", actionButtons: [hostButton]))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.2))

        let positionBefore = engine.currentTime
        engine.performActionButton(hostButton)
        #expect(hostPressed == ["host-next"])
        #expect(abs(engine.currentTime - positionBefore) < 0.5, "Engine should not seek for host-managed buttons")
    }

    @Test("setActionButtons during playback preserves resolved buttons from media")
    func setActionButtonsPreservesResolvedButtons() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let videoURL = URL(fileURLWithPath: video)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }
        let resolvedButton = PlaybackActionButton(
            id: "sponsorblock-0", title: "Skip Sponsor", start: 0.5, end: 1.5, seeksToEnd: true)
        let resolver = StubResolver(
            .success(ResolvedMedia(path: server.url(videoURL.lastPathComponent), actionButtons: [resolvedButton]))
        )
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.mediaResolver = resolver

        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=merge-test"))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.2))
        #expect(engine.actionButtons.map(\.id) == ["sponsorblock-0"])

        // Host updates its action buttons mid-stream (e.g. Next Episode becomes known)
        let hostButton = PlaybackActionButton(id: "host-next", title: "Next Episode", start: 2.0)
        engine.setActionButtons([hostButton])
        #expect(engine.actionButtons.contains { $0.id == "sponsorblock-0" })
        #expect(engine.actionButtons.contains { $0.id == "host-next" })

        // Host clears its action buttons
        engine.setActionButtons([])
        #expect(engine.actionButtons.map(\.id) == ["sponsorblock-0"])
    }

    @Test(
        "A page's subtitle tracks are listed without fetching them, fetched with their headers when selected, and kept across video format switches"
    )
    func loadsResolvedSubtitlesOnDemandAndKeepsAcrossFormatSwitch() async throws {
        guard let first = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264),
            let second = SyntheticTestMediaFactory.ensureMedia(preset: .vp9SDR)
        else { return }
        let (firstURL, secondURL) = (URL(fileURLWithPath: first), URL(fileURLWithPath: second))
        try #require(firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent())
        let server = try TestHTTPServer(root: firstURL.deletingLastPathComponent())
        defer { server.stop() }
        let vtt = """
            WEBVTT

            00:00:00.000 --> 00:00:10.000
            Hello from YouTube VTT
            """
        server.setResponder(forPath: "timedtext_en") { Data(vtt.utf8) }
        server.setResponder(forPath: "timedtext_uk") { Data(vtt.utf8) }
        let (firstPath, secondPath) = (server.url(firstURL.lastPathComponent), server.url(secondURL.lastPathComponent))
        let subEn = try #require(URL(string: server.url("timedtext_en")))
        let subUk = try #require(URL(string: server.url("timedtext_uk")))
        let resolver = StubResolver(
            .success(
                ResolvedMedia(
                    path: firstPath,
                    headers: ["User-Agent": "NitsPage"],
                    subtitleFiles: [
                        .init(
                            url: subEn, title: "English", language: "en",
                            headers: ["User-Agent": "NitsSubEn"]),
                        .init(
                            url: subUk, title: "Ukrainian (auto-generated)", language: "uk",
                            isAutoGenerated: true),
                    ],
                    videoFormats: [
                        VideoFormat(id: "a", url: firstPath, width: 640, height: 360, codec: "H.264"),
                        VideoFormat(id: "b", url: secondPath, width: 320, height: 180, codec: "VP9"),
                    ],
                    selectedVideoFormatID: "a")))
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.mediaResolver = resolver

        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=subs"))
        await engine.waitForPendingLoad()
        try #require(await engine.waitForPlayback(advancingBy: 0.2))

        #expect(engine.subtitles.tracks.count == 2)
        #expect(engine.subtitles.tracks.map(\.title) == ["English", "Ukrainian (auto-generated)"])
        #expect(engine.subtitles.tracks.map(\.isAutoGenerated) == [false, true])
        #expect(engine.subtitles.selectedTrackId == nil)
        #expect(server.requests.filter { $0.path.hasPrefix("timedtext_") }.isEmpty)

        let englishTrack = try #require(engine.subtitles.tracks.first { $0.language == "en" })
        engine.subtitles.select(trackId: englishTrack.id)
        for _ in 0..<100 where engine.subtitles.activeDocument == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.subtitles.selectedTrackId == englishTrack.id)
        #expect(engine.subtitles.activeDocument?.cues.first?.text == "Hello from YouTube VTT")
        #expect(server.requests.filter { $0.path == "timedtext_en" }.map(\.userAgent) == ["NitsSubEn"])
        #expect(server.requests.filter { $0.path == "timedtext_uk" }.isEmpty)

        // Switching video format keeps the selected subtitle track and reuses its downloaded document.
        engine.selectVideoFormat(id: "b")
        await engine.waitForPendingLoad()
        #expect(engine.selectedVideoFormatId == "b")
        #expect(engine.subtitles.selectedTrackId == englishTrack.id)
        #expect(engine.subtitles.activeDocument?.cues.first?.text == "Hello from YouTube VTT")
        #expect(server.requests.filter { $0.path == "timedtext_en" }.count == 1)
    }
}
