import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

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
    let reportedSegmentGrace: Duration

    /// `base` is where the segments are (`TestHTTPServer.url`, or an address nobody serves, for the tests that fake the
    /// answers).
    init(
        base: String, waitLimit: Duration, pollInterval: Duration = .milliseconds(30),
        reportedGrace: Duration = .seconds(2)
    ) {
        self.base = base
        self.segmentWaitLimit = waitLimit
        self.headPollInterval = pollInterval
        self.reportedSegmentGrace = reportedGrace
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

/// The wait for a live stream's next segment (`LiveSegmentGate`), by itself and through the demuxer.
@Suite("Live segments past the head", .serialized, .hostDependent, .networkServer, .backstopTimeLimit)
struct LiveSegmentGateTests {
    // MARK: The gate alone

    private static let never: @Sendable () -> Bool = { false }

    private static func input() -> HTTPSessionTransport.Opened {
        .input(
            HTTPSessionInput(
                holder: HTTPSessionHolder(fixed: .shared),
                request: URLRequest(url: URL(string: "https://live.nits.invalid/x")!), offset: 0,
                end: nil, meter: NetworkTransferMeter(), shouldAbort: Self.never))
    }

    private static func failure(_ code: Int32 = LiveSegmentGate.notFoundError) -> HTTPSessionTransport.Opened {
        .failed(code)
    }

    private func gate(
        source: TestLiveSource, head: Int = 10,
        onChange: @escaping @Sendable (LiveSegmentGate.Change) -> Void = { _ in }
    ) -> LiveSegmentGate {
        LiveSegmentGate(
            source: source, head: LiveHead(number: head, startTime: 100), pollInterval: .milliseconds(10),
            onChange: onChange)
    }

    @Test("The manifest's addresses are the gate's: a key and a number, nothing else is")
    func readsAddresses() {
        let gate = gate(source: TestLiveSource(base: "x", waitLimit: .seconds(1)))
        #expect(
            gate.request(for: LiveSegmentGate.address(key: "134", number: 12)) == .init(key: "134", number: 12))
        #expect(LiveSegmentGate.address(key: "140", number: 0, template: true).hasSuffix("/140?sq=$Number$"))
        #expect(gate.request(for: "https://media.example/134?sq=12") == nil)
        #expect(gate.request(for: "https://live.nits.invalid/?sq=12") == nil)
        #expect(gate.request(for: "https://live.nits.invalid/134") == nil)
    }

    @Test("A segment that fails up to the head is a failure at once; one past it is waited for until it comes")
    func tellsAFailureFromAWait() {
        let source = TestLiveSource(base: "https://media.example", waitLimit: .seconds(30))
        let gate = gate(source: source)
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        let started = ContinuousClock.now
        let past = gate.open(.init(key: "v", number: 10), shouldAbort: Self.never) { _ in
            attempts.withLock { $0 += 1 }
            return Self.failure()
        }
        guard case .failed(LiveSegmentGate.notFoundError) = past else {
            Issue.record("\(past)")
            return
        }
        #expect(attempts.withLock { $0 } == 1, "a segment up to the head is not waited for")
        #expect(ContinuousClock.now - started < .seconds(1))

        attempts.withLock { $0 = 0 }
        let arrived = gate.open(.init(key: "v", number: 11), shouldAbort: Self.never) { _ in
            // 204 (not served here), 404 and 503, then it is there.
            let n = attempts.withLock { state -> Int in
                state += 1
                return state
            }
            switch n {
            case 1: return .notServed
            case 2: return Self.failure()
            case 3: return Self.failure(HTTPSessionInput.ffErrorTag(0xF8, "5", "X", "X"))
            default: return Self.input()
            }
        }
        guard case .input = arrived else {
            Issue.record("\(arrived)")
            return
        }
        #expect(attempts.withLock { $0 } == 4)
        #expect(gate.head.number == 11, "the segment read is the head now")
        // Which the next one is judged by: 11 is a segment that should be there.
        let again = gate.open(.init(key: "v", number: 11), shouldAbort: Self.never) { _ in Self.failure() }
        guard case .failed = again else {
            Issue.record("\(again)")
            return
        }
    }

    @Test("A wait ends in the end of the stream when the head has stood still and the source says it is over")
    func endsWhenTheSourceSaysSo() {
        let source = TestLiveSource(base: "https://media.example", waitLimit: .milliseconds(80))
        source.report(head: LiveHead(number: 10, startTime: 100))
        let changes = OSAllocatedUnfairLock(initialState: [LiveSegmentGate.Change]())
        let gate = gate(source: source) { change in changes.withLock { $0.append(change) } }

        let started = ContinuousClock.now
        let result = gate.open(.init(key: "v", number: 11), shouldAbort: Self.never) { _ in Self.failure() }
        guard case .failed(LiveSegmentGate.notFoundError) = result else {
            Issue.record("\(result)")
            return
        }
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(80) && waited < .seconds(2), "\(waited)")
        #expect(gate.isEnded)
        #expect(source.endedAsked == 1)
        #expect(changes.withLock { $0 } == [.ended(lastNumber: 10, endTime: 105)])

        let asked = OSAllocatedUnfairLock(initialState: 0)
        let next = gate.open(.init(key: "a", number: 12), shouldAbort: Self.never) { _ in
            asked.withLock { $0 += 1 }
            return Self.failure()
        }
        guard case .failed = next else {
            Issue.record("\(next)")
            return
        }
        #expect(ContinuousClock.now - started - waited < .milliseconds(500), "no second wait")
        #expect(changes.withLock { $0.count } == 1, "the end is told once")
    }

    @Test("While the head moves the wait goes on, however long it takes, and no end is asked about")
    func waitsWhileTheHeadMoves() {
        let source = TestLiveSource(base: "https://media.example", waitLimit: .milliseconds(60))
        let gate = gate(source: source)
        // The head moves at every ask: the stream is alive, though its next segment is slow.
        let moves = OSAllocatedUnfairLock(initialState: 10)
        source.report {
            let number = moves.withLock { state -> Int in
                state += 1
                return state
            }
            return LiveHead(number: number, startTime: Double(number))
        }
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let slow = gate.open(.init(key: "v", number: 30), shouldAbort: Self.never) { _ in
            attempts.withLock { state in
                state += 1
                return state < 40 ? Self.failure() : Self.input()  // about 450 ms: seven limits of 60 ms
            }
        }
        guard case .input = slow else {
            Issue.record("\(slow)")
            return
        }
        #expect(!gate.isEnded)
        #expect(source.endedAsked == 0, "a head that moves is no head that stood still")
    }

    @Test("A segment the head says is there but the server does not give is left to the demuxer after a few seconds")
    func skipsASegmentReportedButNotServed() {
        let source = TestLiveSource(
            base: "https://media.example", waitLimit: .seconds(30), reportedGrace: .milliseconds(120))
        source.report(head: LiveHead(number: 99, startTime: 500))
        let gate = gate(source: source)
        let started = ContinuousClock.now
        let result = gate.open(.init(key: "v", number: 11), shouldAbort: Self.never) { _ in Self.failure() }
        guard case .failed = result else {
            Issue.record("\(result)")
            return
        }
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(100) && waited < .seconds(2), "\(waited)")
        #expect(!gate.isEnded, "it is no end of the stream")
        #expect(source.endedAsked == 0)
    }

    @Test("A stream still on the air that goes silent is waited for with no limit, however many limits it takes")
    func waitsForAStreamThatIsStillOnTheAir() {
        let source = TestLiveSource(base: "https://media.example", waitLimit: .milliseconds(60))
        source.report(head: LiveHead(number: 10, startTime: 100))
        source.say(ended: false)
        let gate = gate(source: source)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let result = gate.open(.init(key: "v", number: 11), shouldAbort: Self.never) { _ in
            attempts.withLock { state in
                state += 1
                // About 450 ms: the head stood still for seven limits.
                return state < 40 ? Self.failure() : Self.input()
            }
        }
        guard case .input = result else {
            Issue.record("\(result)")
            return
        }
        #expect(!gate.isEnded)
        #expect(source.endedAsked >= 3, "asked \(source.endedAsked) time(s)")
    }

    @Test(
        "A source that cannot tell, with the server answering and its head standing still, is the end after a few asks")
    func anEndThatCannotBeToldWhileTheServerAnswers() {
        // (The head is asked more often than the limit, so that the server is known to answer before the source is.)
        let source = TestLiveSource(
            base: "https://media.example", waitLimit: .milliseconds(40), pollInterval: .milliseconds(5))
        source.report(head: LiveHead(number: 10, startTime: 100))
        source.say(ended: nil)
        let gate = gate(source: source)
        let result = gate.open(.init(key: "v", number: 11), shouldAbort: Self.never) { _ in Self.failure() }
        guard case .failed(LiveSegmentGate.notFoundError) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(gate.isEnded)
        #expect(source.endedAsked == LiveSegmentGate.unknownRounds + 1)
    }

    @Test("A refusal that tells no head is still the server being there: the stream that is gone is the end")
    func anAnswerWithoutAHeadIsTheServerAnswering() {
        for sourceSays in [true, nil] as [Bool?] {
            let source = TestLiveSource(
                base: "https://media.example", waitLimit: .milliseconds(40), pollInterval: .milliseconds(5))
            source.answerWithoutHead()
            source.say(ended: sourceSays)
            let gate = gate(source: source)
            let result = gate.open(.init(key: "v", number: 11), shouldAbort: Self.never) { _ in Self.failure() }
            guard case .failed(LiveSegmentGate.notFoundError) = result else {
                Issue.record("\(result) (the source says \(String(describing: sourceSays)))")
                return
            }
            #expect(gate.isEnded, "the source says \(String(describing: sourceSays))")
        }
    }

    @Test("With the server not answering it is the network: waited for as long as it takes, never a hole in the time")
    func aServerThatDoesNotAnswerIsWaitedFor() {
        for sourceSays in [false, nil] as [Bool?] {
            let source = TestLiveSource(base: "https://media.example", waitLimit: .milliseconds(20))
            source.report(head: nil)
            source.say(ended: sourceSays)
            let gate = gate(source: source)
            let abort = OSAllocatedUnfairLock(initialState: false)
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.4)
                abort.withLock { $0 = true }
            }
            let isAborted: @Sendable () -> Bool = { abort.withLock { $0 } }
            let started = ContinuousClock.now
            let result = gate.open(.init(key: "v", number: 11), shouldAbort: isAborted) { _ in Self.failure() }
            // Many limits went by (twenty milliseconds each), and what ended the wait was the abort, not a failure handed to
            // the demuxer to skip.
            guard case .failed(HTTPSessionInput.averrorExit) = result else {
                Issue.record("\(result) (the source says \(String(describing: sourceSays)))")
                return
            }
            #expect(ContinuousClock.now - started >= .milliseconds(350))
            #expect(!gate.isEnded)
        }
    }

    @Test("A wait gives way at once to a seek or a close, and tells it with FFmpeg's exit")
    func givesWayToAbort() {
        let source = TestLiveSource(base: "https://media.example", waitLimit: .seconds(60))
        let gate = gate(source: source)
        let abort = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.15)
            abort.withLock { $0 = true }
        }
        let started = ContinuousClock.now
        let isAborted: @Sendable () -> Bool = { abort.withLock { $0 } }
        let result = gate.open(.init(key: "v", number: 11), shouldAbort: isAborted) { _ in
            Self.failure()
        }
        guard case .failed(HTTPSessionInput.averrorExit) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!gate.isEnded, "an abort is no end of the stream")
    }

    @Test("A refused address is renewed once, and asked for again; a second refusal is the server's")
    func renewsAnExpiredSignature() {
        let source = TestLiveSource(base: "https://media.example", waitLimit: .seconds(30))
        let gate = gate(source: source)
        let refusing = OSAllocatedUnfairLock(initialState: true)
        source.onRenew { refusing.withLock { $0 = false } }
        let forbidden = LiveSegmentGate.forbiddenError
        let result = gate.open(.init(key: "v", number: 3), shouldAbort: Self.never) { _ in
            refusing.withLock { $0 } ? Self.failure(forbidden) : Self.input()
        }
        guard case .input = result else {
            Issue.record("\(result)")
            return
        }
        #expect(source.renewals == 1)

        let stubborn = TestLiveSource(base: "https://media.example", waitLimit: .seconds(30))
        let gate2 = self.gate(source: stubborn)
        let again = gate2.open(.init(key: "v", number: 3), shouldAbort: Self.never) { _ in Self.failure(forbidden) }
        guard case .failed(forbidden) = again else {
            Issue.record("\(again)")
            return
        }
        #expect(stubborn.renewals == 1, "once")
    }
}

