import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore
@testable import NitsStreaming

/// What a test makes of the server of a live stream: the addresses, the head it reports, the signature it renews, and
/// whether the stream is over. The waits are short (tens of milliseconds): they hold a slot of the network budget.
final class TestLiveSource: LiveSegmentSource {
    private struct State {
        var headProvider: (@Sendable () -> LiveHead?)?
        var answersWithoutHead = false
        var headAsked = 0
        var endedAsked = 0
        var endedAnswer: Bool? = true
        var renewals = 0
        var onRenew: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let base: String
    let segmentWaitLimit: Duration
    let headPollInterval: Duration

    /// `base` is where the segments are (`TestHTTPServer.url`, or an address nobody serves, for the tests that fake the
    /// answers).
    init(base: String, waitLimit: Duration, pollInterval: Duration = .milliseconds(30)) {
        self.base = base
        self.segmentWaitLimit = waitLimit
        self.headPollInterval = pollInterval
    }

    var headsAsked: Int { state.withLock { $0.headAsked } }
    var endedAsked: Int { state.withLock { $0.endedAsked } }
    var renewals: Int { state.withLock { $0.renewals } }

    func report(head: LiveHead?) { state.withLock { $0.headProvider = { head } } }
    func report(heads: @escaping @Sendable () -> LiveHead?) { state.withLock { $0.headProvider = heads } }
    /// What the source says of the end of the stream: it is over, it is not, it cannot tell.
    func say(ended: Bool?) { state.withLock { $0.endedAnswer = ended } }
    /// The server answers the head's ask, and the answer holds no head (a 404 without the headers).
    func answerWithoutHead() { state.withLock { $0.answersWithoutHead = true } }
    func onRenew(_ action: (@Sendable () -> Void)?) { state.withLock { $0.onRenew = action } }

    func url(for key: String, number: Int) -> URL? { URL(string: "\(base)/\(key)/\(number)") }

    func head(shouldAbort: () -> Bool) -> LiveHeadAnswer {
        let (provider, withoutHead) = state.withLock { state -> ((@Sendable () -> LiveHead?)?, Bool) in
            state.headAsked += 1
            return (state.headProvider, state.answersWithoutHead)
        }
        if let head = provider?() { return .head(head) }
        return withoutHead ? .answeredWithoutHead : .noAnswer
    }

    func hasEnded(shouldAbort: () -> Bool) -> Bool? {
        state.withLock { state in
            state.endedAsked += 1
            return state.endedAnswer
        }
    }

    func renewSignature(shouldAbort: () -> Bool) -> Bool {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            state.renewals += 1
            return state.onRenew
        }
        action?()
        return true
    }
}

/// A clock a test moves.
private final class TestClock: Sendable {
    private let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
    func read() -> Date { now.withLock { $0 } }
    func advance(_ seconds: Double) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// What a live stream's history lists of its manifest (`DASHHistory`), by itself: the head, the end, the slide.
@Suite("Live history playlists")
struct DASHHistoryListingTests {
    /// A day of 5 s segments numbered from `first`, as the resolver's manifest lists.
    private static func playlist(first: Int = 10, count: Int = 100) -> HLSMediaPlaylist {
        var playlist = HLSMediaPlaylist(targetDuration: 5)
        playlist.type = .vod
        playlist.hasEnded = true
        playlist.segments = (0..<count).map { index in
            HLSSegment(
                url: URL(string: "https://live.nits.invalid/v?sq=\(first + index)")!, duration: 5,
                sequence: first + index, discontinuitySequence: 0)
        }
        playlist.mediaSequence = first
        return playlist
    }

    private static func history(
        source: TestLiveSource, head: Int, clock: TestClock = TestClock()
    ) -> (DASHHistory, TestClock) {
        (DASHHistory(source: LiveSegmentSourceBridge(source), head: head, clock: { clock.read() }), clock)
    }

    private static let never: @Sendable () -> Bool = { false }

    private static func source(waitLimit: Duration = .seconds(60)) -> TestLiveSource {
        // A poll every 5 s of the test clock.
        TestLiveSource(base: "https://media.example", waitLimit: waitLimit, pollInterval: .seconds(5))
    }

    @Test("It lists up to the segment before the head, as a playlist that is not over and does not go stuck")
    func listsBeforeTheHead() {
        let (history, _) = Self.history(source: Self.source(), head: 50)
        let listed = history.listing(of: Self.playlist(), shouldAbort: Self.never)
        #expect(listed.segments.first?.sequence == 10)
        #expect(listed.segments.last?.sequence == 49)
        #expect(listed.mediaSequence == 10)
        #expect(listed.isLive)
        #expect(listed.updatePeriod == DASHHistory.updatePeriod)
    }

