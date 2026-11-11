import CFFmpeg
import CoreMedia
import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

/// Whether the FFmpeg linked has `scripts/patches/ffmpeg-dashdec-interrupt.patch` (the build says so in its version,
/// `--extra-version` in `build_dependencies.sh`): without it a DASH demuxer that is interrupted while it reads can go round at full speed for as
/// long as the interrupt lasts. Only the test that seeks hundreds of times needs it to end; the others hold on any build.
let hasDashInterruptPatch = String(cString: av_version_info()).contains("nits-dash-interrupt")

private let needsDashInterruptPatch: ConditionTrait = .enabled(
    if: hasDashInterruptPatch, "needs the bundled FFmpeg with the DASH interrupt patch")

/// For stress loops only, which hold a slot of the network budget for seconds: not for a test that fails in a strict pool,
/// which the check of the HTTP suites (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) is there to catch. In a pool of one thread
/// the loops below hold the only one, and the timing tests of the other suites failed more with them (two runs: 2 and 4
/// failures against 2 and 1 at the commit before, and as at that commit with the loops skipped). They run in any other.
private let notInStrictPool: ConditionTrait = .enabled(
    if: ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == nil,
    "holds the only thread of a strict pool for seconds")

/// A live stream's past given as numbered segments (`LiveHistory`): the segments carry the stream's time, hours into
/// it, so the demuxer plays them as live on a timeline from zero. The segments are those of the `dashSegments` preset,
/// whose timestamps run on from segment to segment; the window starts at the second, as a day-deep window does hours
/// into a stream. Needs FFmpeg built with libxml2 (the bundled one), else the tests do nothing.
@Suite(
    "Live history demuxing", .serialized, .hostDependent, .networkServer, .backstopTimeLimit)
struct LiveHistoryDemuxerTests {
    private static var count: Int { SyntheticTestMediaFactory.dashSegmentCount }
    /// The first segment of the window, and its start in the stream's time.
    private static let first = 1

    private static func manifest(server: TestHTTPServer, firstNumber: Int, count: Int) -> SegmentedDASHManifest {
        var manifest = SegmentedDASHManifest(
            streams: [
                .init(kind: .video, id: "v", container: "mp4", url: server.url("video")),
                .init(kind: .audio, id: "a", container: "mp4", url: server.url("audio")),
            ], segmentDuration: 1, segmentCount: count - firstNumber)
        manifest.firstNumber = firstNumber
        manifest.startTime = Double(firstNumber)
        return manifest
    }

