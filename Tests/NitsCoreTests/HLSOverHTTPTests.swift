import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// HLS served by `TestHTTPServer`: FFmpeg's HLS demuxer reads it as it reads any HTTP stream.
@Suite("HLS over HTTP")
struct HLSOverHTTPTests {
    private static func server() throws -> TestHTTPServer? {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return nil }
        return try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
    }

    /// Segments of a variant (`v0_001.ts` is the first variant's second segment).
    private static func segments(of variant: Int, in requests: [TestHTTPServer.Request]) -> [String] {
        requests.map(\.path).filter { $0.hasPrefix("v\(variant)_") && $0.hasSuffix(".ts") }
    }

    @Test("The server answers ranges, unknown paths and failures as set")
    func serverBasics() async throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let master = try #require(URL(string: server.url("master.m3u8")))

        let (body, response) = try await URLSession.shared.data(from: master)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).hasPrefix("#EXTM3U"))

        var ranged = URLRequest(url: master)
        ranged.setValue("bytes=1-6", forHTTPHeaderField: "Range")
        let (part, partResponse) = try await URLSession.shared.data(for: ranged)
        #expect((partResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(String(decoding: part, as: UTF8.self) == "EXTM3U")

        let missing = try #require(URL(string: server.url("missing.ts")))
        #expect((try await URLSession.shared.data(from: missing).1 as? HTTPURLResponse)?.statusCode == 404)

        server.setBehavior(.init(failure: .status(503)), forPaths: { $0 == "master.m3u8" })
        #expect((try await URLSession.shared.data(from: master).1 as? HTTPURLResponse)?.statusCode == 503)
        #expect(server.requests.map(\.path) == ["master.m3u8", "master.m3u8", "missing.ts", "master.m3u8"])
    }

    @Test("A throttled response arrives at about the rate set", .hostDependent)
    func throttles() async throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let segment = try #require(URL(string: server.url("v1_000.ts")))
        let size = try await URLSession.shared.data(from: segment).0.count

        server.setDefaultBehavior(.init(bytesPerSecond: size * 2))
        let start = ContinuousClock.now
        _ = try await URLSession.shared.data(from: segment)
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        #expect((0.4...0.8).contains(elapsed), "\(size) bytes at \(size * 2) B/s took \(elapsed) s")
    }

    @Test("Read ahead over HTTP, every frame plays and only the selected variant's segments are fetched")
    func readsSelectedVariantOnly() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        #expect(demuxer.variants.count == 2)
        let opened = server.requests.count
        demuxer.startReadAhead()

        var pictures = 0
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures == 180)
        while demuxer.nextAudioPacket() != nil {}
        #expect(demuxer.isEOF)
        // Opening probes the first segment of every variant; after that only the selected (high) one is read.
        let afterOpening = Array(server.requests.dropFirst(opened))
        #expect(Self.segments(of: 0, in: afterOpening).isEmpty, "\(afterOpening.map(\.path))")
        #expect(Set(Self.segments(of: 1, in: server.requests)) == ["v1_000.ts", "v1_001.ts", "v1_002.ts"])
    }

    @Test("A saved playlist of segments on the network is opened and read as a network source")
    func savedPlaylistOfNetworkSegments() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let root = try #require(SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants))
        #expect(!MediaURL.isNetworkSource(root))
        let playlist = try String(
            contentsOf: URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("v1.m3u8"),
            encoding: .utf8)
        let saved = playlist.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix(".ts") ? server.url(String(line)) : String(line)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("saved.m3u8").path
        try saved.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let demuxer = try #require(MediaDemuxer(url: path))
        #expect(demuxer.isNetworkSource)
        demuxer.startReadAhead()
        var pictures = 0
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures == 180)
        #expect(Set(Self.segments(of: 1, in: server.requests)) == ["v1_000.ts", "v1_001.ts", "v1_002.ts"])

        // Subtitle windows and the index are read by a demuxer of their own, opened the same way.
        var window = EmbeddedSubtitleReader.openInput(url: path, headers: [:], interrupt: nil)
        #expect(window != nil, "The subtitle reader couldn't open the saved playlist")
        avformat_close_input(&window)
    }
}

