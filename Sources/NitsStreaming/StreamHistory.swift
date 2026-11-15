import Foundation

/// Where a live stream's newest segment is: its number and its start, in seconds of the stream's time.
package struct StreamHead: Sendable, Equatable {
    package var number: Int
    package var startTime: Double

    package init(number: Int, startTime: Double) {
        self.number = number
        self.startTime = startTime
    }
}

/// What the server said when asked where the stream's head is: a refusal that tells no head (a 404 or a 403 without the
/// headers) is still an answer, the server being there, where no answer at all is the network being down.
package enum StreamHeadAnswer: Sendable, Equatable {
    case head(StreamHead)
    /// The server answered, and the answer holds no head.
    case answeredWithoutHead
    /// No answer: the request failed, or was given up.
    case noAnswer
}

/// What a live stream given as numbered segments (`StreamHistory`) needs of its resolver after it was resolved. The
/// manifest names a segment by a key and a number only (`StreamHistory.streamAddress`, `segment(named:)`): the signed
/// address, which expires in hours, is the source's to give, and to renew, so that a stream watched at its edge never has
/// to be reopened.
///
/// Called on the thread of the demuxer's read (the client's playlist reloads and segment requests), which blocks in
/// them as it does in any read: they may wait for the network, and give up when `shouldAbort` says a seek or a close
/// wants the thread.
package protocol StreamHistorySource: AnyObject, Sendable {
    /// The address of segment `number` of the stream the manifest calls `key`, signed as it is now.
    func url(for key: String, number: Int) -> URL?

    /// Asks the server where the stream's head is. Not on the hot path: a live playlist's reload asks, no more often
    /// than `headPollInterval`.
    func head(shouldAbort: () -> Bool) -> StreamHeadAnswer

    /// Makes the signature valid again after the server refused an address (403: it expired before it was renewed);
    /// false when it could not.
    func renewSignature(shouldAbort: () -> Bool) -> Bool

    /// How long the head may stand still before the source is asked whether the stream is over (`hasEnded`).
    var segmentWaitLimit: Duration { get }

    /// How often the head is asked: it tells that the stream is alive, and what the playlist lists.
    var headPollInterval: Duration { get }

    /// Whether the stream is over, asked once its head stood still for `segmentWaitLimit`: `true`, it is, and the window
    /// becomes a recording; `false`, it is still on the air, and the wait goes on with no limit; `nil`, it could not be
    /// told (see `LiveSegmentSource.hasEnded`, which NitsCore passes through).
    func hasEnded(shouldAbort: () -> Bool) -> Bool?
}

/// A live stream given as the segments of its past, as the client reads it (NitsCore's `LiveHistory` is what a resolver
/// tells; this is its core): the manifest lists the segments up to the head, and `source` tells the rest.
package struct StreamHistory: Sendable {
    /// The number of the newest segment when the manifest was made.
    package var headNumber: Int
    /// What the manifest's segments are asked for through, when the manifest goes on past the head; nil: it ends there.
    package var source: (any StreamHistorySource)?

    package init(headNumber: Int, source: (any StreamHistorySource)?) {
        self.headNumber = headNumber
        self.source = source
    }

    /// The address of segment `number` of the stream at `base` (YouTube's `sq=N`); `number` may be a manifest's
    /// `$Number$`.
    package static func segmentAddress(_ base: String, number: String) -> String {
        base + (base.contains("?") ? "&" : "?") + "sq=" + number
    }

    /// `segmentAddress` as a URL; nil when `base` is not one.
    package static func segmentURL(_ base: String, number: Int) -> URL? {
        URL(string: segmentAddress(base, number: String(number)))
    }

    /// The host of the addresses the manifest names, which no DNS knows: the client asks the source for the address of
    /// each (`HLSPlaylistSource.address(of:)`).
    package static let host = "live.nits.invalid"

    /// What a manifest names the stream `key` by: the address its segments are asked for (with `sq=N`) through the
    /// source (`StreamHistorySource.url(for:number:)`), not an address that exists.
    package static func streamAddress(_ key: String) -> String {
        "https://\(host)/\(key)"
    }

    /// The stream and the number of the segment `url` names, when it is one of the manifest's addresses.
    package static func segment(named url: URL) -> (key: String, number: Int)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host == host,
            let number = components.queryItems?.first(where: { $0.name == "sq" })?.value.flatMap({ Int($0) })
        else { return nil }
        let key = String(components.path.drop { $0 == "/" })
        return key.isEmpty ? nil : (key, number)
    }
}

extension StreamHistorySource {
    package var segmentWaitLimit: Duration { .seconds(60) }
    package var headPollInterval: Duration { .seconds(5) }
    package func hasEnded(shouldAbort: () -> Bool) -> Bool? { true }
}