    private func demuxer(server: TestHTTPServer) throws -> MediaDemuxer {
        let manifest = Self.manifest(server: server, firstNumber: Self.first, count: Self.count)
        let history = LiveHistory(origin: Double(Self.first), end: Double(Self.count))
        return try #require(
            MediaDemuxer(url: MediaURL.inlineDASHManifest(manifest.text()), liveHistory: history))
    }

    @Test("The window plays as live, with no duration, from zero, and its start in the stream's time is told")
    func playsAsLive() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let demuxer = try demuxer(server: server)
        #expect(demuxer.isLive)
        #expect(demuxer.durationSeconds == 0)
        #expect(demuxer.streamTimeOrigin == Double(Self.first))
        let window = try #require(demuxer.liveWindow)
        #expect(window == LiveWindow(start: 0, end: Double(Self.count - Self.first), hasSlid: true))

        demuxer.startReadAhead()
        let firstSample = try #require(demuxer.nextVideoSample())
        let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(firstSample))
        #expect((-0.1...0.1).contains(start), "The first picture is at \(start) s, not the stream's \(Self.first)")
        var pictures = 1
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures == 25 * (Self.count - Self.first))
        // Read to the end of the manifest, the window stays the resolver's: the format context's would say the playlist
        // ended.
        #expect(demuxer.liveWindow == window)
        #expect(demuxer.liveReport?.window.hasEnded == false)
    }

    @Test("A seek is in the window's time, and lands on the keyframe of the segment that holds it")
    func seeksInWindowTime() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let demuxer = try demuxer(server: server)
        demuxer.startReadAhead()
        demuxer.seek(to: 2.5, exact: false)
        let first = try #require(demuxer.nextVideoSample())
        let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))
        #expect((1.9...2.1).contains(start), "Keyframe of the third segment of the window, not \(start)")
        let asked = server.requests.map(\.path)
        // The first segment is read at opening; the one between it and the target is not.
        #expect(asked.contains("video/\(Self.first)"))
        #expect(!asked.contains("video/\(Self.first + 1)"), "\(asked)")
        #expect(asked.contains("video/\(Self.first + 2)"))
    }

    @Test("A seek made while the media is live takes the input from a read in progress")
    func seekYieldsToTheRead() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let demuxer = try demuxer(server: server)
        #expect(demuxer.isLive)
        demuxer.startReadAhead()
        // `seek` yields the input to itself for a live stream (`lockIO(yielding:)`), as the read-ahead may sit in a
        // wait for the next segment; here it still lands where it was asked to.
        demuxer.seek(to: 1.5, exact: false)
        let first = try #require(demuxer.nextVideoSample())
        let landed = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))
        #expect((0.9...1.1).contains(landed), "landed at \(landed)")
    }

    @Test(
        "Seeks made while the read-ahead is in the middle of the segments never wait for it for good",
        needsDashInterruptPatch, notInStrictPool)
    func seeksRepeatedlyWhileReading() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        // Without `ffmpeg-dashdec-interrupt.patch` FFmpeg's DASH demuxer returns "a packet read, none given" when it is
        // interrupted, and libavformat reads again for as long as the interrupt lasts. A seek that interrupted it, holding
        // the interrupt until it had the input the read was holding, waited for good: three runs in four, within a hundred
        // and fifty seeks. The hang here is the suite's time limit.
        for round in 0..<300 {
            let demuxer = try demuxer(server: server)
            demuxer.startReadAhead()
            if round % 3 == 1 { Thread.sleep(forTimeInterval: 0.01) }
            demuxer.seek(to: 1.5, exact: false)
            let there = try #require(demuxer.nextVideoSample())
            #expect((0.9...1.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(there))))
            demuxer.seek(to: 0.2, exact: false)
            let back = try #require(demuxer.nextVideoSample())
            #expect((-0.1...0.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(back))))
        }
    }

    @Test(
        "A stream cancelled from outside at any moment of its read (a stop, a load that replaces it) ends the read",
        notInStrictPool)
    func cancelsAReadAtAnyMoment() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        // The engine cancels the interrupt (`PlayerEngine.currentInterruptContext`), then lets the demuxer go: closing
        // waits for the read to give the input up. A read cut short inside a segment ends with an error, as it should;
        // one cancelled between a segment's end and the next one's start came back from FFmpeg's DASH demuxer as "a packet
        // read" (unpatched: `dash_read_packet`), again and again. So the rounds cancel at any moment from 0 to 20 ms. (On the unpatched library none of 400 looped: this holds the patched one to it.)
        var generator = SystemRandomNumberGenerator()
        for round in 0..<150 {
            let isWindow = round % 2 == 0
            let context = FFmpegInterrupt()
            let manifest = Self.manifest(server: server, firstNumber: isWindow ? Self.first : 0, count: Self.count)
            let started = ContinuousClock.now
            do {
                let url = MediaURL.inlineDASHManifest(manifest.text())
                let history = isWindow ? LiveHistory(origin: Double(Self.first), end: Double(Self.count)) : nil
                let demuxer = try #require(MediaDemuxer(url: url, interruptContext: context, liveHistory: history))
                demuxer.startReadAhead()
                Thread.sleep(forTimeInterval: Double.random(in: 0...0.02, using: &generator))
                context.cancel()
            }
            #expect(ContinuousClock.now - started < .seconds(5), "round \(round) took \(ContinuousClock.now - started)")
        }
    }

    @Test(
        "A segment that fails for good is a hole in the time, not a shift of it: the next plays at its own time",
        arguments: ["video", "audio"])
    func skipsASegmentThatFails(stream: String) throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        // Segments 0 to 3, a second each. The server never gives the second one of one of the streams.
        server.setBehavior(.init(failure: .status(404)), forPaths: { $0 == "\(stream)/1" })
        let manifest = Self.manifest(server: server, firstNumber: 0, count: Self.count)
        let demuxer = try #require(
            MediaDemuxer(
                url: MediaURL.inlineDASHManifest(manifest.text()),
                liveHistory: LiveHistory(origin: 0, end: Double(Self.count))))
        demuxer.startReadAhead()
        var pictures: [Double] = []
        while let sample = demuxer.nextVideoSample() {
            pictures.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        var sounds: [Double] = []
        let audioBase = Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den)
        while let packet = demuxer.nextAudioPacket() { sounds.append(Double(packet.pts) * audioBase) }

        func inSecond(_ times: [Double], _ second: Int) -> Int {
            times.filter { $0 >= Double(second) - 0.001 && $0 < Double(second + 1) - 0.001 }.count
        }
        // The stream that lost a segment has next to nothing in its second (the sound's segments are not a second to the
        // packet: a few at the edges of the neighbours), and its next segments are where they were: a shift would put
        // them a second early. The other is whole, so the two stay together.
        let lost = stream == "video" ? pictures : sounds
        let whole = stream == "video" ? sounds : pictures
        let full = stream == "video" ? 25 : 43
        #expect(inSecond(lost, 1) <= 5, "\(stream) has \(inSecond(lost, 1)) in the second that failed")
        #expect(inSecond(lost, 1) < full / 4)
        #expect(
            inSecond(lost, 0) > 0 && inSecond(lost, 2) > 0 && inSecond(lost, 3) > 0,
            "\(lost.first ?? -1)…\(lost.last ?? -1)")
        #expect((lost.max() ?? 0) > 3, "the last segment is not at its time: \(lost.max() ?? 0)")
        for second in 0..<4 {
            #expect(
                inSecond(whole, second) >= (stream == "video" ? 40 : 24), "the other stream lacks its second \(second)")
        }
    }
}