/// Audio and subtitle renditions (`EXT-X-MEDIA`): each a playlist of its own, downloaded only while selected.
@Suite("HLS renditions over HTTP")
struct HLSRenditionTests {
    private static func open() throws -> (TestHTTPServer, MediaDemuxer, opened: Int)? {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsRenditions) else { return nil }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        return (server, demuxer, server.requests.count)
    }

    private static func readAll(_ demuxer: MediaDemuxer) {
        while demuxer.nextVideoSample() != nil {}
        while demuxer.nextAudioPacket() != nil {}
    }

    /// Segment paths requested after the first `skipping` requests.
    private static func paths(_ server: TestHTTPServer, after skipping: Int) -> [String] {
        server.requests.dropFirst(skipping).map(\.path)
    }

    @Test("Renditions are named by their NAME, and an audio description isn't chosen on load")
    func namesAndAudioDescriptions() throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsRenditions) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        // English, listed first and `DEFAULT=YES`, as an audio description (Apple lists theirs so, `DEFAULT=NO`).
        let text = try String(contentsOfFile: master, encoding: .utf8)
        server.setResponder(forPath: "master.m3u8") {
            Data(
                text.replacingOccurrences(
                    of: "NAME=\"audio_2\",",
                    with: "NAME=\"audio_2\",CHARACTERISTICS=\"public.accessibility.describes-video\","
                )
                .utf8)
        }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        #expect(demuxer.audioTracks.map(\.title) == ["audio_2", "audio_3"])
        #expect(demuxer.audioTracks.map(\.describesVideo) == [true, false])
        #expect(demuxer.subtitleTracks.map(\.title) == ["subtitle_0", "subtitle_1"])
        #expect(TrackAutoSelection.audioTrackId(in: demuxer.audioTracks, languages: []) == 1)
    }

    @Test("Only the selected audio rendition is downloaded, and no subtitles until one is selected")
    func downloadsSelectedRenditionOnly() throws {
        guard let (server, demuxer, opened) = try Self.open() else { return }
        defer { server.stop() }
        #expect(demuxer.audioTracks.map(\.language) == ["eng", "ukr"])
        #expect(demuxer.subtitleTracks.count == 2)
        demuxer.startReadAhead()
        Self.readAll(demuxer)

        let fetched = Self.paths(server, after: opened)
        #expect(fetched.contains { $0.hasPrefix("vEnglish_") })
        #expect(!fetched.contains { $0.hasPrefix("vUkrainian_") }, "\(fetched)")
        #expect(!fetched.contains { $0.hasSuffix(".vtt") || $0.contains("_vtt") }, "\(fetched)")
    }

    @Test("Selecting another audio track or a subtitle track downloads it from the seek that follows")
    func selectionDownloadsFromSeek() throws {
        guard let (server, demuxer, opened) = try Self.open() else { return }
        defer { server.stop() }
        demuxer.startReadAhead()
        _ = demuxer.nextVideoSample()

        let ukrainian = try #require(demuxer.audioTracks.first { $0.language == "ukr" })
        demuxer.selectAudioTrack(trackId: ukrainian.id)
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        let beforeSeek = server.requests.count
        demuxer.seek(to: 2.5)
        Self.readAll(demuxer)

        let fetched = Self.paths(server, after: beforeSeek)
        #expect(fetched.contains { $0.hasPrefix("vUkrainian_") }, "\(fetched)")
        #expect(!fetched.contains { $0.hasPrefix("vEnglish_") }, "\(fetched)")
        #expect(fetched.contains { $0.hasSuffix(".vtt") }, "\(fetched)")
        #expect(server.requests.count > opened)
    }

    @Test("An audio track selected during a variant switch is the one read after it")
    func audioTrackSelectedDuringSwitch() throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsRenditions) else { return }
        let demuxer = try #require(MediaDemuxer(url: master))
        let low = try #require(demuxer.variants.last)
        // Mid-GOP (30 frames): the switch waits for the new variant's keyframe at 2 s.
        for _ in 0..<45 { _ = demuxer.nextVideoSample() }
        demuxer.selectVariant(id: low.id)
        _ = demuxer.nextVideoSample()
        try #require(demuxer.variantSwitch != nil)

        let ukrainian = try #require(demuxer.audioTracks.first { $0.language == "ukr" })
        demuxer.selectAudioTrack(trackId: ukrainian.id)
        // As the engine does after selecting a track; the seek completes the switch first.
        demuxer.seek(to: 1.5)
        #expect(demuxer.selectedVariantId == low.id)
        #expect(demuxer.audioStreamIndex == ukrainian.streamIndex)
        #expect(demuxer.audioTracks.first { $0.id == ukrainian.id }?.streamIndex == ukrainian.streamIndex)
    }

    @Test("A variant switch enables the new variant's video only: the renditions selected stay as they are")
    func variantSwitchKeepsRenditions() throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsRenditions) else { return }
        let demuxer = try #require(MediaDemuxer(url: master))
        let low = try #require(demuxer.variants.last)
        #expect(low.isSwitchable)
        var pictures = 0
        while demuxer.nextVideoSample() != nil {
            pictures += 1
            if pictures == 30 { demuxer.selectVariant(id: low.id) }
        }
        #expect(demuxer.selectedVariantId == low.id)
        let ctx = try #require(demuxer.formatCtx)
        let ukrainian = try #require(demuxer.audioTracks.first { $0.language == "ukr" })
        let isRead = { (index: Int) in ctx.pointee.streams[index]?.pointee.discard != AVDISCARD_ALL }
        #expect(!isRead(ukrainian.streamIndex))
        #expect(demuxer.subtitleTracks.allSatisfy { !isRead($0.streamIndex) })
        #expect(isRead(demuxer.audioStreamIndex) && isRead(demuxer.videoStreamIndex))
    }
}