// MARK: Through the demuxer

/// The segments of the `dashSegments` preset are 0 to 3: the window has 1 and 2 (the head), the manifest goes on to 5,
/// and 3 is held back by the server until a test lets it come; 4 and 5 never exist.
extension LiveSegmentGateTests {
    private static let held: @Sendable (String) -> Bool = { $0 == "video/3" || $0 == "audio/3" }

    private static func source(server: TestHTTPServer, waitLimit: Duration) -> TestLiveSource {
        TestLiveSource(base: String(server.url("").dropLast()), waitLimit: waitLimit)
    }

    private static func demuxer(source: TestLiveSource) throws -> MediaDemuxer {
        var manifest = SegmentedDASHManifest(
            streams: [
                .init(kind: .video, id: "v", container: "mp4", url: "https://\(LiveSegmentGate.host)/video"),
                .init(kind: .audio, id: "a", container: "mp4", url: "https://\(LiveSegmentGate.host)/audio"),
            ], segmentDuration: 1, segmentCount: 5)
        manifest.firstNumber = 1
        manifest.startTime = 1
        let history = LiveHistory(origin: 1, end: 3, headNumber: 2, source: source)
        return try #require(MediaDemuxer(url: MediaURL.inlineDASHManifest(manifest.text()), liveHistory: history))
    }