    @Test("A head of the first segment lists it anyway: a stream of one segment is not empty")
    func listsAtLeastTheFirst() {
        let (history, _) = Self.history(source: Self.source(), head: 10)
        let listed = history.listing(of: Self.playlist(), shouldAbort: Self.never)
        #expect(listed.segments.map(\.sequence) == [10])
    }

    @Test("The head is asked when it is due and no sooner, and what it tells is listed from then on")
    func asksTheHeadWhenDue() {
        let source = Self.source()
        let (history, clock) = Self.history(source: source, head: 50)
        let full = Self.playlist()
        // The opening's own asks (the playlists side by side) are answered with what the resolver knew.
        _ = history.listing(of: full, shouldAbort: Self.never)
        _ = history.listing(of: full, shouldAbort: Self.never)
        #expect(source.headsAsked == 0)

        source.report(head: LiveHead(number: 53, startTime: 0))
        clock.advance(4)
        #expect(history.listing(of: full, shouldAbort: Self.never).segments.last?.sequence == 49)
        #expect(source.headsAsked == 0)
        clock.advance(1.5)
        #expect(history.listing(of: full, shouldAbort: Self.never).segments.last?.sequence == 52)
        #expect(source.headsAsked == 1)
        // Asked at once again: not asked.
        #expect(history.listing(of: full, shouldAbort: Self.never).segments.last?.sequence == 52)
        #expect(source.headsAsked == 1)
        // A head that went back is no news.
        source.report(head: LiveHead(number: 40, startTime: 0))
        clock.advance(6)
        #expect(history.listing(of: full, shouldAbort: Self.never).segments.last?.sequence == 52)
    }

    @Test(
        "A head that stood still for the limit asks the source, and an end is a recording that lists the head's segment"
    )
    func endsWhenTheSourceSaysSo() {
        let source = Self.source(waitLimit: .seconds(30))
        source.report(head: LiveHead(number: 50, startTime: 0))
        let (history, clock) = Self.history(source: source, head: 50)
        let full = Self.playlist()
        clock.advance(6)
        _ = history.listing(of: full, shouldAbort: Self.never)
        #expect(source.endedAsked == 0, "not yet: the head stood still for 6 s")
        clock.advance(25)
        let listed = history.listing(of: full, shouldAbort: Self.never)
        #expect(source.endedAsked == 1)
        #expect(history.isEnded)
        #expect(listed.hasEnded)
        #expect(!listed.isLive)
        #expect(listed.segments.last?.sequence == 50, "the head's segment is the last, whole")
        // Over for good: nothing is asked again.
        clock.advance(60)
        _ = history.listing(of: full, shouldAbort: Self.never)
        #expect(source.endedAsked == 1)
        #expect(source.headsAsked == 2)
    }

    @Test("A stream on the air that goes silent is waited for with no limit, asking again after each limit")
    func waitsForAStreamStillOnTheAir() {
        let source = Self.source(waitLimit: .seconds(30))
        source.report(head: LiveHead(number: 50, startTime: 0))
        source.say(ended: false)
        let (history, clock) = Self.history(source: source, head: 50)
        let full = Self.playlist()
        for _ in 0..<6 {
            clock.advance(31)
            _ = history.listing(of: full, shouldAbort: Self.never)
        }
        #expect(!history.isEnded)
        #expect(source.endedAsked == 6)
        // It speaks again: the head moves on, and the list with it.
        source.report(head: LiveHead(number: 60, startTime: 0))
        clock.advance(6)
        #expect(history.listing(of: full, shouldAbort: Self.never).segments.last?.sequence == 59)
    }

    @Test("A head that moves is never asked about the end, however long the stream goes on")
    func noEndWhileTheHeadMoves() {
        let source = Self.source(waitLimit: .seconds(30))
        let (history, clock) = Self.history(source: source, head: 20)
        let full = Self.playlist(count: 1000)
        for head in 21..<60 {
            source.report(head: LiveHead(number: head, startTime: 0))
            clock.advance(6)
            _ = history.listing(of: full, shouldAbort: Self.never)
        }
        #expect(source.endedAsked == 0)
        #expect(!history.isEnded)
    }