extension HLSOverHTTPTests {
    /// Track selection runs on the main thread: a read stuck on the network mustn't hold it.
    @Test("Track selection doesn't wait for a read stuck on the network", .hostDependent)
    func trackSelectionDoesNotWaitForReads() async throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        defer { demuxer.cancel() }
        server.setBehavior(.init(failure: .hang), forPaths: { $0.hasSuffix("_001.ts") })
        demuxer.startReadAhead()
        #expect(await Self.waitUntil { server.requests.contains { $0.path.hasSuffix("_001.ts") } })
        try await Task.sleep(for: .milliseconds(200))

        let start = ContinuousClock.now
        _ = demuxer.getAudioCodecParameters()
        _ = demuxer.getVideoCodecParameters()
        demuxer.selectAudioTrack(trackId: try #require(demuxer.audioTracks.first).id)
        demuxer.selectSubtitleTrack(trackId: nil)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(200), "Track selection took \(elapsed)")
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

@Suite("HLS over HTTP playback", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct HLSOverHTTPPlaybackTests {
    @Test("The engine plays an HLS URL read ahead, and a switch reads the new variant from the current frame")
    func playsAndSwitches() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }

        engine.load(path: server.url("master.m3u8"))
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        #expect(engine.demuxer?.readsAhead == true)
        #expect(engine.bufferedTime > engine.currentTime + 2, "Read ahead to \(engine.bufferedTime) s")

        let low = try #require(engine.variants.last)
        let switchedAt = engine.currentTime
        let requestsBefore = server.requests.count
        engine.selectVariant(id: low.id)
        #expect(await engine.waitUntil(timeout: .seconds(4)) { engine.media.video.width == 320 })
        #expect(await engine.waitUntil(timeout: .seconds(3)) { engine.currentTime > switchedAt + 1 })
        #expect(!engine.isBuffering)
        let fetched = server.requests.dropFirst(requestsBefore).map(\.path).filter { $0.hasPrefix("v0_") }
        #expect(!fetched.isEmpty, "No segment of the new variant fetched")
    }

    @Test("During a seek, a variant read further ahead waits for playback; the one read at the target shows at once")
    func variantChangesDuringSeek() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: server.url("master.m3u8"))
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        let high = try #require(engine.variants.first)
        let low = try #require(engine.variants.last)
        #expect(engine.selectedVariantId == high.id)
        engine.pause()

        // As a seek to 1 s would see them: an adaptive switch read 12 s on, then the seek's own report.
        engine.chaseTargetTime = 1
        defer { engine.chaseTargetTime = nil }
        let lowAt = { (seconds: Double) in
            MediaDemuxer.VariantChange(
                variant: low, seconds: seconds, width: 320, height: 180, sampleAspectRatio: .square,
                frameDuration: 1.0 / 30)
        }
        engine.variantWillPlay(lowAt(13))
        #expect(engine.selectedVariantId == high.id, "A switch read ahead showed before it plays")
        engine.variantWillPlay(lowAt(1))
        #expect(engine.selectedVariantId == low.id)
        #expect(engine.pendingVariantChanges.isEmpty)
        #expect(engine.media.video.width == 320 && engine.media.video.height == 180)
    }

    @Test("Selecting an HLS subtitle rendition reads it from the current frame, and its cues show")
    func subtitleRenditionShows() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsRenditions) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: server.url("master.m3u8"))
        try #require(await engine.waitForPlayback())
        var seeks = 0
        engine.onSeekingChanged = { if $0 { seeks += 1 } }

        engine.subtitles.select(trackId: try #require(engine.subtitles.tracks.first).id)
        #expect(seeks == 1)
        #expect(
            await engine.waitUntil(timeout: .seconds(6)) {
                engine.subtitles.cues.contains { $0.text.contains("Hello") || $0.text.contains("World") }
            }, "No cue shown")
    }

    @Test("Choosing the variant playing keeps it: adaptive bitrate stops, without a seek")
    func choosingPlayingVariantStopsAdapting() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: server.url("master.m3u8"))
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        #expect(engine.isVariantAutomatic)
        let playing = try #require(engine.selectedVariantId)
        var seeks = 0
        engine.onSeekingChanged = { if $0 { seeks += 1 } }

        engine.selectVariant(id: playing)
        #expect(!engine.isVariantAutomatic)
        #expect(engine.demuxer?.isAdaptiveBitrateEnabled == false)
        #expect(engine.selectedVariantId == playing)
        #expect(seeks == 0)

        engine.selectAutomaticVariant()
        #expect(engine.isVariantAutomatic)
        #expect(engine.demuxer?.isAdaptiveBitrateEnabled == true)
    }
}
