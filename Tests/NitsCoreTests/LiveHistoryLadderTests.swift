import CoreMedia
import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore
@testable import NitsStreaming

/// A live stream's history that has a ladder of rungs and more than one codec, as an ordinary video's manifest has.
@Suite("Live history ladder offered and played", .serialized, .hostDependent, .networkServer, .backstopTimeLimit)
struct LiveHistoryLadderTests {
    /// Two codecs, H.264 and VP9 (WebM), two rungs each, and a sound: the shape the resolver makes of a page that lists them.
    private static func manifest(base: (String) -> String = { LiveHistory.streamAddress($0) }) -> SegmentedDASHManifest
    {
        var manifest = SegmentedDASHManifest(
            streams: [
                .init(
                    kind: .video, id: "134", container: "mp4", codecs: "avc1.4D401E", bandwidth: 700_000, width: 640,
                    height: 360, frameRate: 30, group: "video0", url: base("134")),
                .init(
                    kind: .video, id: "137", container: "mp4", codecs: "avc1.640028", bandwidth: 4_000_000, width: 1920,
                    height: 1080, frameRate: 30, group: "video0", url: base("137")),
                .init(
                    kind: .video, id: "243", container: "webm", codecs: "vp09.00.10.08", bandwidth: 500_000, width: 640,
                    height: 360, frameRate: 30, group: "video1", url: base("243")),
                .init(
                    kind: .video, id: "248", container: "webm", codecs: "vp09.00.10.08", bandwidth: 2_500_000,
                    width: 1920, height: 1080, frameRate: 30, group: "video1", url: base("248")),
                .init(
                    kind: .audio, id: "140", container: "mp4", codecs: "mp4a.40.2", bandwidth: 128_000,
                    sampleRate: 44100,
                    group: "audio0", language: "en", url: base("140")),
            ], segmentDuration: 5, segmentCount: 100)
        manifest.firstNumber = 1000
        manifest.startTime = 5000
        return manifest
    }

    @Test("The codecs of a history are offered as an .mpd's are, each a choice that keeps the history")
    func offersTheCodecs() throws {
        let history = LiveHistory(origin: 5000, end: 5500, headNumber: 1099)
        var media = ResolvedMedia(
            path: MediaURL.inlineDASHManifest(Self.manifest().text()), headers: ["User-Agent": "T"],
            title: "Live", liveHistory: history)
        media.historyKey = "youtube:abc"
        let offered = MediaResolverChain.offeringChoices(of: media, codecs: VideoCodecPreference())
        #expect(offered.liveHistory == history, "the history is kept")
        #expect(offered.videoFormats.count == 2, "\(offered.videoFormats)")
        #expect(Set(offered.videoFormats.map(\.codec)) == ["H.264", "VP9"], "\(offered.videoFormats.map(\.codec))")
        #expect(offered.selectedVideoFormatID != nil)
        #expect(MediaURL.isInlineDASHManifest(offered.path), "still the manifest, inline")
        #expect(offered.path.contains("#nits-video="))
        #expect(offered.historyKey == media.historyKey && offered.title == "Live")
        // Every choice is the same manifest, the picture named in the fragment.
        let base = String(media.path.prefix { $0 != "#" })
        #expect(offered.videoFormats.allSatisfy { $0.url.hasPrefix(base + "#nits-video=") })

        // A manifest that is not a history's or a host's file manifest is left as it is.
        var plain = media
        plain.liveHistory = nil
        #expect(MediaResolverChain.offeringChoices(of: plain, codecs: VideoCodecPreference()) == plain)
    }