    @Test("An end that cannot be told ends the stream while the server answers, and never when it does not")
    func anEndThatCannotBeTold() {
        // The server answers (without a head: a 404): after a few asks, the end.
        let answering = Self.source(waitLimit: .seconds(30))
        answering.say(ended: nil)
        answering.answerWithoutHead()
        let (history, clock) = Self.history(source: answering, head: 50)
        let full = Self.playlist()
        for _ in 0...DASHHistory.unknownRounds {
            #expect(!history.isEnded)
            clock.advance(31)
            _ = history.listing(of: full, shouldAbort: Self.never)
        }
        #expect(history.isEnded)
        #expect(answering.endedAsked == DASHHistory.unknownRounds + 1)

        // No answer at all: the network is down, waited for however long.
        let silent = Self.source(waitLimit: .seconds(30))
        silent.say(ended: nil)
        let (waiting, otherClock) = Self.history(source: silent, head: 50)
        for _ in 0..<(DASHHistory.unknownRounds * 3) {
            otherClock.advance(31)
            _ = waiting.listing(of: full, shouldAbort: Self.never)
        }
        #expect(!waiting.isEnded)
    }

    @Test("A wait given way to a seek or a close decides nothing")
    func givesWayToAbort() {
        let source = Self.source(waitLimit: .seconds(30))
        source.report(head: LiveHead(number: 50, startTime: 0))
        let (history, clock) = Self.history(source: source, head: 50)
        clock.advance(40)
        _ = history.listing(of: Self.playlist(), shouldAbort: { true })
        #expect(!history.isEnded)
        #expect(source.endedAsked == 0)
    }

    @Test("The start slides with the clock, by whole segments: the ones whose time has passed are expired")
    func slidesWithTheClock() {
        let (history, clock) = Self.history(source: Self.source(waitLimit: .seconds(1_000_000)), head: 80)
        let full = Self.playlist()
        #expect(history.listing(of: full, shouldAbort: Self.never).segments.first?.sequence == 10)
        clock.advance(4)
        #expect(history.listing(of: full, shouldAbort: Self.never).segments.first?.sequence == 10)
        clock.advance(7)  // 11 s: two segments of 5 s have passed
        let listed = history.listing(of: full, shouldAbort: Self.never)
        #expect(listed.segments.first?.sequence == 12)
        #expect(listed.mediaSequence == 12)
        // Never past the last: a window slid to its end keeps its newest segment.
        clock.advance(10_000)
        #expect(history.listing(of: full, shouldAbort: Self.never).segments.map(\.sequence) == [Self.lastBefore(80)])
    }

    private static func lastBefore(_ head: Int) -> Int { head - 1 }

    @Test("The manifest's addresses are the source's: a key and a number, and the signature renewed")
    func mapsAddresses() throws {
        let source = TestLiveSource(base: "https://media.example", waitLimit: .seconds(1))
        var manifest = SegmentedDASHManifest(
            streams: [.init(kind: .video, id: "v", container: "mp4", url: LiveHistory.streamAddress("136"))],
            segmentDuration: 5, segmentCount: 10)
        manifest.firstNumber = 1
        let playlists = try #require(
            DASHPlaylists(
                media: MediaURL.inlineDASHManifest(manifest.text()),
                history: LiveHistory(origin: 0, end: 5, headNumber: 3, source: source).streamHistory))
        let named = try #require(URL(string: "https://live.nits.invalid/136?sq=7"))
        #expect(playlists.address(of: named)?.absoluteString == "https://media.example/136/7")
        let other = try #require(URL(string: "https://media.example/other?sq=7"))
        #expect(playlists.address(of: other) == other)
        #expect(playlists.renewAddresses(shouldAbort: { false }))
        #expect(source.renewals == 1)

        #expect(LiveHistory.segment(named: named)?.key == "136")
        #expect(LiveHistory.segment(named: named)?.number == 7)
        #expect(LiveHistory.segment(named: other) == nil)
        #expect(LiveHistory.segment(named: URL(string: "https://live.nits.invalid/?sq=12")!) == nil)
        #expect(LiveHistory.segment(named: URL(string: "https://live.nits.invalid/136")!) == nil)
    }
}

/// A live history through the demuxer: the segments are those of the `dashSegments` preset, 0 to 3. The window has
/// segments 1 and 2 (the head is 3: the playlist lists to the one before), the manifest goes on to 5, and the stream's
/// end, by the source, adds 3.
@Suite("Live history at its head", .serialized, .hostDependent, .networkServer, .backstopTimeLimit)
struct DASHHistoryPlaybackTests {
    private static func source(server: TestHTTPServer, waitLimit: Duration) -> TestLiveSource {
        TestLiveSource(base: String(server.url("").dropLast()), waitLimit: waitLimit)
    }

