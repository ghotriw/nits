import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// A DASH manifest given inline (`MediaURL.inlineDASHManifest`), as built for segments of one URL a site lists:
/// FFmpeg's DASH demuxer reads it, and the segments (their URLs without an extension, each with the initialization
/// data in it) from `TestHTTPServer`. Needs FFmpeg built with libxml2 (the bundled one; Homebrew's has no DASH
/// demuxer), else the tests do nothing.
@Suite("Inline DASH manifest", .serialized, .hostDependent, .networkServer)
struct InlineDASHTests {
    private static var count: Int { SyntheticTestMediaFactory.dashSegmentCount }

    /// A server of the `dashSegments` preset's segments; nil when FFmpeg can't make them or can't read DASH.
    static func server() throws -> TestHTTPServer? {
        guard av_find_input_format("dash") != nil,
            let first = SyntheticTestMediaFactory.ensureMedia(preset: .dashSegments)
        else { return nil }
        let root = URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent()
        return try TestHTTPServer(root: root)
    }

    /// The manifest the resolver builds for the segments, as the demuxer is given it.
    private static func manifest(for server: TestHTTPServer) -> String {
        MediaURL.inlineDASHManifest(
            SegmentedDASHManifest(
                streams: [
                    .init(kind: .video, id: "v", container: "mp4", url: server.url("video")),
                    .init(kind: .audio, id: "a", container: "mp4", url: server.url("audio")),
                ], segmentDuration: 1, segmentCount: count
            ).text())
    }

    @Test("The picture and its audio play out of segments without extensions, each request carrying the headers set")
    func playsSegments() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(
            MediaDemuxer(
                url: Self.manifest(for: server),
                headers: ["User-Agent": "NitsTest/1", "X-Nits": "1"]))
        #expect(demuxer.isNetworkSource)
        #expect(demuxer.hasVideo)
        #expect(demuxer.hasAudio)
        #expect(abs(demuxer.durationSeconds - Double(Self.count)) < 0.1)

        demuxer.startReadAhead()
        var pictures = 0
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures == 25 * Self.count, "\(pictures) pictures; asked for \(server.requests.map(\.path))")

        let requests = server.requests
        let segments = requests.filter { $0.path.hasPrefix("video/") || $0.path.hasPrefix("audio/") }
        // They came through the transport (which measures each transfer apart from its answer): it alone asks for the
        // body as it is.
        #expect(demuxer.network?.transferMeter != nil)
        #expect(segments.allSatisfy { $0.acceptEncoding == "identity" }, "\(segments.map(\.acceptEncoding))")
        let asked = Set(requests.map(\.path).filter { $0.contains("/") })
        let wanted = Set((0..<Self.count).flatMap { ["audio/\($0)", "video/\($0)"] })
        #expect(asked == wanted, "Every segment of both streams and none past the end: \(asked.sorted())")
        #expect(segments.allSatisfy { $0.userAgent == "NitsTest/1" }, "The user agent reaches the segments' requests")
        #expect(segments.allSatisfy { $0.headers["x-nits"] == "1" }, "The other headers reach them too")
    }

    @Test("A seek lands on the segment's keyframe and plays on from there; only the segments from it are asked for")
    func seeksBySegment() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: Self.manifest(for: server)))
        demuxer.startReadAhead()
        demuxer.seek(to: 2.5, exact: false)
        let first = try #require(demuxer.nextVideoSample())
        let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))
        #expect((1.9...2.1).contains(start), "Keyframe of the third segment, not \(start)")
        var pictures = 1
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures == 25 * (Self.count - 2))
        #expect(!server.requests.map(\.path).contains("video/1"), "The segments before the target are not read")
    }

    @Test("After the end was read, a seek back plays the picture and the audio again")
    func seeksBackAfterTheEnd() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: Self.manifest(for: server)))
        demuxer.startReadAhead()
        var allPictures = 0
        while demuxer.nextVideoSample() != nil { allPictures += 1 }
        var allPackets = 0
        while demuxer.nextAudioPacket() != nil { allPackets += 1 }

        demuxer.seek(to: 1.0, exact: false)
        var pictures = 0
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        var packets = 0
        while demuxer.nextAudioPacket() != nil { packets += 1 }
        #expect(pictures == 25 * (Self.count - 1), "\(pictures) pictures after the seek")
        #expect(allPictures == 25 * Self.count)
        // The packets of the segments from the second: about, as the encoder divides them between segments.
        let expected = allPackets * (Self.count - 1) / Self.count
        #expect(
            abs(packets - expected) <= 4,
            "\(packets) audio packets after the seek, \(expected) expected of \(allPackets) in all")
    }

    @Test("The manifest is not written to the log, nor are thumbnails made of it")
    func keepsManifestOutOfLogsAndThumbnails() async {
        let manifest = MediaURL.inlineDASHManifest("<MPD>https://signed.example/videoplayback?sig=secret</MPD>")
        let logged = MediaURL.loggable(manifest)
        #expect(!logged.contains("secret") && !logged.contains("base64"), "\(logged)")
        #expect(logged.hasPrefix("inline DASH manifest ("))
        #expect(MediaURL.loggable("https://a.example/v.mp4") == "https://a.example/v.mp4")

        let manager = await ThumbnailManager()
        let items = await manager.prepareThumbnailsAsync(for: manifest, duration: 3600, networkPolicy: .always)
        #expect(items.isEmpty)
        #expect(await !manager.isGenerating)
    }
}
