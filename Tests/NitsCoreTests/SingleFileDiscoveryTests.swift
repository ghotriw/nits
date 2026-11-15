import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore
@testable import NitsStreaming

/// Files that are DASH representations whose manifest tells no `indexRange` and no `Initialization` (what a manifest built
/// from a site's list of files, YouTube's, is): the client finds the index in the file's first bytes
/// (`SingleFileLayout`), one request for the start and the index with it, and plays them as it does a manifest that tells.
@Suite("Single file discovery", .serialized, .hostDependent, .networkServer)
struct SingleFileDiscoveryTests {
    /// `manifest` without the ranges it tells.
    static func withoutRanges(_ manifest: String) throws -> String {
        manifest
            .replacing(try Regex(#" indexRange="[0-9-]+""#), with: "")
            .replacing(try Regex(#"<Initialization range="[0-9-]+"/>"#), with: "")
    }

    private static func requests(_ server: TestHTTPServer, _ name: String) -> [String] {
        server.requests.filter { $0.path == name }.compactMap(\.range)
    }

    private static func playlist(of source: DASHPlaylists, loader: SegmentLoader, variant: Int = 0) throws
        -> MediaPlaylist
    {
        guard
            case .multivariant(let multivariant) = try source.playlist(
                at: source.multivariantURL, variables: [:], loader: loader),
            case .media(let media) = try source.playlist(
                at: multivariant.variants[variant].url, variables: [:], loader: loader)
        else { throw PlaylistSourceError.unsupported("no media playlist") }
        return media
    }

    @Test("An MP4 ladder opens from files alone: the start is read once, with the index in it, and the segments follow")
    func mp4Ladder() async throws {
        guard let made = SingleFileDASHTests.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let server = try TestHTTPServer(root: made.directory)
        defer { server.stop() }
        let manifest = try Self.withoutRanges(SingleFileDASHTests.manifest(made, videos: [0, 1, 2]))
        #expect(!manifest.contains("indexRange") && !manifest.contains("Initialization"))
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        let url = try #require(URL(string: server.url("dash.mpd")))

        let media = try #require(try await DASHManifestResolver().resolve(url, headers: [:]))
        #expect(
            URL(string: media.path)?.path == url.path, "Files with no range are the client's, not played as they are")
        let demuxer = try #require(MediaDemuxer(url: media.path, headers: media.headers))
        #expect(demuxer.input is StreamingInput)
        #expect(demuxer.variants.count == 3, "\(demuxer.variants)")
        #expect(abs(demuxer.durationSeconds - 20) < 0.1)

        demuxer.startReadAhead(limits: .init(seconds: 30), held: true)
        demuxer.seek(to: 16.5, exact: true)
        let sample = try #require(demuxer.nextVideoSample())
        let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        #expect((14.0...16.6).contains(start), "Landed at \(start) s")

        for file in made.videos {
            let asked = Self.requests(server, file.name)
            #expect(asked.first == "bytes=0-\(SingleFileLayout.firstRead - 1)", "\(file.name): \(asked)")
            // Neither the index nor the initialization is asked for apart: both are in the start.
            #expect(!asked.contains("bytes=\(file.index.lowerBound)-\(file.index.upperBound)"), "\(asked)")
            #expect(!asked.contains("bytes=0-\(file.index.lowerBound - 1)"), "\(asked)")
        }
    }

    @Test("A WebM ladder opens from files alone, the initialization up to the cues")
    func webmFile() async throws {
        guard let made = WebMSingleFileDASHTests.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let server = try TestHTTPServer(root: made.directory)
        defer { server.stop() }
        let manifest = try Self.withoutRanges(WebMSingleFileDASHTests.manifest(made))
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        let url = try #require(URL(string: server.url("dash.mpd")))

        let source = DASHPlaylists(address: url)
        let loader = SegmentLoader(
            transport: HTTPSessionTransport(source: url.absoluteString, headers: [:]) { false }, allowsFiles: false)
        let media = try Self.playlist(of: source, loader: loader)
        #expect(media.segments.count == 10 && media.hasEnded)
        #expect(
            media.segments.first?.initSection?.byteRange
                == ByteRange(offset: 0, length: made.video.indexRange.lowerBound))
        #expect(media.segments.first?.byteRange?.offset == made.video.firstCluster)
        #expect(media.segments.allSatisfy { abs($0.duration - 2) < 0.05 })
        let asked = Self.requests(server, "v.webm")
        #expect(asked.first == "bytes=0-\(SingleFileLayout.firstRead - 1)", "\(asked)")
        #expect(asked.count == 1, "Start, init and cues came with one request: \(asked)")

        // The initialization is the loader's already: the lane's first segment asks for it no more.
        let initSection = try #require(media.segments.first?.initSection)
        _ = try loader.initSection(initSection)
        #expect(Self.requests(server, "v.webm").count == 1)
    }

    @Test("A sidx past the first read is asked for with the one request that reaches its end")
    func longIndex() throws {
        guard let ffmpeg = SyntheticTestMediaFactory.ffmpegBinaryPath() else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsLongIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("v.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        // A keyframe every 5 frames: 100 fragments, a sidx of 1232 bytes after a moov of some 700.
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=25:duration=20",
            "-c:v", "libx264", "-g", "5", "-keyint_min", "5", "-sc_threshold", "0", "-pix_fmt", "yuv420p",
            "-movflags", "+frag_keyframe+empty_moov+default_base_moof+global_sidx", file.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return }

        let server = try TestHTTPServer(root: directory)
        defer { server.stop() }
        let manifest = """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT20S" \
            profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period><AdaptationSet contentType="video">\
            <Representation id="v" mimeType="video/mp4" codecs="avc1.64000c" width="160" height="90" bandwidth="100000">\
            <BaseURL>v.mp4</BaseURL><SegmentBase/></Representation></AdaptationSet></Period></MPD>
            """
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        let url = try #require(URL(string: server.url("dash.mpd")))
        let source = DASHPlaylists(address: url)
        let loader = SegmentLoader(
            transport: HTTPSessionTransport(source: url.absoluteString, headers: [:]) { false }, allowsFiles: false)
        let media = try Self.playlist(of: source, loader: loader)
        #expect(media.segments.count == 100, "\(media.segments.count)")
        let asked = Self.requests(server, "v.mp4")
        let first = SingleFileLayout.firstRead
        #expect(asked.count == 2 && asked.first == "bytes=0-\(first - 1)", "\(asked)")
        #expect(asked.last?.hasPrefix("bytes=\(first)-") == true, "\(asked)")
        let init0 = try #require(media.segments.first?.initSection?.byteRange)
        #expect(init0.offset == 0 && init0.length < first)
    }

    @Test("A file whose start has no index is refused with the reason, as a wrong range is")
    func refusedStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsNoIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // An MP4 of a moov and then media, no sidx: a progressive file.
        func box(_ type: String, size: Int) -> Data {
            Data([0, 0, UInt8(size >> 8 & 0xff), UInt8(size & 0xff)] + Array(type.utf8))
                + Data(count: size - 8)
        }
        let plain = box("ftyp", size: 28) + box("moov", size: 300) + box("mdat", size: 5000)
        try plain.write(to: directory.appendingPathComponent("v.mp4"))
        let server = try TestHTTPServer(root: directory)
        defer { server.stop() }
        let manifest = """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT20S" \
            profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period><AdaptationSet contentType="video">\
            <Representation id="v" mimeType="video/mp4" codecs="avc1.64000c" width="160" height="90" bandwidth="100000">\
            <BaseURL>v.mp4</BaseURL><SegmentBase/></Representation></AdaptationSet></Period></MPD>
            """
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        let url = try #require(URL(string: server.url("dash.mpd")))
        let source = DASHPlaylists(address: url)
        let loader = SegmentLoader(
            transport: HTTPSessionTransport(source: url.absoluteString, headers: [:]) { false }, allowsFiles: false)
        #expect(throws: PlaylistSourceError.self) { try Self.playlist(of: source, loader: loader) }
        #expect(source.refusal?.contains("no sidx before the first fragment") == true, "\(source.refusal ?? "nil")")
    }

    /// Files whose addresses a source tells, as a site's extractor does for signed ones.
    private final class FakeFiles: MediaFileSource {
        private let state: OSAllocatedUnfairLock<(urls: [String: URL], renewed: [String: URL], renewals: Int)>

        init(urls: [String: URL], renewed: [String: URL]) {
            state = OSAllocatedUnfairLock(initialState: (urls, renewed, 0))
        }

        var renewals: Int { state.withLock { $0.renewals } }

        func address(forKey key: String) -> URL? { state.withLock { $0.urls[key] } }

        func renewAddresses(shouldAbort: () -> Bool) -> Bool {
            state.withLock { state in
                state.urls.merge(state.renewed) { _, new in new }
                state.renewals += 1
            }
            return true
        }
    }

    @Test(
        "A manifest of keys plays through the addresses a source tells: one the server refuses is renewed and asked again, no signed address is in the manifest"
    )
    func keysAndRenewal() async throws {
        guard let made = SingleFileDASHTests.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let server = try TestHTTPServer(root: made.directory)
        defer { server.stop() }
        // The pictures' first address is one that has expired (403); the renewal brings the file's own.
        try FileManager.default.copyItem(
            at: made.directory.appendingPathComponent("v.mp4"),
            to: made.directory.appendingPathComponent("expired-v.mp4"))
        server.setBehavior(.init(failure: .status(403)), forPaths: { $0 == "expired-v.mp4" })
        let urls = ["v": "expired-v.mp4", "vlow": "v-low.mp4", "a": "a.mp4"].mapValues { URL(string: server.url($0))! }
        let files = FakeFiles(urls: urls, renewed: ["v": URL(string: server.url("v.mp4"))!])

        var manifest = try Self.withoutRanges(SingleFileDASHTests.manifest(made, videos: [0, 1]))
        for (name, key) in [("v.mp4", "v"), ("v-low.mp4", "vlow"), ("a.mp4", "a")] {
            manifest = manifest.replacingOccurrences(
                of: "<BaseURL>\(name)</BaseURL>", with: "<BaseURL>\(MediaFileKey.address(key))</BaseURL>")
        }
        #expect(!manifest.contains("127.0.0.1") && !manifest.contains(".mp4<"), "Keys, no address that exists")
        let path = MediaURL.inlineDASHManifest(manifest)

        let demuxer = try #require(
            MediaDemuxer(url: path, headers: [:], httpRequestSize: nil, interruptContext: nil, files: MediaFiles(files))
        )
        #expect(demuxer.input is StreamingInput)
        #expect(demuxer.variants.count == 2, "\(demuxer.variants)")
        #expect(abs(demuxer.durationSeconds - 20) < 0.1)
        #expect(files.renewals >= 1, "The refused address was renewed")
        #expect(demuxer.nextVideoSample() != nil)
        #expect(!Self.requests(server, "v.mp4").isEmpty && Self.requests(server, "expired-v.mp4").count >= 1)

        // The choice a location carries in its fragment reaches the client of an inline manifest.
        let chosen = try #require(
            DASHPlaylists(media: DASHSelection(video: "v1").address(of: URL(string: path)!)))
        #expect(chosen.selection.video == "v1")
        #expect(DASHPlaylists(media: path)?.selection.isEmpty == true)
    }
}