    private static func demuxer(source: TestLiveSource, head: Int = 3) throws -> MediaDemuxer {
        var manifest = SegmentedDASHManifest(
            streams: [
                .init(kind: .video, id: "v", container: "mp4", url: LiveHistory.streamAddress("video")),
                .init(kind: .audio, id: "a", container: "mp4", url: LiveHistory.streamAddress("audio")),
            ], segmentDuration: 1, segmentCount: 5)
        manifest.firstNumber = 1
        manifest.startTime = 1
        let history = LiveHistory(origin: 1, end: Double(head), headNumber: head, source: source)
        return try #require(MediaDemuxer(url: MediaURL.inlineDASHManifest(manifest.text()), liveHistory: history))
    }

    private static func pictures(of demuxer: MediaDemuxer) -> Int {
        var count = 0
        while demuxer.nextVideoSample() != nil { count += 1 }
        return count
    }

    /// The pictures of `segments` segments of 25, less a frame or two at the end.
    private static func expectedPictures(segments: Int) -> ClosedRange<Int> {
        (25 * segments - 2)...(25 * segments)
    }

    @Test("A stream whose head stops moving ends after the head's segment: the segments before it, then it, no hole")
    func endsAfterTheHead() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let source = Self.source(server: server, waitLimit: .milliseconds(500))
        source.report(head: LiveHead(number: 3, startTime: 3))
        let demuxer = try Self.demuxer(source: source)
        #expect(demuxer.isLive)
        demuxer.startReadAhead()
        let started = ContinuousClock.now
        let pictures = Self.pictures(of: demuxer)
        #expect(Self.expectedPictures(segments: 3).contains(pictures), "\(pictures) pictures")
        let waited = ContinuousClock.now - started
        #expect(waited > .milliseconds(400), "it did not wait for the end: \(waited)")
        #expect(source.endedAsked >= 1)
        let window = try #require(demuxer.liveWindow)
        #expect(window.hasEnded)
        // The segments past the head were never asked for.
        let past = server.requests.map(\.path).filter { $0.hasSuffix("/4") || $0.hasSuffix("/5") }
        #expect(past.isEmpty, "\(past)")
        // The segment before the head was read before the end, and the head's after it.
        #expect(server.requests.map(\.path).contains("video/3"))
    }

    @Test("The head moving on lists the segment that was the head's: the stream goes on from it, with no hole")
    func playsOnWhenTheHeadMoves() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let source = Self.source(server: server, waitLimit: .milliseconds(400))
        // The window ends before segment 2; the head moves to 3 at 0.3 s, and the stream is over from 1.5 s on.
        source.report(head: LiveHead(number: 2, startTime: 2))
        source.say(ended: false)
        let demuxer = try Self.demuxer(source: source, head: 2)
        demuxer.startReadAhead()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            source.report(head: LiveHead(number: 3, startTime: 3))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { source.say(ended: true) }
        let pictures = Self.pictures(of: demuxer)
        #expect(Self.expectedPictures(segments: 3).contains(pictures), "\(pictures) pictures")
        #expect(source.headsAsked >= 2, "asked \(source.headsAsked) time(s)")
        #expect(demuxer.liveWindow?.hasEnded == true)
    }

    @Test("A seek made while the read waits at the head is not held up by it, and is no end of the stream")
    func seeksWhileWaiting() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        // A minute of waiting: only the seek can end it.
        let source = Self.source(server: server, waitLimit: .seconds(60))
        source.report(head: LiveHead(number: 2, startTime: 2))
        let demuxer = try Self.demuxer(source: source, head: 2)
        demuxer.startReadAhead()
        let deadline = ContinuousClock.now + .seconds(10)
        let reached = { server.requests.map(\.path).contains("video/1") }
        while !reached(), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try #require(reached(), "the read never reached segment 1: \(server.requests.map(\.path))")
        Thread.sleep(forTimeInterval: 0.6)

        let started = ContinuousClock.now
        demuxer.seek(to: 0.2, exact: false)
        let seekTime = ContinuousClock.now - started
        #expect(seekTime < .seconds(2), "the seek waited \(seekTime) for the read")
        let first = try #require(demuxer.nextVideoSample())
        #expect((-0.1...0.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))))
        #expect(demuxer.liveWindow?.hasEnded == false, "a seek is no end of the stream")
    }

    @Test("An address that expired before it was renewed is renewed, and the stream opens")
    func renewsWhenRefused() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        server.setBehavior(.init(failure: .status(403)), forPaths: { $0 == "video/1" || $0 == "audio/1" })
        let source = Self.source(server: server, waitLimit: .seconds(5))
        source.report(head: LiveHead(number: 3, startTime: 3))
        source.onRenew { server.setBehavior(TestHTTPServer.Behavior(), forPaths: { $0.hasSuffix("/1") }) }
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        let first = try #require(demuxer.nextVideoSample())
        #expect((-0.1...0.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))))
        #expect(source.renewals >= 1)
    }

    // MARK: Redirects

    /// The preset's segment file `path` ("video/1"), which a mirror of it is served from.
    private static func segmentData(_ path: String) throws -> Data {
        let first = try #require(SyntheticTestMediaFactory.ensureMedia(preset: .dashSegments))
        let root = URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent(path))
    }

    /// Makes the segments `paths` answer with a redirect to a mirror of each ("mirror/video/1"), which serves the same bytes.
    private static func redirect(_ paths: [String], on server: TestHTTPServer) throws {
        for path in paths {
            let data = try segmentData(path)
            server.setResponder(forPath: "mirror/" + path) { data }
            server.setBehavior(.init(redirect: "mirror/" + path), forPaths: { $0 == path })
        }
    }

    @Test("A segment the CDN redirects (YouTube's 4K tier is on another server) is followed, and plays")
    func followsARedirect() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        try Self.redirect(["video/1", "video/2", "audio/1", "audio/2"], on: server)
        let source = Self.source(server: server, waitLimit: .milliseconds(400))
        source.report(head: LiveHead(number: 3, startTime: 3))
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        let pictures = Self.pictures(of: demuxer)
        #expect(Self.expectedPictures(segments: 3).contains(pictures), "\(pictures) pictures")
        let asked = server.requests.map(\.path)
        #expect(asked.contains("mirror/video/2") && asked.contains("mirror/audio/2"), "\(asked)")
    }

    @Test("A refusal from where a redirect led renews the signature, which may be that server's own, and goes on")
    func renewsAfterARedirect() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        try Self.redirect(["video/1", "audio/1"], on: server)
        // The mirror refuses (403) until the signature is renewed.
        server.setBehavior(.init(failure: .status(403)), forPaths: { $0.hasPrefix("mirror/") })
        let source = Self.source(server: server, waitLimit: .seconds(5))
        source.report(head: LiveHead(number: 3, startTime: 3))
        source.onRenew { server.setBehavior(TestHTTPServer.Behavior(), forPaths: { $0.hasPrefix("mirror/") }) }
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        let first = try #require(demuxer.nextVideoSample())
        #expect((-0.1...0.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))))
        #expect(source.renewals >= 1, "renewed \(source.renewals) time(s)")
    }
}

