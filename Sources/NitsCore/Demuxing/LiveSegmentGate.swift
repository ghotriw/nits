import Foundation
import os

/// Where a live stream's newest segment is: its number and its start, in seconds of the stream's time.
public struct LiveHead: Sendable, Equatable {
    public var number: Int
    public var startTime: Double

    public init(number: Int, startTime: Double) {
        self.number = number
        self.startTime = startTime
    }
}

/// What the server said when asked where the stream's head is: a refusal that tells no head (a 404 or a 403 without the
/// headers) is still an answer, the server being there, where no answer at all is the network being down.
public enum LiveHeadAnswer: Sendable, Equatable {
    case head(LiveHead)
    /// The server answered, and the answer holds no head.
    case answeredWithoutHead
    /// No answer: the request failed, or was given up.
    case noAnswer
}

/// What a live stream given as numbered segments (`LiveHistory`) needs of its resolver after it was resolved. The
/// manifest names a segment by a key and a number only (`LiveSegmentGate.address(key:number:)`): the signed address, which
/// expires in hours, is the source's to give, and to renew, so that a stream watched at its edge never has to be reopened.
///
/// Called on the demuxer's read thread (`LiveSegmentGate`), which blocks in them as it does in any read: they may wait
/// for the network, and give up when `shouldAbort` says a seek or a close wants the thread.
public protocol LiveSegmentSource: AnyObject, Sendable {
    /// The address of segment `number` of the stream the manifest calls `key`, signed as it is now.
    func url(for key: String, number: Int) -> URL?

    /// Asks the server where the stream's head is. Not on the hot path: while a segment past the head is waited for,
    /// every `headPollInterval`.
    func head(shouldAbort: () -> Bool) -> LiveHeadAnswer

    /// Makes the signature valid again after the server refused an address (403: it expired before it was renewed);
    /// false when it could not.
    func renewSignature(shouldAbort: () -> Bool) -> Bool

    /// How long the head may stand still while a segment past it is waited for, before the source is asked whether the
    /// stream is over (`hasEnded`). A broadcaster's hiccup lasts seconds; a minute is worth asking about.
    var segmentWaitLimit: Duration { get }

    /// How often the head is asked while a segment past it is waited for: it tells that the stream is alive, and when the
    /// server has the segment waited for.
    var headPollInterval: Duration { get }

    /// How long a segment that the head says is there, and that the server does not give, is waited for before it is taken
    /// for lost and left to the demuxer to skip: a few lengths of a segment, not a minute of a picture that stands.
    var reportedSegmentGrace: Duration { get }

    /// Whether the stream is over, asked once its head stood still for `segmentWaitLimit`; the decision is the source's,
    /// which knows (YouTube's says it of the page, as the player does): `true`, it is, and the window becomes a recording;
    /// `false`, it is still on the air (the source is silent, an encoder restarts), and the wait goes on with no limit;
    /// `nil`, it could not be told: with the server not answering (no network) the wait goes on, with no limit; with the
    /// server answering and its head standing still, asked again a few times, then it is the end (a page that no longer
    /// shows the stream is a stream that is gone).
    /// The default is for a source that cannot tell: a head that stood still that long is the end.
    func hasEnded(shouldAbort: () -> Bool) -> Bool?
}

extension LiveSegmentSource {
    public var segmentWaitLimit: Duration { .seconds(60) }
    public var headPollInterval: Duration { .seconds(5) }
    public var reportedSegmentGrace: Duration { .seconds(15) }
    public func hasEnded(shouldAbort: () -> Bool) -> Bool? { true }
}

