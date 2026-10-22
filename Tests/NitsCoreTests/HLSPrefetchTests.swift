import Foundation
import Testing

@testable import NitsCore

/// `HLSPlaylistPrefetcher`: what FFmpeg's opening of a master playlist reads, downloaded side by side and served from
/// memory.
@Suite("HLS opening prefetch", .serialized)
struct HLSPrefetchTests {
    private static func serve(_ preset: SyntheticTestMediaFactory.Preset) throws -> TestHTTPServer? {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return nil }
        return try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
    }

    private static func ffmpegRequests(_ server: TestHTTPServer) -> [TestHTTPServer.Request] {
        server.requests.filter { $0.userAgent?.hasPrefix("Lavf") == true }
    }

    /// `body` on a thread of its own: opening and reading block on the network, and `TestHTTPServer` answers on the
    /// cooperative pool, which a full run's tests blocking its threads left without one (FFmpeg's requests timed out).
    private static func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: body()) }
        }
    }

    private static func open(_ server: TestHTTPServer) async -> MediaDemuxer? {
        let url = server.url("master.m3u8")
        return await offPool { MediaDemuxer(url: url) }
    }

    @Test(
        "Opening a master playlist, FFmpeg asks the server for the master only, and for segments past their start",
        arguments: [
            SyntheticTestMediaFactory.Preset.hlsVariants, .hlsVariantsFMP4, .hlsVariantsSingleFile, .hlsRenditions,
        ])
    func readsFromMemory(preset: SyntheticTestMediaFactory.Preset) async throws {
        guard let server = try Self.serve(preset) else { return }
        defer { server.stop() }
        let demuxer = try #require(await Self.open(server))
        #expect(demuxer.variants.count == 2)
        // Opening reads into the first fragments of fragmented MP4 past the start downloaded: those it reads on, from
        // where it ends (past an init section in the same file: from its offset on).
        let ffmpeg = Self.ffmpegRequests(server)
        let readsOn = { (request: TestHTTPServer.Request) in
            request.range.flatMap { Int($0.dropFirst("bytes=".count).prefix { $0 != "-" }) }.map {
                $0 >= HLSPlaylistPrefetcher.segmentStart
            } ?? false
        }
        #expect(
            ffmpeg.first?.path == "master.m3u8" && ffmpeg.dropFirst().allSatisfy(readsOn),
            "\(ffmpeg.map { "\($0.path) \($0.range ?? "")" })")
        // Each playlist once, by the prefetcher; segments' starts as ranges.
        let prefetched = server.requests.filter { $0.userAgent?.hasPrefix("Lavf") != true }
        let playlists = prefetched.filter { $0.path.hasSuffix(".m3u8") }.map(\.path)
        #expect(playlists.count == Set(playlists).count, "\(playlists)")
        #expect(prefetched.filter { !$0.path.hasSuffix(".m3u8") }.allSatisfy { $0.range != nil })
        // Subtitles' segments FFmpeg doesn't probe.
        #expect(!prefetched.contains { $0.path.hasSuffix(".vtt") })
        #expect(await Self.offPool { demuxer.nextVideoSample(waitingForReadAhead: false) != nil })
    }

    @Test("Past a segment's start FFmpeg reads on from the network")
    func readsOnPastTheStart() async throws {
        guard let server = try Self.serve(.hlsVariantsFMP4) else { return }
        defer { server.stop() }
        // 2 KB of each range: the probe reads further into the first segments.
        server.setBehavior(.init(rangeLimit: 2048), forPaths: { !$0.hasSuffix(".m3u8") })
        let demuxer = try #require(await Self.open(server))
        #expect(demuxer.variants.count == 2)
        // From where the start ends, not from the start: FFmpeg asks for `bytes=0-` (and goes on itself where the
        // server's part ends).
        let ffmpeg = Self.ffmpegRequests(server)
        let described = "\(ffmpeg.map { "\($0.path) \($0.range ?? "")" })"
        #expect(ffmpeg.contains { $0.range == "bytes=2048-" }, "\(described)")
        #expect(!ffmpeg.contains { $0.path != "master.m3u8" && $0.range == "bytes=0-" }, "\(described)")
        let read = await Self.offPool {
            (0..<30).filter { _ in demuxer.nextVideoSample(waitingForReadAhead: false) != nil }
        }
        #expect(read.count == 30)
    }

    @Test("A playlist served from elsewhere FFmpeg reads itself: its segments resolve against that place")
    func redirectedPlaylist() async throws {
        guard let server = try Self.serve(.hlsVariants) else { return }
        defer { server.stop() }
        let playlist = try #require(URL(string: server.url("v1.m3u8")))
        let original = String(decoding: try await URLSession.shared.data(from: playlist).0, as: UTF8.self)
        server.setResponder(forPath: "moved/v1.m3u8") {
            Data(
                original.split(separator: "\n").map { $0.hasPrefix("v1_") ? "../\($0)" : String($0) }
                    .joined(separator: "\n").utf8)
        }
        server.setBehavior(.init(redirect: "moved/v1.m3u8"), forPaths: { $0 == "v1.m3u8" })
        let demuxer = try #require(await Self.open(server))
        #expect(demuxer.variants.count == 2)
        #expect(Self.ffmpegRequests(server).map(\.path).contains("moved/v1.m3u8"))
        #expect(await Self.offPool { demuxer.nextVideoSample(waitingForReadAhead: false) != nil })
    }

    @Test("A master's playlists: variants and renditions, subtitles told apart, I-frame playlists left out")
    func mediaPlaylists() {
        let master = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",URI="audio/en.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Українська",LANGUAGE="uk",URI="subs/uk.m3u8"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC",INSTREAM-ID="CC1"
            #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud",SUBTITLES="subs"
            video/800k.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="video/iframes.m3u8"

            #EXT-X-STREAM-INF:BANDWIDTH=2500000,AUDIO="aud"
            https://cdn.example.com/video/2500k.m3u8
            """
        let playlists = HLSPlaylistPrefetcher.mediaPlaylists(in: master)
        #expect(
            playlists.map(\.uri) == [
                "audio/en.m3u8", "subs/uk.m3u8", "video/800k.m3u8", "https://cdn.example.com/video/2500k.m3u8",
            ])
        #expect(playlists.map(\.isSubtitles) == [false, true, false, false])
    }

    @Test("What FFmpeg's probe of a media playlist opens: its init section and the segment it starts from")
    func probedInputs() {
        let vod = """
            #EXTM3U
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:2.0,
            seg0.m4s
            #EXTINF:2.0,
            seg1.m4s
            #EXT-X-ENDLIST
            """
        #expect(HLSPlaylistPrefetcher.probedInputs(in: vod) == [.init(uri: "init.mp4"), .init(uri: "seg0.m4s")])
        // Live: the third segment from the end (`live_start_index`), of a window of five.
        let live = (0..<5).map { "#EXTINF:2.0,\nseg\($0).ts" }.joined(separator: "\n")
        #expect(HLSPlaylistPrefetcher.probedInputs(in: "#EXTM3U\n" + live) == [.init(uri: "seg2.ts")])
        #expect(HLSPlaylistPrefetcher.probedInputs(in: "#EXTM3U\n#EXTINF:2.0,\nseg0.ts") == [.init(uri: "seg0.ts")])
        // Encryption FFmpeg opens itself; `METHOD=NONE` is no encryption.
        let encrypted = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2.0,\nseg0.ts\n#EXT-X-ENDLIST"
        #expect(HLSPlaylistPrefetcher.probedInputs(in: encrypted).isEmpty)
        let clear = "#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:2.0,\nseg0.ts\n#EXT-X-ENDLIST"
        #expect(HLSPlaylistPrefetcher.probedInputs(in: clear) == [.init(uri: "seg0.ts")])
    }

    @Test("Byte ranges are placed as FFmpeg places them: one without an offset follows the one before")
    func probedByteRanges() {
        // Apple's one-file variants: the init section and the segments in `main.mp4`.
        let oneFile = """
            #EXTM3U
            #EXT-X-MAP:URI="main.mp4",BYTERANGE="1118@0"
            #EXTINF:7.98333,
            #EXT-X-BYTERANGE:1700094@1118
            main.mp4
            #EXTINF:8.0,
            #EXT-X-BYTERANGE:1789481@1701212
            main.mp4
            #EXT-X-ENDLIST
            """
        #expect(
            HLSPlaylistPrefetcher.probedInputs(in: oneFile) == [
                .init(uri: "main.mp4", offset: 0, length: 1118),
                .init(uri: "main.mp4", offset: 1118, length: 1_700_094),
            ])
        // Without offsets, each range follows the one before, from 0 on; a live window starts at its third from last.
        let following = (0..<4).map { _ in "#EXTINF:2.0,\n#EXT-X-BYTERANGE:1000\nall.ts" }.joined(separator: "\n")
        #expect(
            HLSPlaylistPrefetcher.probedInputs(in: "#EXTM3U\n" + following) == [
                .init(uri: "all.ts", offset: 1000, length: 1000)
            ])
        // A whole-file segment after a range starts the count again.
        let mixed = "#EXTM3U\n#EXT-X-BYTERANGE:500@100\n#EXTINF:2.0,\na.ts\n#EXTINF:2.0,\nb.ts\n#EXT-X-ENDLIST"
        #expect(HLSPlaylistPrefetcher.probedInputs(in: mixed) == [.init(uri: "a.ts", offset: 100, length: 500)])
        #expect(HLSPlaylistPrefetcher.probedInputs(in: "#EXTM3U\n#EXT-X-BYTERANGE:x\n#EXTINF:2.0,\na.ts").isEmpty)
    }
}