    /// Lets segment 3 come after `delay`, the head reported as 3 from then on.
    private static func release(_ server: TestHTTPServer, source: TestLiveSource, after delay: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            server.setBehavior(TestHTTPServer.Behavior(), forPaths: held)
            source.report(head: LiveHead(number: 3, startTime: 3))
        }
    }

    private static func pictures(of demuxer: MediaDemuxer) -> Int {
        var count = 0
        while demuxer.nextVideoSample() != nil { count += 1 }
        return count
    }

    /// The pictures of `segments` segments of 25, less the last frame or two. A stream that ended ends in a segment that
    /// fails to open, which FFmpeg's DASH demuxer takes for the end of everything the moment the stream it is reading
    /// (the sound, whose time is behind) asks for it: what the other stream (the picture) still holds of its last
    /// segment, a frame in decode order, is not read. A clean end, by the timeline, drains both.
    private static func expectedPictures(segments: Int) -> ClosedRange<Int> {
        (25 * segments - 2)...(25 * segments)
    }

    @Test(
        "A segment past the head is waited for, and plays on from it with no hole; the end of the stream follows",
        arguments: [404, 204, 503])
    func waitsForTheSegment(status: Int) throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        server.setBehavior(.init(failure: .status(status)), forPaths: Self.held)
        let source = Self.source(server: server, waitLimit: .seconds(1))
        source.report(head: LiveHead(number: 2, startTime: 2))
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        let started = ContinuousClock.now
        Self.release(server, source: source, after: 0.5)

        // Segments 1, 2 and 3, a second each at 25 pictures: none skipped, then 4 never comes.
        let pictures = Self.pictures(of: demuxer)
        #expect(Self.expectedPictures(segments: 3).contains(pictures), "\(pictures) pictures")
        let waited = ContinuousClock.now - started
        #expect(waited > .milliseconds(450), "it did not wait: \(waited)")
        // Segment 3 of the picture or of the sound, whichever the demuxer waited for (it reads one of the two at a time).
        let asked = server.requests.map(\.path).filter { $0 == "video/3" || $0 == "audio/3" }
        #expect(
            asked.count >= 3, "segment 3 was asked for \(asked.count) time(s): one wait, a retry, the segment of each")
        // The head did not move in the limit that followed (4 does not exist): the stream ended, and the window says so.
        let window = try #require(demuxer.liveWindow)
        #expect(window.hasEnded)
        // The start has slid with the clock since the window was told, a few seconds, and never past the end.
        #expect((0...20).contains(window.start), "\(window)")
        // The segments 4 and 5 are asked for once or twice before the head says it ended, and not after.
        let past = server.requests.map(\.path).filter { $0.hasSuffix("/5") }
        #expect(past.isEmpty, "the end is not walked over: \(past)")
    }

    @Test("A stream that stops ends the window when its head does not move; a seek back plays what there is")
    func endsWhenTheSourceStops() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        server.setBehavior(.init(failure: .status(404)), forPaths: Self.held)
        let source = Self.source(server: server, waitLimit: .milliseconds(500))
        source.report(head: LiveHead(number: 2, startTime: 2))
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        let started = ContinuousClock.now
        let pictures = Self.pictures(of: demuxer)
        #expect(Self.expectedPictures(segments: 2).contains(pictures), "\(pictures) pictures")
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(450) && elapsed < .seconds(5), "\(elapsed)")
        #expect(demuxer.liveWindow?.hasEnded == true)
        #expect(source.headsAsked >= 1)

        // A recording now: the window stands, and what it holds plays again.
        demuxer.seek(to: 0.5, exact: false)
        let first = try #require(demuxer.nextVideoSample())
        #expect((-0.1...0.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))))
        let replayed = Self.pictures(of: demuxer) + 1
        #expect(Self.expectedPictures(segments: 2).contains(replayed), "\(replayed) pictures after the seek")
    }

    @Test("A segment the server reports but is slow to serve is waited for: the stream is alive, not ended")
    func waitsForASlowSegment() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        server.setBehavior(.init(failure: .status(404)), forPaths: Self.held)
        let source = Self.source(server: server, waitLimit: .milliseconds(400))
        // The head says 3 is there from the first ask; the server serves it only at 1.1 s, with the head standing still for
        // longer than the limit. The stream is on the air (the page says so): it is waited for.
        source.report(head: LiveHead(number: 3, startTime: 3))
        source.say(ended: false)
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        Self.release(server, source: source, after: 1.1)
        // The broadcast ends after it (the page says so from 1.2 s on): without that the wait for segment 4 has no limit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { source.say(ended: true) }
        let pictures = Self.pictures(of: demuxer)
        #expect(Self.expectedPictures(segments: 3).contains(pictures), "\(pictures) pictures")
        #expect(source.headsAsked >= 2, "asked \(source.headsAsked) time(s)")
    }

    @Test("A seek made while the read waits for a segment is not held up by it", needsPatch)
    func seeksWhileWaiting() throws {
        guard let server = try InlineDASHTests.server() else { return }
        defer { server.stop() }
        server.setBehavior(.init(failure: .status(404)), forPaths: Self.held)
        // A minute of waiting: only the seek can end it.
        let source = Self.source(server: server, waitLimit: .seconds(60))
        source.report(head: LiveHead(number: 2, startTime: 2))
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        let deadline = ContinuousClock.now + .seconds(10)
        let reached = { server.requests.map(\.path).contains { $0 == "video/3" || $0 == "audio/3" } }
        while !reached(), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try #require(reached(), "the read never reached segment 3: \(server.requests.map(\.path))")
        Thread.sleep(forTimeInterval: 0.3)

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
        server.setBehavior(.init(failure: .status(404)), forPaths: Self.held)
        try Self.redirect(["video/1", "video/2", "audio/1", "audio/2"], on: server)
        let source = Self.source(server: server, waitLimit: .milliseconds(400))
        source.report(head: LiveHead(number: 2, startTime: 2))
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        let pictures = Self.pictures(of: demuxer)
        #expect(Self.expectedPictures(segments: 2).contains(pictures), "\(pictures) pictures")
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
        source.onRenew { server.setBehavior(TestHTTPServer.Behavior(), forPaths: { $0.hasPrefix("mirror/") }) }
        let demuxer = try Self.demuxer(source: source)
        demuxer.startReadAhead()
        let first = try #require(demuxer.nextVideoSample())
        #expect((-0.1...0.1).contains(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first))))
        #expect(source.renewals >= 1, "renewed \(source.renewals) time(s)")
    }
}

private let needsPatch: ConditionTrait = .enabled(
    if: hasDashInterruptPatch, "needs the bundled FFmpeg with the DASH interrupt patch")

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
        server.setBehavior(.init(failure: .status(404)), forPaths: { $0 == "video/3" || $0 == "audio/3" })
        let source = TestLiveSource(base: String(server.url("").dropLast()), waitLimit: .milliseconds(600))
        source.report(head: LiveHead(number: 2, startTime: 2))
        var manifest = SegmentedDASHManifest(
            streams: [
                .init(kind: .video, id: "v", container: "mp4", url: "https://\(LiveSegmentGate.host)/video"),
                .init(kind: .audio, id: "a", container: "mp4", url: "https://\(LiveSegmentGate.host)/audio"),
            ], segmentDuration: 1, segmentCount: 5)
        manifest.firstNumber = 1
        manifest.startTime = 1
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.mediaResolver = LiveHistoryEngineTests.Resolver(
            ResolvedMedia(
                path: MediaURL.inlineDASHManifest(manifest.text()), historyKey: "youtube:live",
                liveHistory: LiveHistory(origin: 1, end: 3, headNumber: 2, source: source)))

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