    @Test("A hand switch of the picture keeps the history, and its position (the edge when it was there)")
    func switchKeepsThePosition() throws {
        let history = LiveHistory(origin: 5000, end: 5500, headNumber: 1099)
        let media = ResolvedMedia(
            path: MediaURL.inlineDASHManifest(Self.manifest().text()), liveHistory: history)
        let offered = MediaResolverChain.offeringChoices(of: media, codecs: VideoCodecPreference())
        let other = try #require(offered.videoFormats.first { $0.id != offered.selectedVideoFormatID })
        let source = ResolvedSource(request: MediaLoadRequest(path: "https://example.com/live"), media: offered)

        let behind = try #require(
            source.switching(
                to: other.id, startTime: 1234, audioTrack: nil, title: "Live", artworkData: nil, artworkURL: nil))
        #expect(behind.media.liveHistory == history)
        #expect(behind.media.selectedVideoFormatID == other.id)
        #expect(
            behind.request.livePosition == .streamTime(1234 + history.origin), "the stream's time, not the window's")

        let atEdge = try #require(
            source.switching(
                to: other.id, startTime: 1234, audioTrack: nil, title: "Live", artworkData: nil, artworkURL: nil,
                atLiveEdge: true))
        #expect(atEdge.request.livePosition == .edge)
        #expect(atEdge.request.startTime == nil)

        // Another media's switch is the plain one: its start is its own, a position of the media.
        var file = offered
        file.liveHistory = nil
        let plain = try #require(
            ResolvedSource(request: MediaLoadRequest(path: "x"), media: file).switching(
                to: other.id, startTime: 12, audioTrack: nil, title: "T", artworkData: nil, artworkURL: nil,
                atLiveEdge: true))
        #expect(plain.request.livePosition == nil && plain.request.startTime == 12)
    }

    @MainActor
    @Test("A history loaded again keeps its position inside the window, and no nearer the edge than go-live lands")
    func keptTarget() {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        live.begin(isLive: true, window: LiveWindow(start: 0, end: 86_400, hasSlid: true), at: t0)
        let edge = live.edgeTarget(now: t0)
        #expect(live.keptTarget(10_800, now: t0) == 10_800)
        #expect(live.keptTarget(3, now: t0) == LiveStream.startMargin)
        #expect(live.keptTarget(90_000, now: t0) == edge)
        let notLive = LiveStream()
        #expect(notLive.keptTarget(5) == nil)
    }

    @Test("A history of a ladder plays with its rungs as variants, and the sound with them")
    func playsALadder() throws {
        guard let first = SyntheticTestMediaFactory.ensureMedia(preset: .dashLadder) else { return }
        let root = URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent()
        let server = try TestHTTPServer(root: root)
        defer { server.stop() }
        let count = SyntheticTestMediaFactory.dashLadderSegmentCount
        var manifest = SegmentedDASHManifest(
            streams: SyntheticTestMediaFactory.dashLadderRungs.enumerated().map { index, rung in
                .init(
                    kind: .video, id: "video\(index)", container: "mp4", codecs: "avc1.64001f", bandwidth: rung.bitrate,
                    width: rung.width, height: rung.height, frameRate: 25, group: "video",
                    url: LiveHistory.streamAddress("video\(index)"))
            } + [
                .init(
                    kind: .audio, id: "audio", container: "mp4", codecs: "mp4a.40.2", bandwidth: 64_000, group: "audio",
                    language: "en", url: LiveHistory.streamAddress("audio"))
            ], segmentDuration: 1, segmentCount: count - 1)
        manifest.firstNumber = 1
        manifest.startTime = 1
        let source = TestLiveSource(base: String(server.url("").dropLast()), waitLimit: .milliseconds(400))
        source.report(head: LiveHead(number: count - 1, startTime: Double(count - 1)))
        let history = LiveHistory(origin: 1, end: Double(count - 1), headNumber: count - 1, source: source)
        let demuxer = try #require(
            MediaDemuxer(url: MediaURL.inlineDASHManifest(manifest.text()), liveHistory: history))
        #expect(demuxer.isLive && demuxer.hasVideo && demuxer.hasAudio)
        #expect(demuxer.variants.count == SyntheticTestMediaFactory.dashLadderRungs.count, "\(demuxer.variants)")
        demuxer.startReadAhead()
        var pictures = 0
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures >= 25 * (count - 3), "\(pictures) pictures")
    }

    @Test("A history of WebM segments, each with its own header and no initialization, plays, seeks and switches rung")
    func playsWebM() throws {
        guard let first = SyntheticTestMediaFactory.ensureMedia(preset: .dashSegmentsWebM) else { return }
        let root = URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent()
        let server = try TestHTTPServer(root: root)
        defer { server.stop() }
        let count = 4
        var manifest = SegmentedDASHManifest(
            streams: [(160, 90, 100_000), (320, 180, 300_000)].enumerated().map { index, rung in
                .init(
                    kind: .video, id: "video\(index)", container: "webm", codecs: "vp09.00.10.08", bandwidth: rung.2,
                    width: rung.0, height: rung.1, frameRate: 25, group: "video",
                    url: LiveHistory.streamAddress("video\(index)"))
            }, segmentDuration: 1, segmentCount: count - 1)
        manifest.firstNumber = 1
        manifest.startTime = 1
        let source = TestLiveSource(base: String(server.url("").dropLast()), waitLimit: .milliseconds(400))
        source.report(head: LiveHead(number: count - 1, startTime: Double(count - 1)))
        let history = LiveHistory(origin: 1, end: Double(count - 1), headNumber: count - 1, source: source)
        let demuxer = try #require(
            MediaDemuxer(url: MediaURL.inlineDASHManifest(manifest.text()), liveHistory: history))
        #expect(demuxer.hasVideo)
        #expect(demuxer.variants.count == 2, "\(demuxer.variants)")
        demuxer.startReadAhead()
        let started = try #require(demuxer.nextVideoSample())
        #expect((-0.1...0.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(started))))
        var pictures = 1
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures >= 25 * (count - 1) - 2, "\(pictures) pictures, asked \(server.requests.map(\.path))")

        // The other rung, by hand, from the second segment: its picture is the smaller one (the start was the larger).
        let small = try #require(demuxer.variants.min { $0.height < $1.height })
        demuxer.selectVariant(id: small.id)
        demuxer.seek(to: 1.0, exact: false)
        let landed = try #require(demuxer.nextVideoSample())
        #expect((0.9...1.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(landed))))
        var sizes = Set<Int32>()
        for _ in 0..<40 {
            guard let sample = demuxer.nextVideoSample(), let description = CMSampleBufferGetFormatDescription(sample)
            else { break }
            sizes.insert(CMVideoFormatDescriptionGetDimensions(description).height)
        }
        #expect(sizes == [90], "pictures of heights \(sizes)")
    }
}