/// The reads of a live stream's segments, between FFmpeg's DASH demuxer and the network (`FFmpegIOByteCounter`'s
/// `io_open`): a segment is asked for at the source's address, and one past the head, which does not exist yet, is waited
/// for.
///
/// A segment past the head is answered in different ways (YouTube holds the request of the next two or three until they
/// exist, and answers 204 after 7.5 s for those beyond, or 404, or fails to answer at all), and FFmpeg's DASH demuxer takes
/// any failure for a segment to skip: it would play on over a hole in time (the next segment keeps its own timestamps, so the time does not shift; the other stream goes on). So here a failure of a
/// segment past the head is retried while the stream is alive. The head is asked for every `headPollInterval`: a segment
/// the server says is there but does not give is left to the demuxer to skip after `reportedSegmentGrace` (a hole in the
/// time of that stream, the other going on, and what follows at its own time: segments carry their timestamps); and when
/// the head stood still for `segmentWaitLimit` the source says whether the stream is over (`hasEnded`): if it is, every
/// request past its last segment fails at once, which the demuxer takes for the end of its input, and the window is a
/// recording; if it is not, the wait goes on, with no limit. A failure of a segment up to the head is a failure.
///
/// "The head" that tells the two apart is the newest segment known to have been delivered (the resolver's, and each one
/// read since), not the one the server last reported: a CDN may report a segment before it serves it, and that one is
/// still waited for, a little, not skipped at once. The server's report shows that the stream is alive.
final class LiveSegmentGate: Sendable {
    /// The host of the addresses the manifest names, which no DNS knows: the gate is the only one that opens them.
    static let host = "live.nits.invalid"
    /// A segment lasts about this long (YouTube's): the end of one past the last whose start is known.
    static let nominalSegmentDuration = LiveHistory.nominalSegmentDuration

    struct Request: Equatable {
        var key: String
        var number: Int
    }

    enum Change: Equatable {
        /// The head moved to this (asked for, after a wait).
        case headAdvanced(LiveHead)
        /// The stream ended after this segment, which lasts to this time.
        case ended(lastNumber: Int, endTime: Double)
    }

    private struct State {
        var head: LiveHead
        var isEnded = false
    }

    private let source: any LiveSegmentSource
    private let state: OSAllocatedUnfairLock<State>
    private let onChange: @Sendable (Change) -> Void
    /// How often a retry is made; a seek or a close is let through within this.
    private let pollInterval: Duration

    /// - Parameters:
    ///   - head: What the resolver knew of the head when it made the manifest.
    ///   - onChange: Told of a head found further on and of the end of the stream, from the read thread.
    init(
        source: any LiveSegmentSource, head: LiveHead, pollInterval: Duration = .milliseconds(250),
        onChange: @escaping @Sendable (Change) -> Void
    ) {
        self.source = source
        self.state = OSAllocatedUnfairLock(initialState: State(head: head))
        self.pollInterval = pollInterval
        self.onChange = onChange
    }

    /// The address the manifest names a segment by.
    static func address(key: String, number: Int, template: Bool = false) -> String {
        "https://\(host)/\(key)?sq=\(template ? "$Number$" : String(number))"
    }

    /// The segment `url` names, when it is one of the gate's addresses.
    func request(for url: String) -> Request? {
        guard let components = URLComponents(string: url), components.host == Self.host,
            let number = components.queryItems?.first(where: { $0.name == "sq" })?.value.flatMap({ Int($0) })
        else { return nil }
        let key = String(components.path.drop { $0 == "/" })
        return key.isEmpty ? nil : Request(key: key, number: number)
    }

    /// The newest segment known to be there, from the resolver and from the segments read since.
    var head: LiveHead { state.withLock { $0.head } }
    /// How many times `hasEnded` may fail to tell, with the server answering and its head standing still, before that is
    /// taken for the end of the stream.
    static let unknownRounds = 3
    var isEnded: Bool { state.withLock { $0.isEnded } }