/// What the engine makes of the end of a live stream: the window of a stream that ended is the last one, a recording.
@Suite(
    "Live history ending in the engine", .serialized, .hostDependent, .realtimePlayback, .networkServer,
    .backstopTimeLimit)
@MainActor
struct LiveHistoryEndTests {
    @Test("A stream whose head stops moving is a recording once the wait ends: no edge, the window as it was")
    func endedStreamIsARecording() async throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        let source = TestLiveSource(base: String(server.url("").dropLast()), waitLimit: .milliseconds(600))
        source.report(head: LiveHead(number: 3, startTime: 3))
        var manifest = SegmentedDASHManifest(
            streams: [
                .init(kind: .video, id: "v", container: "mp4", url: LiveHistory.streamAddress("video")),
                .init(kind: .audio, id: "a", container: "mp4", url: LiveHistory.streamAddress("audio")),
            ], segmentDuration: 1, segmentCount: 5)
        manifest.firstNumber = 1
        manifest.startTime = 1
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.mediaResolver = LiveHistoryEngineTests.Resolver(
            ResolvedMedia(
                path: MediaURL.inlineDASHManifest(manifest.text()), historyKey: "youtube:live",
                liveHistory: LiveHistory(origin: 1, end: 3, headNumber: 3, source: source)))

        engine.load(MediaLoadRequest(path: "https://video.example/watch?v=live"))
        await engine.waitForPendingLoad()
        try #require(engine.isLoaded)
        #expect(engine.live.isLive)
        // (Not that it is not ended yet: in a pool of one thread a load may take longer than the wait.)

        let deadline = ContinuousClock.now + .seconds(15)
        while !engine.live.isEnded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.live.isEnded, "the engine was never told the stream ended")
        #expect(engine.live.isLive, "it stays a stream that was live, as a recording of it")
        #expect(engine.live.edgeTarget() == nil)
        let window = try #require(engine.live.window())
        #expect(window.hasEnded)
        #expect((0...window.end).contains(window.start), "slid with the clock")
        #expect(window.end >= 2, "\(window)")
        // Seeks stay in all of it.
        #expect(engine.live.clamp(1_000_000) == window.end)
        #expect(engine.live.clamp(-5) == window.start)
    }
}