/// Adaptive bitrate on a live history's ladder against `TestHTTPServer` throttled, as a DASH ladder's
/// (`DASHAdaptiveBitrateTests`): the history's rungs are the client's variants, and a slow link brings the picture down.
@Suite("Live history adaptive bitrate", .serialized, .realtimePlayback, .backstopTimeLimit)
struct LiveHistoryAdaptiveBitrateTests {
    @Test("A slow network brings a history's picture down to the rung it carries, without stalling")
    func followsTheNetwork() async throws {
        guard let server = try DASHLadderTests.server() else { return }
        defer { server.stop() }
        let count = SyntheticTestMediaFactory.dashLadderSegmentCount
        let rungs = SyntheticTestMediaFactory.dashLadderRungs
        var manifest = SegmentedDASHManifest(
            streams: rungs.enumerated().map { index, rung in
                .init(
                    kind: .video, id: "video\(index)", container: "mp4", codecs: "avc1.64001f", bandwidth: rung.bitrate,
                    width: rung.width, height: rung.height, frameRate: 25, group: "video",
                    url: LiveHistory.streamAddress("video\(index)"))
            } + [
                .init(
                    kind: .audio, id: "audio", container: "mp4", codecs: "mp4a.40.2", bandwidth: 64_000, group: "audio",
                    language: "en", url: LiveHistory.streamAddress("audio"))
            ], segmentDuration: 1, segmentCount: count)
        manifest.firstNumber = 0
        manifest.startTime = 0
        let source = TestLiveSource(base: String(server.url("").dropLast()), waitLimit: .milliseconds(400))
        source.report(head: LiveHead(number: count - 1, startTime: Double(count - 1)))
        let history = LiveHistory(origin: 0, end: Double(count - 1), headNumber: count - 1, source: source)
        let demuxer = try #require(
            MediaDemuxer(url: MediaURL.inlineDASHManifest(manifest.text()), liveHistory: history))
        #expect(demuxer.variants.map(\.width) == [480, 320, 160])
        #expect(demuxer.isAdaptiveBitrateEnabled)
        demuxer.adaptiveBitrateConfig = AdaptiveBitrateTests.config(readAhead: 3)

        // What opening read says nothing of the network playback meets. 0.5 Mbit/s carries the 0.35 Mbit/s rung, not the 0.8
        // one the history starts on.
        _ = demuxer.network?.transferMeter?.take()
        let since = Date()
        server.setLinkRate(500_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 3))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer, startAhead: 2.5)
        defer { consumer.stop() }

        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(20)) { consumer.playedWidth == 320 },
            "Playing \(String(describing: consumer.playedWidth)); the variant is \(String(describing: demuxer.selectedVariantId))"
        )
        AdaptiveBitrateTests.expectCameDownWithoutStalling(consumer, to: 320, demuxer: demuxer, since: since)
        #expect(demuxer.isAdaptiveBitrateEnabled, "The network chose, not the viewer")
    }
}