    /// Opens `request` through `attempt`, which asks the server at the address it is given. `shouldAbort` is the
    /// demuxer's interrupt (a seek that wants the input, a close): the wait gives way to it at once.
    func open(
        _ request: Request, shouldAbort: () -> Bool,
        attempt: (URL) -> HTTPSessionTransport.Opened
    ) -> HTTPSessionTransport.Opened {
        let began = ContinuousClock.now
        var lastPoll = began
        var lastMovement = began
        var headSeen = state.withLock { $0.head.number }
        var reportedSince: ContinuousClock.Instant?
        // Whether the server answered the last ask for the head: it is reachable, or it may be the network that is down.
        var isServerAnswering = false
        var unknownEnds = 0
        var hasRenewed = false
        while true {
            if shouldAbort() { return .failed(Self.exitError) }
            // Past the end of a stream that ended there is nothing to ask for.
            let current = state.withLock { $0 }
            if current.isEnded, request.number > current.head.number { return .failed(Self.notFoundError) }
            guard let address = source.url(for: request.key, number: request.number) else {
                return .failed(Self.notFoundError)
            }
            let opened = attempt(address)
            if case .input = opened {
                noteDelivered(request.number)
                return opened
            }
            // Refused: the signature expired before it was renewed. Once; a second refusal is the server's.
            if case .failed(let code) = opened, code == Self.forbiddenError, !hasRenewed {
                hasRenewed = true
                if source.renewSignature(shouldAbort: shouldAbort) { continue }
                return opened
            }
            let known = state.withLock { $0 }
            guard request.number > known.head.number else { return opened }
            // Past the head: it is not there yet, or never will be.
            if known.isEnded { return .failed(Self.notFoundError) }
            let now = ContinuousClock.now
            if now - lastPoll >= source.headPollInterval {
                lastPoll = now
                let answer = source.head(shouldAbort: shouldAbort)
                if shouldAbort() { return .failed(Self.exitError) }
                // Any answer is the server being there; only no answer at all is the network being down.
                isServerAnswering = answer != .noAnswer
                if case .head(let found) = answer {
                    if found.number > headSeen {
                        headSeen = found.number
                        lastMovement = now
                        onChange(.headAdvanced(found))
                    }
                    // The server has it, and does not give it: a little longer, then the demuxer's to skip.
                    if found.number >= request.number {
                        let since = reportedSince ?? now
                        reportedSince = since
                        if now - since >= source.reportedSegmentGrace { return opened }
                    }
                }
            }
            if now - lastMovement >= source.segmentWaitLimit {
                let over = source.hasEnded(shouldAbort: shouldAbort)
                if shouldAbort() { return .failed(Self.exitError) }
                switch over {
                case true?:
                    end(after: known.head)
                    return .failed(Self.notFoundError)
                case false?:
                    // Still on the air, and silent: waited for as long as it takes, asking again after another limit.
                    lastMovement = .now
                case nil:
                    lastMovement = .now
                    // The server answers and its head stands still, and the source cannot say (yt-dlp fails on a page whose
                    // stream is gone: "recording is not available"): after a few asks, that is the end. If the server does
                    // not answer either, it is the network: waited for as long as it takes, never a hole in the time.
                    if isServerAnswering {
                        unknownEnds += 1
                        if unknownEnds > Self.unknownRounds {
                            end(after: known.head)
                            return .failed(Self.notFoundError)
                        }
                    }
                }
            }
            Self.sleep(pollInterval, unless: shouldAbort)
        }
    }

    private func noteDelivered(_ number: Int) {
        state.withLock { state in
            if number > state.head.number {
                // Its start is the head's plus the segments between (nominal ones): only the end of the window needs it.
                let start = state.head.startTime + Double(number - state.head.number) * Self.nominalSegmentDuration
                state.head = LiveHead(number: number, startTime: start)
            }
        }
    }

    private func end(after head: LiveHead) {
        let didEnd = state.withLock { state -> LiveHead? in
            guard !state.isEnded else { return nil }
            state.isEnded = true
            return state.head
        }
        guard let last = didEnd else { return }
        onChange(.ended(lastNumber: last.number, endTime: last.startTime + Self.nominalSegmentDuration))
    }

    /// Sleeps `duration`, in steps that let `shouldAbort` end it early. A thread of FFmpeg's read, which blocks.
    private static func sleep(_ duration: Duration, unless shouldAbort: () -> Bool) {
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end, !shouldAbort() {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// FFmpeg's errors: the server's 403 and 404 (`AVERROR_HTTP_FORBIDDEN`, `AVERROR_HTTP_NOT_FOUND`), and `AVERROR_EXIT`.
    static let forbiddenError = HTTPSessionInput.ffErrorTag(0xF8, "4", "0", "3")
    static let notFoundError = HTTPSessionInput.ffErrorTag(0xF8, "4", "0", "4")
    static let exitError = HTTPSessionInput.averrorExit
}