/// The same window through a load: the engine takes the resolver's `LiveHistory` to the demuxer, and plays the media as
/// a live stream (`PlayerEngine.live`) whose time is the window's, the stream's time kept in `MediaInfo`.
@Suite(
    "Live history in the engine", .serialized, .hostDependent, .realtimePlayback, .networkServer, .backstopTimeLimit)
@MainActor
struct LiveHistoryEngineTests {
    final class Resolver: MediaResolver {
        let media: ResolvedMedia
        init(_ media: ResolvedMedia) { self.media = media }
        func order(for url: URL) -> MediaResolutionOrder? { url.path == "/watch" ? .beforeOpening : nil }
        func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? { media }
    }

    @Test("A resolved live history loads as live: no duration, a window from zero, the stream's time kept")
    func loadsAsLive() async throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let first = 1
        let count = SyntheticTestMediaFactory.dashSegmentCount
        var manifest = SegmentedDASHManifest(
            streams: [
                .init(kind: .video, id: "v", container: "mp4", url: server.url("video")),
                .init(kind: .audio, id: "a", container: "mp4", url: server.url("audio")),
            ], segmentDuration: 1, segmentCount: count - first)
        manifest.firstNumber = first
        manifest.startTime = Double(first)
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.mediaResolver = Resolver(
            ResolvedMedia(
                path: MediaURL.inlineDASHManifest(manifest.text()), historyKey: "youtube:live",
                liveHistory: LiveHistory(origin: Double(first), end: Double(count))))

