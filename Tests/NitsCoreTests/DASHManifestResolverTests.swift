import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// `.mpd` addresses played through `DASHManifestResolver`: the manifest is served by `TestHTTPServer` beside the
/// segments of the `dashSegments` preset (the same four seconds for every picture it lists), read as the engine reads
/// it. Need FFmpeg built with libxml2, else they do nothing.
@Suite("DASH manifest resolver", .serialized)
struct DASHManifestResolverTests {
    private static let count = SyntheticTestMediaFactory.dashSegmentCount

    /// A manifest with a TTML track FFmpeg cannot open, two pictures of one template that repeats its segment "to the
    /// end" (the timeline FFmpeg seeks wrongly in), and the audio; its addresses relative to the manifest.
    private static let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT\(count)S" \
        minBufferTime="PT2S" profiles="urn:mpeg:dash:profile:isoff-live:2011"><Period>
        <AdaptationSet contentType="text" lang="en"><Representation id="subs" bandwidth="256" \
        mimeType="application/ttml+xml"><BaseURL>subs.ttml</BaseURL></Representation></AdaptationSet>
        <AdaptationSet contentType="video" segmentAlignment="true">
        <SegmentTemplate timescale="1000" startNumber="0" media="video/$Number$"><SegmentTimeline>\
        <S d="1000" r="-1"/></SegmentTimeline></SegmentTemplate>
        <Representation id="low" mimeType="video/mp4" codecs="avc1.42c01e" width="160" height="90" bandwidth="100000"/>
        <Representation id="high" mimeType="video/mp4" codecs="avc1.42c01e" width="320" height="180" bandwidth="500000"/>
        </AdaptationSet>
        <AdaptationSet contentType="audio" lang="en"><SegmentTemplate timescale="1000" startNumber="0" \
        media="audio/$Number$"><SegmentTimeline><S d="1000" r="-1"/></SegmentTimeline></SegmentTemplate>
        <Representation id="a" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="64000"/></AdaptationSet>
        </Period></MPD>
        """

    private static func served() throws -> TestHTTPServer? {
        guard let server = try InlineDASHTests.server() else { return nil }
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        return server
    }

    @Test(
        "The best picture plays, the others are to choose from, and the audio comes with it; the headers reach the segments"
    )
    func playsTheBestPicture() async throws {
        guard let server = try Self.served() else { return }
        defer { server.stop() }
        let headers = ["User-Agent": "NitsTest/1", "X-Nits": "1"]
        let manifestURL = try #require(URL(string: server.url("dash.mpd")))
        let media = try #require(try await DASHManifestResolver().resolve(manifestURL, headers: headers))
        #expect(media.videoFormats.map(\.id) == ["high", "low"])
        #expect(media.selectedVideoFormatID == "high")
        #expect(media.videoFormats.map(\.height) == [180, 90])
        #expect(media.videoFormats.map(\.codec) == ["H.264", "H.264"], "SDR says nothing")
        #expect(media.headers == headers)
        #expect(MediaURL.isInlineDASHManifest(media.path))
        #expect(media.path == media.videoFormats[0].url)

        let demuxer = try #require(MediaDemuxer(url: media.path, headers: media.headers))
        #expect(demuxer.hasVideo && demuxer.hasAudio)
        #expect(abs(demuxer.durationSeconds - Double(Self.count)) < 0.1)
        demuxer.startReadAhead()
        var pictures = 0
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures == 25 * Self.count)

        let requests = server.requests
        let segments = requests.filter { $0.path.hasPrefix("video/") || $0.path.hasPrefix("audio/") }
        #expect(
            !segments.isEmpty && segments.allSatisfy { $0.userAgent == "NitsTest/1" && $0.headers["x-nits"] == "1" })
        #expect(!requests.contains { $0.path.hasSuffix(".ttml") }, "The subtitle track is never asked for")
    }

    @Test(
        "A seek in a timeline that repeats to the end lands on its segment, and the other picture plays from the manifest chosen"
    )
    func seeksAndSwitches() async throws {
        guard let server = try Self.served() else { return }
        defer { server.stop() }
        let manifestURL = try #require(URL(string: server.url("dash.mpd")))
        let media = try #require(try await DASHManifestResolver().resolve(manifestURL, headers: [:]))
        let demuxer = try #require(MediaDemuxer(url: media.path, headers: media.headers))
        demuxer.startReadAhead()
        demuxer.seek(to: 2.5, exact: false)
        let first = try #require(demuxer.nextVideoSample())
        let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))
        #expect((1.9...2.1).contains(start), "Keyframe of the third segment, not \(start)")

        let other = try #require(media.selecting(videoFormat: "low"))
        #expect(other.path != media.path && other.selectedVideoFormatID == "low")
        let low = try #require(MediaDemuxer(url: other.path, headers: other.headers))
        low.startReadAhead()
        var pictures = 0
        while low.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures == 25 * Self.count)
    }

    @Test("Only .mpd addresses are the resolver's; the host's resolver keeps the rest")
    func decidesByAddress() throws {
        let resolver = DASHManifestResolver()
        guard resolver.order(for: URL(string: "https://a.example/v.mpd")!) != nil else { return }  // no DASH demuxer
        #expect(resolver.order(for: URL(string: "https://a.example/v.mpd")!) == .beforeOpening)
        #expect(resolver.order(for: URL(string: "https://a.example/v/.MPD?x=1")!) == .beforeOpening)
        #expect(resolver.order(for: URL(string: "https://a.example/x.ism/.mpd")!) == .beforeOpening)
        #expect(resolver.order(for: URL(string: "https://a.example/v.m3u8")!) == nil)
        #expect(resolver.order(for: URL(string: "https://a.example/watch?v=1")!) == nil)

        struct Host: MediaResolver {
            func order(for url: URL) -> MediaResolutionOrder? { .afterOpeningFails }
            func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
                ResolvedMedia(path: "https://host.example/stream")
            }
        }
        let chain = MediaResolverChain(host: Host())
        #expect(chain.order(for: URL(string: "https://a.example/v.mpd")!) == .beforeOpening)
        #expect(chain.order(for: URL(string: "https://a.example/page")!) == .afterOpeningFails)
        #expect(MediaResolverChain(host: nil).order(for: URL(string: "https://a.example/page")!) == nil)
    }

    @Test("A manifest it cannot use is left to the demuxer; one of protected streams fails with the reason")
    func leavesWhatItCannotUse() async throws {
        guard DASHManifestResolver().order(for: URL(string: "https://a.example/v.mpd")!) != nil,
            let server = try Self.served()
        else { return }
        defer { server.stop() }
        let live = Self.manifest.replacingOccurrences(of: #"type="static""#, with: #"type="dynamic""#)
        server.setResponder(forPath: "live.mpd") { Data(live.utf8) }
        server.setResponder(forPath: "broken.mpd") { Data("<MPD".utf8) }
        // Nothing but protected streams (a mixed one is the manifest tests').
        let onlyProtected = """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S"><Period>\
            <AdaptationSet contentType="video"><ContentProtection schemeIdUri="urn:uuid:x"/>\
            <Representation id="v" mimeType="video/mp4" width="2" height="2" bandwidth="1"/></AdaptationSet></Period></MPD>
            """
        server.setResponder(forPath: "drm.mpd") { Data(onlyProtected.utf8) }
        // Larger than a manifest is read to be: stopped on the way, not read.
        let oversized = Self.manifest + String(repeating: " ", count: DASHManifest.sizeLimit)
        server.setResponder(forPath: "huge.mpd") { Data(oversized.utf8) }

        let resolver = DASHManifestResolver()
        for name in ["live.mpd", "broken.mpd", "missing.mpd", "huge.mpd"] {
            let address = try #require(URL(string: server.url(name)))
            let found = try await resolver.resolve(address, headers: [:])
            #expect(found == nil, "\(name) is the demuxer's")
        }
        let drmURL = try #require(URL(string: server.url("drm.mpd")))
        await #expect(throws: MediaResolutionError.self) {
            try await resolver.resolve(drmURL, headers: [:])
        }
    }
}

extension DASHManifestResolverTests {
    @Test("An HDR picture says so in the quality menu, beside its codec; Dolby Vision's name does already")
    func labelsHDRPictures() async throws {
        guard DASHManifestResolver().order(for: URL(string: "https://a.example/v.mpd")!) != nil,
            let server = try Self.served()
        else { return }
        defer { server.stop() }
        let hdr = """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S"><Period>\
            <AdaptationSet contentType="video"><SegmentTemplate timescale="1" startNumber="0" media="video/$Number$" duration="1"/>\
            <Representation id="sdr" mimeType="video/mp4" codecs="hvc1.1.6.L120" width="1920" height="1080" bandwidth="4000000"/>\
            <Representation id="hdr" mimeType="video/mp4" codecs="hvc1.2.4.L120" width="1920" height="1080" bandwidth="6000000">\
            <SupplementalProperty schemeIdUri="urn:mpeg:mpegB:cicp:TransferCharacteristics" value="16"/></Representation>\
            <Representation id="dv" mimeType="video/mp4" codecs="dvh1.05.06" width="1920" height="1080" bandwidth="5000000"/>\
            </AdaptationSet></Period></MPD>
            """
        server.setResponder(forPath: "hdr.mpd") { Data(hdr.utf8) }
        let address = try #require(URL(string: server.url("hdr.mpd")))
        let media = try #require(try await DASHManifestResolver().resolve(address, headers: [:]))
        // HDR over SDR; of the two HDR ones, the higher bitrate first.
        #expect(media.videoFormats.map(\.id) == ["hdr", "dv", "sdr"])
        #expect(media.videoFormats.map(\.codec) == ["HEVC HDR", "Dolby Vision", "HEVC"])
    }
}
