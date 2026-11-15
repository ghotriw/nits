import Foundation
internal import NitsStreaming

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
/// manifest names a segment by a key and a number only (`LiveHistory.streamAddress`, `LiveHistory.segment(named:)`):
/// the signed address, which expires in hours, is the source's to give, and to renew, so that a stream watched at its edge never has to be reopened.
///
/// Called on the thread of the demuxer's read (the client's playlist reloads and segment requests), which blocks in
/// them as it does in any read: they may wait for the network, and give up when `shouldAbort` says a seek or a close
/// wants the thread.
public protocol LiveSegmentSource: AnyObject, Sendable {
    /// The address of segment `number` of the stream the manifest calls `key`, signed as it is now.
    func url(for key: String, number: Int) -> URL?

    /// Asks the server where the stream's head is. Not on the hot path: a live playlist's reload asks, no more often
    /// than `headPollInterval`.
    func head(shouldAbort: () -> Bool) -> LiveHeadAnswer

    /// Makes the signature valid again after the server refused an address (403: it expired before it was renewed);
    /// false when it could not.
    func renewSignature(shouldAbort: () -> Bool) -> Bool

    /// How long the head may stand still before the source is asked whether the stream is over (`hasEnded`). A
    /// broadcaster's hiccup lasts seconds; a minute is worth asking about.
    var segmentWaitLimit: Duration { get }

    /// How often the head is asked: it tells that the stream is alive, and what the playlist lists.
    var headPollInterval: Duration { get }

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
    public func hasEnded(shouldAbort: () -> Bool) -> Bool? { true }
}

/// A resolver's `LiveSegmentSource` as the streaming client's source of a history (`StreamHistorySource`).
final class LiveSegmentSourceBridge: StreamHistorySource {
    private let source: any LiveSegmentSource

    init(_ source: any LiveSegmentSource) {
        self.source = source
    }

    func url(for key: String, number: Int) -> URL? {
        source.url(for: key, number: number)
    }

    func head(shouldAbort: () -> Bool) -> StreamHeadAnswer {
        switch source.head(shouldAbort: shouldAbort) {
        case .head(let head): .head(StreamHead(number: head.number, startTime: head.startTime))
        case .answeredWithoutHead: .answeredWithoutHead
        case .noAnswer: .noAnswer
        }
    }

    func renewSignature(shouldAbort: () -> Bool) -> Bool {
        source.renewSignature(shouldAbort: shouldAbort)
    }

    var segmentWaitLimit: Duration { source.segmentWaitLimit }
    var headPollInterval: Duration { source.headPollInterval }

    func hasEnded(shouldAbort: () -> Bool) -> Bool? {
        source.hasEnded(shouldAbort: shouldAbort)
    }
}