        let began = ContinuousClock.now
        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=live"))
        await engine.waitForPendingLoad()
        try #require(engine.isLoaded)
        #expect(engine.live.isLive)
        #expect(engine.media.isLive)
        #expect(engine.media.duration == 0)
        #expect(engine.media.timelineOrigin == Double(first))
        let window = try #require(engine.live.window())
        // It slides with the clock from the first load (`hasSlid`): by no more than the time the load and this took.
        let elapsed = (ContinuousClock.now - began) / .seconds(1)
        #expect((0...elapsed + 1).contains(window.start), "\(window) \(elapsed) s after the load began")
        #expect(window.hasSlid)
        #expect(!engine.live.isEnded)
        // A stream starts behind its edge, never before the window's start, and seeks are kept inside the window.
        #expect(engine.currentTime >= 0)
        #expect(engine.live.clamp(-5) >= 0)
        #expect(engine.live.clamp(1_000_000) <= window.end)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
    }

    // MARK: The position

    /// An engine that loads the window (segments 1 to 3 of the preset, the stream's time 1 to 4) as the stream whose
    /// history is `youtube:live`, told to end at `end` in the stream's time: a window longer than its segments, for a start
    /// to be told apart from the edge. The history is `history`.
    private func engine(
        server: TestHTTPServer, history: PlaybackHistoryStore, end: Double, startThreshold: Double = 0
    ) -> PlayerEngine {
        var manifest = SegmentedDASHManifest(
            streams: [
                .init(kind: .video, id: "v", container: "mp4", url: server.url("video")),
                .init(kind: .audio, id: "a", container: "mp4", url: server.url("audio")),
            ], segmentDuration: 1, segmentCount: SyntheticTestMediaFactory.dashSegmentCount - 1)
        manifest.firstNumber = 1
        manifest.startTime = 1
        let engine = PlayerEngine.makeForTesting(
            configuration: PlayerConfiguration(resumePlayback: true, resumeStartThreshold: startThreshold),
            historyStore: history)
        engine.mediaResolver = Resolver(
            ResolvedMedia(
                path: MediaURL.inlineDASHManifest(manifest.text()), historyKey: "youtube:live",
                liveHistory: LiveHistory(origin: 1, end: end)))
        return engine
    }

    private static let page = "https://video.example/watch?v=live"
    private static let identity = MediaHistoryIdentity(historyKey: "youtube:live")

    @Test("A live history saves where it is in the stream's time, and whether that is its edge")
    func savesInTheStreamsTime() async throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let history = PlaybackHistoryStore(fileURL: nil)
        let engine = engine(server: server, history: history, end: 4)
        defer { engine.stop() }
        #expect(engine.playbackProgress == nil)  // nothing loaded
        engine.load(MediaLoadRequest(path: Self.page))
        await engine.waitForPendingLoad()
        try #require(engine.isLoaded)
        try #require(await engine.waitForPlayback(advancingBy: 0.4))
        engine.saveCurrentPlaybackProgress()

        let saved = try #require(engine.historyStore.savedLivePosition(for: Self.identity))
        // The engine's time plus where its zero stands, within a tick of the clock moving on.
        #expect(abs(saved.position - (engine.currentTime + 1)) < 0.5, "\(saved.position) at \(engine.currentTime)")
        #expect(saved.position > 1.3)
        // A window of three seconds is all edge.
        #expect(saved.wasAtEdge)

        // What the engine tells a host that keeps progress of its own is what it saved: the stream's time, against
        // the stream as far as it is known (the window's end, at least 4, moving on with the clock), on the air and at
        // its edge.
        let progress = try #require(engine.playbackProgress)
        #expect(abs(progress.position - (engine.currentTime + 1)) < 0.5, "\(progress.position)")
        #expect(progress.duration >= max(4, progress.position), "\(progress.duration)")
        #expect(progress.isLive)
        #expect(progress.wasAtLiveEdge)
    }

    @Test("A live history opens where it was left, if the window holds it and it was not left at the edge")
    func resumesWhereLeft() async throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let history = PlaybackHistoryStore(fileURL: nil)
        let engine = engine(server: server, history: history, end: 301)
        defer { engine.stop() }
        // Left 40 s into a window of 300, in the stream's time: where the window starts, 1, plus 40.
        engine.historyStore.savePosition(
            for: Self.identity, position: 41, duration: 301, startThreshold: 0, isLive: true, wasAtLiveEdge: false)
        engine.load(MediaLoadRequest(path: Self.page))
        await engine.waitForPendingLoad()
        try #require(engine.isLoaded)
        #expect(abs(engine.currentTime - 40) < 1.5, "opened at \(engine.currentTime)")
    }

    @Test("A start the request asks for is not overridden by the position saved: a live history has only its edge")
    func anExplicitStartKeepsTheEdge() async throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let engine = engine(server: server, history: PlaybackHistoryStore(fileURL: nil), end: 301)
        defer { engine.stop() }
        engine.historyStore.savePosition(
            for: Self.identity, position: 41, duration: 301, startThreshold: 0, isLive: true, wasAtLiveEdge: false)
        engine.load(MediaLoadRequest(path: Self.page, startTime: 5))
        await engine.waitForPendingLoad()
        try #require(engine.isLoaded)
        #expect(engine.currentTime > 280, "opened at \(engine.currentTime), not at the edge")
    }

    @Test("A live history left at its edge, or before the window, opens at the edge")
    func opensAtTheEdge() async throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        for (saved, atEdge) in [(299.0, true), (41.0, true), (-30.0, false)] {
            let engine = engine(server: server, history: PlaybackHistoryStore(fileURL: nil), end: 301)
            defer { engine.stop() }
            engine.historyStore.savePosition(
                for: Self.identity, position: saved, duration: 301, startThreshold: 0, isLive: true,
                wasAtLiveEdge: atEdge)
            // A negative position is not saved at all; a record from some other run, long before the window, stands for it.
            if saved < 0 {
                engine.historyStore.savePosition(
                    for: Self.identity, position: 0.5, duration: 301, startThreshold: 0, isLive: true,
                    wasAtLiveEdge: false)
            }
            engine.load(MediaLoadRequest(path: Self.page))
            await engine.waitForPendingLoad()
            try #require(engine.isLoaded)
            // The edge is the window's end less the margin: 294 s into the window of 300, give or take what slid.
            #expect(engine.currentTime > 280, "opened at \(engine.currentTime), left at \(saved) (edge: \(atEdge))")
        }
    }
}
