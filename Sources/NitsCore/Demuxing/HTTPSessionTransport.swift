import CFFmpeg
import Foundation
import os

/// Reads the HTTP(S) inputs of Nits' HLS client (and of a DASH demuxer) through `URLSession`, in place of FFmpeg's HTTP protocol (`io_open`,
/// `FFmpegIOByteCounter`). FFmpeg downloads a segment only as fast as its reads take the bytes, inside
/// `av_read_frame`, so what the network does could only be guessed from how long reads took. Here each request is a
/// task of its own: its answer, which `io_open` waits for (the request's latency), and its transfer, which goes on
/// while FFmpeg reads at its own pace, are told apart, and `meter` takes each transfer for a sample, as VLC,
/// hls.js and ExoPlayer measure their segments' downloads (`.ref`). The session keeps the connections open
/// (HTTP/1.1 keep-alive, HTTP/2), where FFmpeg's own only keeps one it reads itself: with these inputs it opens every
/// request through `io_open` (`is_native_http` in its `hls.c`).
///
/// What FFmpeg's HTTP did for the inputs it opened, the transport does for these: the source's headers (and FFmpeg's
/// user agent without one), the cookies FFmpeg passes on from the answers of the inputs it opened itself (its
/// `cookies` option: the master's), no compressed bodies (`Accept-Encoding: identity`, as FFmpeg asks: URLSession
/// hands a compressed body on decompressed, which would count bytes the link never carried in the samples, and byte
/// ranges are of the file, not of a compressed stream), and a body cut short asked for again from where it stopped
/// (`HTTPSessionInput`, as FFmpeg's `reconnect`).
///
/// What isn't served here FFmpeg opens itself: a URL that isn't HTTP(S) (an encrypted segment's `crypto+`), an answer
/// redirected (FFmpeg resolves a playlist's URIs against where it was served from, which only its own inputs tell),
/// and a byte range the server answers whole.
final class HTTPSessionTransport: Sendable {
    enum Opened {
        case input(HTTPSessionInput)
        /// FFmpeg's error for the request: the server's answer, or `AVERROR_EXIT` for an interrupted open.
        case failed(Int32)
        /// Not served here: FFmpeg opens it.
        case notServed
    }

    let meter = NetworkTransferMeter()
    /// What the inputs opened while a DASH demuxer opens are held to, until `endOpening`.
    private let openingLimit = HTTPSessionInput.OpeningLimit()
    let holder: HTTPSessionHolder
    private let headers: [String: String]
    /// Where the cookies FFmpeg passes on came from, when the master's location isn't told: the source.
    private let cookieOrigin: URL?
    /// FFmpeg's `cookies` option last stored in the session's cookies.
    private let storedCookies = OSAllocatedUnfairLock<String?>(initialState: nil)
    let shouldAbort: @Sendable () -> Bool

    /// `headers` are the source's (the user agent among them), sent with every request; `shouldAbort` interrupts the
    /// waits for an answer and for data, as FFmpeg's interrupt callback does its own I/O.
    init(source: String, headers: [String: String], shouldAbort: @escaping @Sendable () -> Bool) {
        var headers = MediaURL.sanitizedHeaders(headers)
        // FFmpeg's own, without one of the source's: the server sees the client the inputs FFmpeg opens show.
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            let version = avformat_version()
            headers["User-Agent"] = "Lavf/\(version >> 16).\(version >> 8 & 0xFF).\(version & 0xFF)"
        }
        headers = headers.filter { $0.key.lowercased() != "accept-encoding" }
        headers["Accept-Encoding"] = "identity"
        self.headers = headers
        self.shouldAbort = shouldAbort
        cookieOrigin = MediaURL.isNetworkURL(source) ? URL(string: source) : nil
        let configuration = URLSessionConfiguration.ephemeral
        // FFmpeg's `rw_timeout` (`MediaURL.applyNetworkOptions`): seconds without data.
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .always
        // The delegates' calls, off the cooperative pool: FFmpeg's thread waits on them with its own.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        holder = HTTPSessionHolder(configuration: configuration, queue: queue)
    }

    deinit { holder.invalidate() }

    static func serves(_ url: String) -> Bool {
        url.hasPrefix("http://") || url.hasPrefix("https://")
    }

    /// Bits a second the inputs held while opening have brought (`OpeningLimit.throughput`).
    var openingThroughput: Double? { openingLimit.throughput }
    /// The opening's rate at the points it could be read at, for the measurement (`OpeningLimit.rateReport`).
    var openingRateReport: String { openingLimit.rateReport }

    /// Bytes of the opening's transfers left out of the link's rate at least (`skipSlowStart`).
    static let slowStartBytes = 128 << 10
    /// How long `skipSlowStart` waits for the round trip of a request read through.
    static let metricsWait: Duration = .milliseconds(100)

    /// Leaves the start of the opening's transfers out of the link's rate (`OpeningLimit.linkRate`): TCP's slow start,
    /// in which a fresh connection carries a window a round trip whatever the link (at 180 ms of round trip a single
    /// probe brought its first 256 KB at 3.4–5.2 Mbit/s on a fat link, 2.6–2.8 by its first half second). As many bytes
    /// as a link at `limit` carries in two round trips, `slowStartBytes` at least; the round trip is one measured to
    /// `host` (`NetworkTransferMeter.roundTrip(host:)`: the master's and playlists' requests set up its connections),
    /// none for another host. Before the opening's transfers start. Returns the round trip it took, for the log.
    ///
    /// A request's metrics may come after its body was read through: those still to come for `host`
    /// (`NetworkTransferMeter.awaitsMetrics(host:)`) are waited for, `metricsWait` at most, in steps of 10 ms.
    func skipSlowStart(forSegmentsOn host: String?, limit: Double) -> Double? {
        var roundTrip = host.flatMap { meter.roundTrip(host: $0) }
        if let host, roundTrip == nil {
            let deadline = ContinuousClock.now + Self.metricsWait
            let wake = DispatchSemaphore(value: 0)
            while roundTrip == nil, meter.awaitsMetrics(host: host), ContinuousClock.now < deadline, !shouldAbort() {
                _ = wake.wait(timeout: .now() + .milliseconds(10))
                roundTrip = meter.roundTrip(host: host)
            }
        }
        let bytes = max(Self.slowStartBytes, Int((limit / 8 * (roundTrip ?? 0) * 2).rounded()))
        openingLimit.skip(bytes)
        return roundTrip
    }

    /// The link's rate as the opening's transfers tell it against `limit` (`OpeningLimit.linkRate`), waited for while
    /// they go on (a start's download, `HTTPSessionInput.Opening.start`, goes on past the probes): at most until a link
    /// at `limit` would have carried what it takes, about a second at 3 Mbit/s. When the transfers ended first, the rate of
    /// what came (`OpeningLimit.rateOfWhatCame`: nil for less than half a second of transfer, a link that brought all
    /// they asked for at once); nil for an abort. Blocks the opening's thread, as its
    /// probes do (`shouldAbort`, checked every 20 ms).
    func waitForOpeningRate(limit: Double) -> Double? {
        let wake = DispatchSemaphore(value: 0)
        while true {
            if let rate = openingLimit.linkRate(limit: limit) { return rate }
            if shouldAbort() { return nil }
            if !openingLimit.isTransferring { return openingLimit.rateOfWhatCame }
            _ = wake.wait(timeout: .now() + .milliseconds(20))
        }
    }

    /// The demuxer has opened: the inputs opened meanwhile are held no longer (see `HTTPSessionInput.OpeningLimit`).
    func endOpening() {
        openingLimit.lift()
    }

    /// Asks for `url` from `offset` (to `end`, a byte range's, when given) and waits for the answer. `cookies` is
    /// FFmpeg's option of that name: `Set-Cookie` values, a line each, from the answer of `cookieOrigin` (where the
    /// master was served from, after its redirects). `opening`: a request of the demuxer's opening, and how it is read
    /// (`HTTPSessionInput.Opening`). `abort` interrupts this request too, besides `shouldAbort` (a probe of the opening
    /// that lost its race, `HLSInput`). `onProgress` is told how far the request has got while it waits for its answer
    /// too (a server that stalls before its headers), and for its bytes after.
    func open(
        _ url: String, offset: Int64, end: Int64?, cookies: String?, cookieOrigin: String?,
        opening: HTTPSessionInput.Opening? = nil, followsRedirects: Bool = false, abort: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (HTTPSessionInput.Progress) -> Void)? = nil
    ) -> Opened {
        guard let requestURL = URL(string: url) else { return .notServed }
        if let cookies {
            store(cookies, from: cookieOrigin.flatMap(URL.init(string:)) ?? self.cookieOrigin ?? requestURL)
        }
        var request = URLRequest(url: requestURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let interrupts: @Sendable () -> Bool
        if let abort {
            let shouldAbort = shouldAbort
            interrupts = { shouldAbort() || abort() }
        } else {
            interrupts = shouldAbort
        }
        let input = HTTPSessionInput(
            holder: holder, request: request, offset: offset, end: end, meter: meter,
            openingLimit: opening == nil ? nil : openingLimit, opening: opening ?? .held,
            followsRedirects: followsRedirects, shouldAbort: interrupts)
        input.onProgress = onProgress
        input.start()
        let begin = ContinuousClock.now
        let opened = input.waitForAnswer()
        if case .input = opened { meter.addAnswer(asked: begin, answered: ContinuousClock.now) }
        if case .input = opened, let length = input.answeredLength, length < Self.oneTimeRequestBytes {
            meter.addOneTimeWait((ContinuousClock.now - begin) / .seconds(1))
        }
        return opened
    }

    /// Bodies smaller than this are no media's (an init section, a key, a playlist reloaded): the wait for their
    /// answer is paid once (at the start, a switch), not by every second of media, and counts in no latency share;
    /// their transfer, a few round trips of TCP's slow start, is no sample of the link. Apple's AV1 example on a cold
    /// CDN cache, at 184 ms of round trip, waited 0.76 s for its two init sections of 665 and 788 bytes among the 2.5 s
    /// of the first 6 s of media: counted, the share came out at 0.42 s a second where it then held at 0.29, and
    /// brought 4K down a step 4 s in.
    static let oneTimeRequestBytes: Int64 = 16 << 10

    /// The cookies the session holds, from `Set-Cookie` answers and FFmpeg's option.
    var cookies: [HTTPCookie] { holder.cookieStorage?.cookies ?? [] }

    /// Takes over cookies another session holds (a read of the same stream on a session of its own).
    func adopt(_ cookies: [HTTPCookie]) {
        guard let storage = holder.cookieStorage else { return }
        for cookie in cookies { storage.setCookie(cookie) }
    }

    /// The cookies of `cookies` (FFmpeg's option, as it was last) into the session's, which sends them where they
    /// apply. Without a domain of their own they are `origin`'s.
    private func store(_ cookies: String, from origin: URL) {
        let isNew = storedCookies.withLock { stored in
            defer { stored = cookies }
            return stored != cookies
        }
        guard isNew, let storage = holder.cookieStorage else { return }
        for line in cookies.split(whereSeparator: \.isNewline) {
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": String(line)], for: origin)
            storage.setCookies(parsed, for: origin, mainDocumentURL: nil)
        }
    }
}

/// The transfers `HTTPSessionTransport`'s requests made, for `MediaDemuxer.noteRead`: each from its answer to its last
/// byte, but while held back for FFmpeg to catch up (`HTTPSessionInput`). A sample each, as VLC, hls.js and ExoPlayer
/// take theirs: measured together, the link's busy time over every transfer, a window of an audio segment alone (half
/// a megabyte on a connection idle since its last, which TCP starts slowly again) measured 24 Mbit/s of 300.
///
/// Requests stay one at a time (`HLSSegmentLoader`). Asking for the next segment
/// while one is read hides its answer's wait, but over HTTP/1.1 the server sends the body with the answer: side by
/// side, the one read, needed first, came in at half the rate (a live stream at 1.5 Mbit/s: the read-ahead empty for
/// 7 s), and a task suspended once answered took its body all the same, into the socket's buffer.
final class NetworkTransferMeter: Sendable {
    struct Transfer: Sendable {
        let bytes: Int
        let seconds: Double
        /// Bytes every transfer received during this one's `seconds`, its own included: the requests of a switch's old
        /// and new variant, side by side, share the link, and the rate of the link is what all of them carried, however
        /// they divided it. Never below `bytes`.
        let linkBytes: Int
        /// The shortest round trip measured to the request's host (`roundTrip(host:)`), when one was: how long TCP's slow
        /// start may hold the transfer back (`AdaptiveBitrateLogic.addSample`).
        let roundTrip: Double?

        init(bytes: Int, seconds: Double, linkBytes: Int? = nil, roundTrip: Double? = nil) {
            self.bytes = bytes
            self.seconds = seconds
            self.linkBytes = max(linkBytes ?? bytes, bytes)
            self.roundTrip = roundTrip
        }
    }

    private struct State {
        var transfers: [Transfer] = []
        var oneTimeWaits = 0.0
        /// Seconds every request waited for its answer, and the latest answered (`HLSInput` reads them as FFmpeg's
        /// `io_open` times are read: `MediaDemuxer.noteRead`).
        var answerSeconds = 0.0
        var lastAnswer:
            (asked: ContinuousClock.Instant, answered: ContinuousClock.Instant, total: Int64, seconds: Double)?
        /// Body bytes received by every transfer so far.
        var receivedBytes = 0
        /// The shortest round trip to each host its connections were set up in (`HTTPSessionInput.roundTrip(of:)`).
        var roundTrips: [String: Double] = [:]
        /// Tasks to each host whose metrics have not come yet.
        var awaitedMetrics: [String: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A connection to `host` was set up in a round trip of `seconds`.
    func noteRoundTrip(_ seconds: Double, host: String) {
        guard seconds > 0 else { return }
        state.withLock { state in state.roundTrips[host] = min(state.roundTrips[host] ?? .infinity, seconds) }
    }

    /// The shortest round trip a connection to `host` was set up in, if one was.
    func roundTrip(host: String) -> Double? {
        state.withLock { $0.roundTrips[host] }
    }

    /// A task to `host` started: its metrics are to come (`metricsCame`).
    func awaitMetrics(host: String) {
        state.withLock { $0.awaitedMetrics[host, default: 0] += 1 }
    }

    /// The metrics of a task to `host` came (`noteRoundTrip` before, when they tell one).
    func metricsCame(host: String) {
        state.withLock { state in state.awaitedMetrics[host] = max((state.awaitedMetrics[host] ?? 0) - 1, 0) }
    }

    /// Whether a task to `host` has its metrics still to come: a round trip may be on the way.
    func awaitsMetrics(host: String) -> Bool {
        state.withLock { ($0.awaitedMetrics[host] ?? 0) > 0 }
    }

    /// `count` body bytes came, to whichever transfer.
    func received(_ count: Int) {
        state.withLock { $0.receivedBytes += count }
    }

    /// Body bytes received by every transfer so far: a transfer's share of the link is the difference over its spells.
    var receivedBytes: Int {
        state.withLock { $0.receivedBytes }
    }

    func add(_ transfer: Transfer) {
        state.withLock { $0.transfers.append(transfer) }
    }

    /// A request asked for at `asked` was answered at `answered`.
    func addAnswer(asked: ContinuousClock.Instant, answered: ContinuousClock.Instant) {
        state.withLock { state in
            let before = state.answerSeconds
            state.answerSeconds += (answered - asked) / .seconds(1)
            state.lastAnswer = (asked, answered, Int64(state.receivedBytes), before)
        }
    }

    /// Seconds spent waiting for answers so far.
    var answerSeconds: Double { state.withLock { $0.answerSeconds } }

    /// The latest request answered.
    var lastAnswer: (asked: ContinuousClock.Instant, answered: ContinuousClock.Instant, total: Int64, seconds: Double)?
    {
        state.withLock { $0.lastAnswer }
    }

    /// `seconds` waited for an answer paid once (`HTTPSessionTransport.oneTimeRequestBytes`).
    func addOneTimeWait(_ seconds: Double) {
        state.withLock { $0.oneTimeWaits += seconds }
    }

    /// Seconds waited for answers paid once, so far: a read's are the difference over it.
    var oneTimeWaitSeconds: Double {
        state.withLock { $0.oneTimeWaits }
    }

    /// The transfers ended since the last call.
    func take() -> [Transfer] {
        state.withLock { state in
            defer { state.transfers.removeAll() }
            return state.transfers
        }
    }
}

/// One request of `HTTPSessionTransport`, read as an FFmpeg input (`FFmpegIOByteCounter`). The task's delegate fills
/// a buffer on the session's queue, which FFmpeg's thread reads, waiting when it is empty. Past `highWater` bytes
/// unread, the task is suspended (the socket's buffer fills and TCP holds the server back) until FFmpeg has read it
/// down to `lowWater`: a 4K segment of six seconds is some 30 MB, read whole while FFmpeg is still on its start.
///
/// A body cut short (the connection dropped, or timed out: a server may close one suspended for long) is asked for
/// again from where it stopped, `Range` from the bytes received, up to `retryDelays.count` times, as FFmpeg's
/// `reconnect` does for its own (`MediaURL.applyNetworkOptions`): failed, `hls.c` drops the rest of the segment.
final class HTTPSessionInput: NSObject, URLSessionDataDelegate, FFmpegInputSource, @unchecked Sendable {
    private enum Answer {
        case open
        case failed(Int32)
        case notServed
    }

    private struct State {
        /// The request's task: another after a body cut short. Made, suspended, resumed and cancelled under the lock,
        /// so a resume never comes before the suspend it answers (the reader resuming before the delegate suspended
        /// left the task suspended for good). None of these calls the delegate back synchronously, which takes the
        /// lock: no deadlock.
        var task: URLSessionDataTask?
        var answer: Answer?
        /// The body's bytes, as the first answer told them.
        var answeredLength: Int64?
        var chunks: [Data] = []
        /// Bytes of `chunks.first` already read.
        var readInFirst = 0
        var buffered = 0
        /// Body bytes still to be served: a byte range answered whole stops at its end.
        var remaining: Int64?
        var fileSize: Int64?
        var isFinished = false
        var failed = false
        var isSuspended = false
        /// The task was suspended at some point: a server may close a connection left idle that long.
        var wasSuspended = false
        var isClosed = false
        /// Body bytes received, by every task.
        var received = 0
        /// Where the first answer came from, after the redirects a request that follows them went through.
        var servedFrom: URL?
        /// Of them, those that came while the transfer didn't run (still under way when suspended): in no time.
        var untimed = 0
        var retries = 0
        /// Since when the transfer runs, while it does, and for how long it ran before.
        var transferringSince: ContinuousClock.Instant?
        var transferSeconds = 0.0
        /// The meter's count of bytes received (by every transfer) when this one began its spell, and the sum over its
        /// spells of what every transfer received during them, itself included; the opening's spells are left out as
        /// `limitedSeconds` is.
        var meterBytesAtStart = 0
        var meterBytes = 0
        var isReported = false
        /// The task asked for a piece of the body (`makeTask`), and the body goes on past it once it ends.
        var isChunked = false
        /// Of `received` and `transferSeconds`, what came while the demuxer opened (`OpeningLimit`): the rungs of a
        /// ladder read side by side, each with a share of the link, not a sample of its rate.
        var limitedBytes = 0
        var limitedSeconds = 0.0
        /// The task was made while the demuxer opened: all its bytes and time are the opening's, whenever they come.
        var isOpeningTask = false
        var needsContinuation = false
        /// When the request was made, and when its first answer came (`progress`).
        var requestedAt: ContinuousClock.Instant?
        var answeredAt: ContinuousClock.Instant?
        var lastObserved: ContinuousClock.Instant?
        /// The download was given up for another's (`abandon`): a read waiting for it is interrupted, as a seek's would.
        var isAbandoned = false
    }

    static let highWater = 32 << 20
    static let lowWater = 8 << 20
    /// While the demuxer opens (`OpeningLimit`): it reads the start of each of a ladder's rungs, and a body downloaded
    /// whole for those few kilobytes (a rung of 4.5 Mbit/s: 2.7 MB) costs seconds of a slow link, with all the rungs.
    static let openingHighWater = 256 << 10
    static let openingLowWater = 64 << 10

    /// How a request of the demuxer's opening (`OpeningLimit`) is read. Its bytes are the opening's either way: counted
    /// in its rate, and no adaptive-bitrate sample.
    enum Opening: Sendable {
        /// A probe of a stream's description, of which FFmpeg's analysis reads a little: held to `openingHighWater`,
        /// asked for in pieces of it.
        case held
        /// The segment playback starts on (`HLSInput`'s start rung): asked for whole and not held, so that its probe goes
        /// on as the segment read (`HLSLane.startBody`) and its transfer measures the link (`OpeningLimit.linkRate`).
        /// What comes after the opening is a sample of the link's rate, as any segment's (`openingEnded`).
        case start
    }

    /// What the inputs opened while a demuxer opens share (`HTTPSessionTransport.open(opening:)`), until it has
    /// (`HTTPSessionTransport.endOpening`): the held ones are held to `openingHighWater` while `isLimited`, their buffers
    /// growing as any's once lifted, and all of them measure the link together (`throughput`, `linkRate`).
    final class OpeningLimit: Sendable {
        private struct State {
            var isLimited = true
            /// Inputs transferring now, since when any did, for how long any did, and what they brought meanwhile.
            var active = 0
            var busySince: ContinuousClock.Instant?
            var busySeconds = 0.0
            var bytes = 0
            /// The busy seconds when `bytes` first reached `openingHighWater`, and the bytes when the busy time first
            /// reached half a second: the points `throughput` could be read at, for the measurement (`rateReport`).
            var secondsAtHighWater: Double?
            var bytesAtHalfSecond: (bytes: Int, seconds: Double)?
            /// The bytes `linkRate` leaves out, and the bytes and busy seconds once they had come.
            var skip = 0
            var atSkip: (bytes: Int, seconds: Double)?
            /// What `lift` tells the inputs that go on past the opening (`HTTPSessionInput.openingEnded`).
            var onLift: [@Sendable () -> Void] = []

            var seconds: Double {
                busySeconds + (busySince.map { (ContinuousClock.now - $0) / .seconds(1) } ?? 0)
            }
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        var isLimited: Bool { state.withLock { $0.isLimited } }
        /// Ends the measuring: what the inputs do from now on is not the opening's.
        func lift() {
            let told = state.withLock { state -> [@Sendable () -> Void] in
                state.isLimited = false
                if let since = state.busySince {
                    state.busySeconds += (ContinuousClock.now - since) / .seconds(1)
                    state.busySince = nil
                }
                defer { state.onLift = [] }
                return state.onLift
            }
            // Outside the lock: an input tells its transfer's end and start under its own, which takes this one.
            for tell in told { tell() }
        }

        /// `tell` is called when the opening ends; false (nothing registered) once it has.
        func whenLifted(_ tell: @escaping @Sendable () -> Void) -> Bool {
            state.withLock { state in
                guard state.isLimited else { return false }
                state.onLift.append(tell)
                return true
            }
        }

        /// The first `bytes` the inputs bring are no measure of the link (`linkRate`). Before they come.
        func skip(_ bytes: Int) {
            state.withLock { $0.skip = max(bytes, 0) }
        }

        /// Whether an input transfers now, while the opening goes on.
        var isTransferring: Bool { state.withLock { $0.isLimited && $0.busySince != nil } }

        /// Bytes `linkRate` measures the link over, past the skipped ones.
        static let measuredBytes = 256 << 10
        /// The least time past the skip a rate of a link slower than the limit is measured over; less, and it is the
        /// whole opening's.
        static let shortestMeasure = 0.25

        /// Bits a second of the link, once they can be told against `limit` (bits a second): over `measuredBytes` past the
        /// first `skip` ones (TCP's slow start), or, when a link at `limit` would have brought them and the skip by now,
        /// over what came past the skip (all that came, past it for less than `shortestMeasure`): a link proven slower
        /// than the limit, whose rate a full measure would only wait for. Nil until then. The time is the time any input
        /// transferred (`throughput`).
        func linkRate(limit: Double) -> Double? {
            state.withLock { state in
                let seconds = state.seconds
                if let start = state.atSkip {
                    let bytes = state.bytes - start.bytes
                    let time = seconds - start.seconds
                    if bytes >= Self.measuredBytes, time > 0 { return Double(bytes) * 8 / time }
                }
                guard limit > 0, seconds >= Double(state.skip + Self.measuredBytes) * 8 / limit else { return nil }
                if let start = state.atSkip, seconds - start.seconds >= Self.shortestMeasure,
                    state.bytes > start.bytes
                {
                    return Double(state.bytes - start.bytes) * 8 / (seconds - start.seconds)
                }
                return Double(state.bytes) * 8 / seconds
            }
        }

        /// Bits a second of what came, when the transfers ended before `linkRate` could tell (a start's segment smaller
        /// than the skip and the measure, a start's probe that failed): past the skip when that ran `shortestMeasure`,
        /// else all of it. Nil for less than half a second of transfer: a link that brought all it was asked for that
        /// fast is no slow one.
        var rateOfWhatCame: Double? {
            state.withLock { state in
                let seconds = state.seconds
                guard seconds >= 0.5, state.bytes > 0 else { return nil }
                if let start = state.atSkip, seconds - start.seconds >= Self.shortestMeasure,
                    state.bytes > start.bytes
                {
                    return Double(state.bytes - start.bytes) * 8 / (seconds - start.seconds)
                }
                return Double(state.bytes) * 8 / seconds
            }
        }

        func transferBegan() {
            state.withLock { state in
                guard state.isLimited else { return }
                state.active += 1
                if state.busySince == nil { state.busySince = .now }
            }
        }

        func transferEnded() {
            state.withLock { state in
                guard state.isLimited else { return }
                state.active = max(state.active - 1, 0)
                if state.active == 0, let since = state.busySince {
                    state.busySeconds += (ContinuousClock.now - since) / .seconds(1)
                    state.busySince = nil
                }
            }
        }

        func received(_ count: Int) {
            state.withLock { state in
                guard state.isLimited else { return }
                state.bytes += count
                let seconds = state.seconds
                if state.secondsAtHighWater == nil, state.bytes >= HTTPSessionInput.openingHighWater {
                    state.secondsAtHighWater = seconds
                }
                if state.bytesAtHalfSecond == nil, seconds >= 0.5 {
                    state.bytesAtHalfSecond = (state.bytes, seconds)
                }
                if state.atSkip == nil, state.bytes >= state.skip {
                    state.atSkip = (state.bytes, seconds)
                }
            }
        }

        /// The rate at the points it could be read at (the first `openingHighWater` bytes, the first half second of
        /// transfer) and over all, for the measurement of the opening (`HLSOpeningMeasure.rate`).
        var rateReport: String {
            state.withLock { state in
                func kbps(_ bytes: Int, _ seconds: Double) -> String {
                    seconds > 0 ? "\(Int(Double(bytes) * 8 / seconds / 1000))kbit/s" : "-"
                }
                let highWater = HTTPSessionInput.openingHighWater
                let atHighWater = state.secondsAtHighWater.map {
                    "\(kbps(highWater, $0))/\(Int(($0 * 1000).rounded()))ms"
                }
                let atHalf = state.bytesAtHalfSecond.map { "\(kbps($0.bytes, $0.seconds))/\($0.bytes >> 10)KB" }
                let seconds = state.seconds
                let ms = { (seconds: Double) in Int((seconds * 1000).rounded()) }
                let pastSkip = state.atSkip.map { start in
                    let bytes = state.bytes - start.bytes
                    return "\(kbps(bytes, seconds - start.seconds))/\(bytes >> 10)KB/\(ms(seconds - start.seconds))ms"
                }
                return "at\(highWater >> 10)KB=\(atHighWater ?? "-") at0.5s=\(atHalf ?? "-") "
                    + "all=\(kbps(state.bytes, seconds))/\(state.bytes >> 10)KB/\(ms(seconds))ms "
                    + "skip=\(state.skip >> 10)KB past=\(pastSkip ?? "-")"
            }
        }

        /// Bits a second the inputs brought together over the time any of them transferred (the ladder's rungs read
        /// side by side share the link: each one's own rate is a share of it), once there is enough to say.
        var throughput: Double? {
            state.withLock { state in
                let seconds = state.seconds
                guard state.bytes >= HTTPSessionInput.openingHighWater, seconds >= 0.5 else { return nil }
                return Double(state.bytes) * 8 / seconds
            }
        }
    }

    private let openingLimit: OpeningLimit?
    /// How the input is read while the demuxer opens, when it is one of the opening's (`openingLimit`).
    private let opening: Opening
    /// A redirect is followed here, and the answer of where it leads is the input's. For a request whose address is whole
    /// and whose answer needs no other address to be read (a live stream's segment, `LiveSegmentGate`); an HLS playlist's
    /// is FFmpeg's, which resolves the relative addresses in it against where it was served from.
    private let followsRedirects: Bool
    /// Held to the opening's buffer: a held input of the opening, while it goes on.
    private var isHeld: Bool { opening == .held && openingLimit?.isLimited == true }
    private var highWater: Int { isHeld ? Self.openingHighWater : Self.highWater }
    private var lowWater: Int { isHeld ? Self.openingLowWater : Self.lowWater }
    /// Seconds before asking again for a body cut short, a retry each: FFmpeg's `reconnect` waits 0, 1, 2, … s.
    static let retryDelays = [0.0, 1, 2]
    /// `AVERROR_EXIT` (`-MKTAG('E', 'X', 'I', 'T')`), FFmpeg's error for an interrupted call.
    static let averrorExit: Int32 = -0x5449_5845

    private let holder: HTTPSessionHolder
    private let request: URLRequest
    private let offset: Int64
    private let end: Int64?
    private let meter: NetworkTransferMeter
    private let shouldAbort: @Sendable () -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Signalled when the state the reader waits on changes (an answer, data into an empty buffer, the end), for the
    /// one thread that reads (FFmpeg's).
    private let changed = DispatchSemaphore(value: 0)

    init(
        holder: HTTPSessionHolder, request: URLRequest, offset: Int64, end: Int64?, meter: NetworkTransferMeter,
        openingLimit: OpeningLimit? = nil, opening: Opening = .held, followsRedirects: Bool = false,
        shouldAbort: @escaping @Sendable () -> Bool
    ) {
        self.followsRedirects = followsRedirects
        self.openingLimit = openingLimit
        self.opening = opening
        self.holder = holder
        self.request = request
        self.offset = offset
        self.end = end
        self.meter = meter
        self.shouldAbort = shouldAbort
    }

    private var requestURL: URL {
        request.url ?? URL(fileURLWithPath: "/")
    }

    /// A task for the body from `position` on (the request's offset at first), to `end`: while the demuxer opens
    /// (`OpeningLimit`), a held one to `openingHighWater` bytes only, so the server sends no more (a suspended task's
    /// socket still takes in what the kernel buffers: megabytes of a slow link) and `startContinuation` asks for the
    /// rest. Made behind `state`'s lock, as the task is its `task`.
    private func makeTask(from position: Int64, in state: inout State) -> URLSessionDataTask {
        var request = request
        var last = end.map { $0 - 1 }
        state.isChunked = false
        state.isOpeningTask = openingLimit?.isLimited == true
        if state.isOpeningTask, opening == .start {
            // Whole, and read on past the opening: what comes after it is a sample, as any segment's.
            let registered =
                openingLimit?.whenLifted { [weak self] in
                    self?.openingEnded()
                } ?? false
            if !registered { state.isOpeningTask = false }
        }
        if isHeld {
            let chunkLast = position + Int64(Self.openingHighWater) - 1
            if last.map({ chunkLast < $0 }) ?? true {
                last = chunkLast
                state.isChunked = true
            }
        }
        if position > 0 || last != nil {
            request.setValue("bytes=\(position)-\(last.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        }
        // Made under the holder's lock: a session is closed only after the tasks made on it, never between a task's session
        // being picked and its being made (a task made on a closed session is an exception that ends the app).
        let task = holder.dataTask(with: request)
        task.delegate = self
        if let host = request.url?.host { meter.awaitMetrics(host: host) }
        state.task = task
        return task
    }

    /// The next chunk of a body asked for in pieces. Behind `state`'s lock.
    private func startContinuation(in state: inout State) {
        state.needsContinuation = false
        state.wasSuspended = false
        state.isSuspended = false
        makeTask(from: offset + Int64(state.received), in: &state).resume()
    }

    fileprivate func start() {
        state.withLockUnchecked { state in
            state.requestedAt = .now
            makeTask(from: offset, in: &state).resume()
        }
    }

    /// How far the request has got, for the rule that gives a download up (`AdaptiveBitrateLogic.abandonment`).
    struct Progress: Sendable, Equatable {
        /// Body bytes received, read or not.
        var bytes: Int
        /// The body's length, as the server told it.
        var length: Int64?
        /// Seconds since the request was made.
        var elapsed: Double
        /// Seconds until the first answer, once it came.
        var firstAnswer: Double?
        /// Seconds the transfer ran (not suspended by a full buffer) since the first answer, and the bytes it brought in
        /// them: what came while the demuxer opened is left out of both (the ladder's rungs read side by side, a share
        /// of the link, not its rate); none while that goes on.
        var transferring: Double
        var measuredBytes: Int
        /// The task is suspended: the reader is behind, so a slow download is not the link's doing.
        var isSuspended: Bool
        /// The body is through, or the request closed: nothing is left to watch.
        var isFinished = false
    }

    /// Told how far the request has got while the reader waits for its bytes, at most every `observeInterval`: the
    /// read thread is blocked there exactly when a download is too slow. Set before the first read.
    var onProgress: (@Sendable (Progress) -> Void)?
    static let observeInterval = Duration.milliseconds(100)

    var progress: Progress {
        state.withLock { state in
            let now = ContinuousClock.now
            let spell = state.transferringSince.map { (now - $0) / .seconds(1) } ?? 0
            return Progress(
                bytes: state.received, length: state.answeredLength,
                elapsed: state.requestedAt.map { (now - $0) / .seconds(1) } ?? 0,
                firstAnswer: state.requestedAt.flatMap { requested in
                    state.answeredAt.map { ($0 - requested) / .seconds(1) }
                },
                transferring: max(
                    state.transferSeconds + spell - state.limitedSeconds - (state.isOpeningTask ? spell : 0), 0),
                measuredBytes: state.isOpeningTask ? 0 : max(state.received - state.limitedBytes, 0),
                isSuspended: state.isSuspended, isFinished: state.isFinished || state.isClosed)
        }
    }

    private func observeIfDue() {
        guard let onProgress else { return }
        let isDue = state.withLock { state -> Bool in
            let now = ContinuousClock.now
            guard !state.isFinished, !state.isClosed,
                state.lastObserved.map({ now - $0 >= Self.observeInterval }) ?? true
            else { return false }
            state.lastObserved = now
            return true
        }
        if isDue { onProgress(progress) }
    }

    /// Waits for `condition` on the state, checking `shouldAbort` every 50 ms: false when interrupted. A download given up
    /// (`abandon`) is interrupted whatever the state, first: the condition holds at once on bytes buffered or on the
    /// cancelled task's end (cut short, a failure), which read so made the rest of the body the segment's end, or -EIO.
    private func wait(until condition: (State) -> Bool) -> Bool {
        while true {
            let (isAbandoned, isMet) = state.withLockUnchecked { ($0.isAbandoned, condition($0)) }
            if isAbandoned { return false }
            if isMet { return true }
            if shouldAbort() { return false }
            observeIfDue()
            _ = changed.wait(timeout: .now() + .milliseconds(50))
        }
    }

    fileprivate func waitForAnswer() -> HTTPSessionTransport.Opened {
        guard wait(until: { $0.answer != nil }) else {
            close()
            return .failed(Self.averrorExit)
        }
        switch state.withLock({ $0.answer }) {
        case .open?: return .input(self)
        case .failed(let code)?: return .failed(code)
        case .notServed?, nil: return .notServed
        }
    }

    /// The body's bytes, once answered, when the server told them.
    var answeredLength: Int64? {
        state.withLock { $0.answeredLength }
    }

    /// The address that answered, after the redirects a request that followed them went through: what a playlist's
    /// relative URIs are read against.
    var servedFrom: URL? {
        state.withLock { $0.servedFrom }
    }

    /// Body bytes the task has delivered so far, read or not.
    var receivedBytes: Int {
        state.withLock { $0.received }
    }

    /// The transfer runs, or not (suspended, ended, closed). Behind `state`'s lock.
    private func setTransferring(_ transferring: Bool, in state: inout State) {
        if transferring {
            if state.transferringSince == nil {
                state.transferringSince = .now
                state.meterBytesAtStart = meter.receivedBytes
                openingLimit?.transferBegan()
            }
        } else if let since = state.transferringSince {
            let seconds = (ContinuousClock.now - since) / .seconds(1)
            state.transferSeconds += seconds
            if state.isOpeningTask {
                state.limitedSeconds += seconds
            } else {
                state.meterBytes += meter.receivedBytes - state.meterBytesAtStart
            }
            state.transferringSince = nil
            openingLimit?.transferEnded()
        }
    }

    /// The opening ended while a start's task (`Opening.start`) goes on: what it brought so far is the opening's, what it
    /// brings from now on a sample of the link. Its spell is ended and begun again, outside the opening.
    private func openingEnded() {
        state.withLockUnchecked { state in
            guard state.isOpeningTask else { return }
            let isTransferring = state.transferringSince != nil
            setTransferring(false, in: &state)
            state.isOpeningTask = false
            if isTransferring { setTransferring(true, in: &state) }
        }
    }

    /// The transfer ended (or was given up, with what it brought): the meter's sample, but of a body paid once
    /// (`HTTPSessionTransport.oneTimeRequestBytes`). Behind `state`'s lock.
    private func reportTransfer(in state: inout State) {
        setTransferring(false, in: &state)
        guard !state.isReported, state.received > 0 else { return }
        state.isReported = true
        // What came while opening is the ladder's share of the link, not this input's: not a sample.
        let bytes = state.received - state.limitedBytes
        let seconds = state.transferSeconds - state.limitedSeconds
        guard bytes >= HTTPSessionTransport.oneTimeRequestBytes, seconds > 0 else { return }
        meter.add(
            .init(
                bytes: bytes - state.untimed, seconds: seconds, linkBytes: state.meterBytes,
                roundTrip: request.url?.host.flatMap { meter.roundTrip(host: $0) }))
    }

    // MARK: FFmpegInputSource

    func read(_ buffer: UnsafeMutablePointer<UInt8>, _ size: Int32) -> Int32 {
        while true {
            let result = readOnce(buffer, size)
            if result != Self.again { return result }
        }
    }

    /// `readOnce`'s answer when the next piece of the body was asked for: read again once it comes.
    private static let again = Int32.min

    private func readOnce(_ buffer: UnsafeMutablePointer<UInt8>, _ size: Int32) -> Int32 {
        guard
            wait(until: { $0.buffered > 0 || $0.isFinished || $0.remaining == 0 || $0.needsContinuation })
        else { return Self.averrorExit }
        let (result, isServed) = state.withLockUnchecked { state -> (Int32, Bool) in
            if state.remaining == 0 { return (MediaDemuxer.averrorEOF, true) }
            if state.buffered == 0, state.needsContinuation {
                // The piece is read: the next, and the reader waits for it.
                startContinuation(in: &state)
                return (Self.again, false)
            }
            guard state.buffered > 0 else { return (state.failed ? -EIO : MediaDemuxer.averrorEOF, false) }
            var wanted = Int(size)
            if let remaining = state.remaining { wanted = Int(min(Int64(wanted), remaining)) }
            var copied = 0
            while copied < wanted, let first = state.chunks.first {
                let count = min(wanted - copied, first.count - state.readInFirst)
                let start = first.startIndex + state.readInFirst
                first.copyBytes(to: buffer + copied, from: start..<(start + count))
                copied += count
                state.readInFirst += count
                if state.readInFirst == first.count {
                    state.chunks.removeFirst()
                    state.readInFirst = 0
                }
            }
            state.buffered -= copied
            state.remaining = state.remaining.map { $0 - Int64(copied) }
            if state.needsContinuation, state.buffered <= lowWater {
                startContinuation(in: &state)
            } else if state.isSuspended, state.buffered <= lowWater {
                state.isSuspended = false
                setTransferring(true, in: &state)
                state.task?.resume()
            }
            return (Int32(copied), state.remaining == 0)
        }
        // A byte range answered whole: the rest of the file isn't needed.
        if isServed, !state.withLock({ $0.isFinished }) { close() }
        return result
    }

    /// Only the file's size (`avio_size`, which an init section without a byte range asks).
    func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        guard whence & AVSEEK_SIZE != 0, let size = state.withLock({ $0.fileSize }) else { return Int64(-ENOSYS) }
        return size
    }

    /// Gives the download up for another's: the task is cancelled, and a read waiting for it, now or later, is interrupted
    /// (`averrorExit`, as a seek interrupts it) instead of reading what is left of the body as the end of a segment.
    /// What it received stays reported as a transfer (`reportTransfer`): the link did carry it.
    func abandon() {
        state.withLockUnchecked { $0.isAbandoned = true }
        close()
        changed.signal()
    }

    func close() {
        state.withLockUnchecked { state in
            state.isClosed = true
            reportTransfer(in: &state)
            state.task?.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    /// A redirect isn't followed, but for the input that asked to (`followsRedirects`): its answer goes to FFmpeg, which
    /// asks for it again and follows it itself.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Not to a plainer scheme than the request's: a segment asked for over https is not given up to http.
        let isDowngrade = response.url?.scheme == "https" && request.url?.scheme != "https"
        completionHandler(followsRedirects && !isDowngrade ? request : nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let isAllowed = state.withLockUnchecked { state -> Bool in
            guard dataTask === state.task, !state.isClosed else { return false }
            if case .open? = state.answer {
                // Asked for again, from the bytes received on: only that range carries on the body.
                let position = offset + Int64(state.received)
                guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                    http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(position)-") == true
                else {
                    state.isFinished = true
                    state.failed = true
                    return false
                }
                setTransferring(true, in: &state)
                return true
            }
            let answer = Self.answer(
                to: response, url: requestURL, offset: offset, end: end, followsRedirects: followsRedirects)
            var answered = answer
            if state.isChunked, (response as? HTTPURLResponse)?.statusCode != 206 { state.isChunked = false }
            if state.isChunked, case .open = answer.answer, let http = response as? HTTPURLResponse,
                http.statusCode == 206
            {
                // A piece of the body: what it carries is the whole body's, to the request's end or the file's.
                if let total = end ?? answer.fileSize {
                    answered.remaining = total - offset
                } else {
                    answered.answer = .notServed
                }
            }
            state.answer = answered.answer
            state.answeredAt = state.answeredAt ?? .now
            state.servedFrom = response.url
            state.answeredLength = answered.remaining
            state.fileSize = answered.fileSize
            state.remaining = answered.remaining
            guard case .open = answered.answer else { return false }
            setTransferring(true, in: &state)
            return true
        }
        completionHandler(isAllowed ? .allow : .cancel)
        changed.signal()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let wasEmpty = state.withLockUnchecked { state -> Bool in
            guard dataTask === state.task, !state.isClosed else { return false }
            let wasEmpty = state.buffered == 0
            state.chunks.append(data)
            state.buffered += data.count
            state.received += data.count
            meter.received(data.count)
            let isOpening = state.isOpeningTask
            if isOpening {
                openingLimit?.received(data.count)  // Ignored once lifted: the rate is the opening's alone.
                state.limitedBytes += data.count
            }
            if !isOpening, state.transferringSince == nil { state.untimed += data.count }
            // A piece asked for with a `Range` ends at its bound, whatever is unread.
            if !state.isSuspended, !state.isChunked, state.buffered >= highWater {
                state.isSuspended = true
                state.wasSuspended = true
                setTransferring(false, in: &state)
                dataTask.suspend()
            }
            return wasEmpty
        }
        if wasEmpty { changed.signal() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // A connection the server closed (HTTP/3 to YouTube's servers does it after a response, with the next request
        // already on it): the requests that follow, retries included, would go on the same dead connection until the
        // session drops it, which was seen to be never. A session of its own for what comes next. The replacement costs
        // the other inputs their warm connections (their TLS, their window): on HTTP/1.1, where a server closing an idle
        // keep-alive is routine, it would drop them too, and the metrics of the next requests would show the slow start.
        // Only HTTP/3 to YouTube was seen. Not narrowed to it (the protocol is known by now: `didFinishCollecting` comes
        // before this) until another case shows the cost.
        if (error as? URLError)?.code == .networkConnectionLost { holder.replace(session) }
        let retry = state.withLockUnchecked { state -> Double? in
            guard task === state.task else { return nil }
            setTransferring(false, in: &state)
            // A connection dropped is asked again, as FFmpeg's `reconnect` does; one timed out only after a suspension
            // (a server closing a connection idle that long), as FFmpeg's isn't (`reconnect_on_network_error` off):
            // a server just slow would hold the read-ahead for every retry's timeout.
            let isCutShort = state.answeredLength.map { Int64(state.received) < $0 } ?? true
            let code = (error as? URLError)?.code
            if error != nil, !state.isClosed, !state.isFinished, case .open? = state.answer, isCutShort,
                state.retries < Self.retryDelays.count, code != .cancelled, code != .timedOut || state.wasSuspended
            {
                state.retries += 1
                return Self.retryDelays[state.retries - 1]
            }
            // A piece of the body ended with more to come: the next is asked for when the buffer has run down.
            if error == nil, state.isChunked, !state.isClosed, !state.isFinished, case .open? = state.answer,
                let total = state.answeredLength, Int64(state.received) < total
            {
                // Asked for by the reader (`read`), not now: a rung of a ladder that isn't played is not read on, and
                // would otherwise download its segment to `highWater` once the opening is done.
                state.needsContinuation = true
                return nil
            }
            state.isFinished = true
            // An error after the whole body came (the connection closed on the last byte) loses nothing.
            state.failed = state.failed || (error != nil && isCutShort)
            if state.answer == nil {
                state.answer = (error as? URLError)?.code == .timedOut ? .failed(-ETIMEDOUT) : .failed(-EIO)
            }
            if !state.isClosed { reportTransfer(in: &state) }
            return nil
        }
        if let retry {
            let received = state.withLock { $0.received }
            AppLog.warning(
                .demuxer,
                "HTTP: \(requestURL.lastPathComponent) cut short at \(received) B "
                    + "(\(error?.localizedDescription ?? "?")): asking again in \(Int(retry)) s")
            DispatchQueue.global().asyncAfter(deadline: .now() + retry) { [self] in
                state.withLockUnchecked { state in
                    guard !state.isClosed else { return }
                    let task = makeTask(from: offset + Int64(state.received), in: &state)
                    // A task suspended when it was cut short: the new one runs, and its data suspends it again if
                    // what is buffered still reaches `highWater`.
                    state.isSuspended = false
                    state.wasSuspended = false
                    task.resume()
                }
            }
            return
        }
        if let error, (error as? URLError)?.code != .cancelled {
            AppLog.warning(.demuxer, "HTTP: \(requestURL.lastPathComponent) failed: \(error.localizedDescription)")
        }
        changed.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for transaction in metrics.transactionMetrics {
            guard let host = transaction.request.url?.host, let roundTrip = Self.roundTrip(of: transaction) else {
                continue
            }
            meter.noteRoundTrip(roundTrip, host: host)
        }
        if let host = task.originalRequest?.url?.host { meter.metricsCame(host: host) }
        guard let transaction = metrics.transactionMetrics.last, let requested = transaction.fetchStartDate,
            let answered = transaction.responseStartDate, let ended = transaction.responseEndDate
        else { return }
        let received = state.withLock { $0.received }
        let ms = { (seconds: TimeInterval) in Int((seconds * 1000).rounded()) }
        let transfer = ended.timeIntervalSince(answered)
        let rate = transfer > 0 ? "\(Int(Double(received) * 8 / transfer / 1000)) kbit/s" : "-"
        AppLog.debug(
            .demuxer,
            "HTTP: \(requestURL.lastPathComponent) @\(offset) \(received) B, answer \(ms(answered.timeIntervalSince(requested))) ms, "
                + "transfer \(ms(transfer)) ms (\(rate)), \(transaction.isReusedConnection ? "reused" : "new") "
                + "\(transaction.networkProtocolName ?? "?")")
    }

    /// A round trip to the server, from how a new connection was set up: TCP's handshake alone (to the start of TLS, or
    /// to the connection for plain HTTP), or QUIC's for HTTP/3, one round trip with its TLS. Nil for a connection reused
    /// or through a proxy (the round trip is the proxy's), or one not timed.
    static func roundTrip(of transaction: URLSessionTaskTransactionMetrics) -> Double? {
        guard !transaction.isReusedConnection, !transaction.isProxyConnection,
            let start = transaction.connectStartDate
        else { return nil }
        let end =
            transaction.networkProtocolName == "h3"
            ? transaction.connectEndDate : (transaction.secureConnectionStartDate ?? transaction.connectEndDate)
        guard let end else { return nil }
        let seconds = end.timeIntervalSince(start)
        return seconds > 0 ? seconds : nil
    }

    /// What FFmpeg is told of `response`, the file's size, and the body bytes it serves.
    private static func answer(to response: URLResponse, url: URL, offset: Int64, end: Int64?, followsRedirects: Bool)
        -> (answer: Answer, fileSize: Int64?, remaining: Int64?)
    {
        guard let http = response as? HTTPURLResponse else { return (.notServed, nil, nil) }
        // Answered from another address: a redirect followed, which FFmpeg is to open itself, unless it was asked to follow.
        guard followsRedirects || http.url?.absoluteString == url.absoluteString else { return (.notServed, nil, nil) }
        let length = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        switch http.statusCode {
        case 200:
            // The whole file: for a range from its start too, then cut at its end.
            guard offset == 0 else { return (.notServed, nil, nil) }
            return (.open, length, end ?? length)
        case 206:
            // `bytes 0-131071/12000000`: from the offset asked for, the size after the slash (`*` when unknown).
            guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                contentRange.hasPrefix("bytes \(offset)-")
            else { return (.notServed, nil, nil) }
            let fileSize = contentRange.split(separator: "/").last.flatMap { Int64($0) }
            return (.open, fileSize, length)
        case 400: return (.failed(ffErrorTag(0xF8, "4", "0", "0")), nil, nil)
        case 401: return (.failed(ffErrorTag(0xF8, "4", "0", "1")), nil, nil)
        case 403: return (.failed(ffErrorTag(0xF8, "4", "0", "3")), nil, nil)
        case 404: return (.failed(ffErrorTag(0xF8, "4", "0", "4")), nil, nil)
        case 429: return (.failed(ffErrorTag(0xF8, "4", "2", "9")), nil, nil)
        case 400..<500: return (.failed(ffErrorTag(0xF8, "4", "X", "X")), nil, nil)
        case 500..<600: return (.failed(ffErrorTag(0xF8, "5", "X", "X")), nil, nil)
        // A redirect (not followed) and the rest: FFmpeg's to open.
        default: return (.notServed, nil, nil)
        }
    }

    /// `FFERRTAG(a, b, c, d)`, which doesn't import into Swift: FFmpeg's `AVERROR_HTTP_*`.
    static func ffErrorTag(_ a: UInt8, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
        let tag =
            UInt32(a) | UInt32(b.asciiValue ?? 0) << 8 | UInt32(c.asciiValue ?? 0) << 16
            | UInt32(d.asciiValue ?? 0) << 24
        return -Int32(bitPattern: tag)
    }
}

/// The `URLSession` a transport's requests go through, which can be replaced: a session keeps its connections, and one
/// the server closed may be the one its next request is put on (`HTTPSessionInput`, `networkConnectionLost`). The
/// replaced one finishes the requests it has, and goes. The cookies belong to the holder, not to a session: every session
/// is made with the first's storage.
final class HTTPSessionHolder: Sendable {
    private struct State {
        var session: URLSession
        var isInvalidated = false
    }

    /// Makes the next session; `nil` for one that is never replaced.
    private let make: (@Sendable () -> URLSession)?
    private let state: OSAllocatedUnfairLock<State>
    /// What the cookies of the answers go into, and the requests take theirs from.
    let cookieStorage: HTTPCookieStorage?

    /// Sessions of `configuration`, their delegates' calls on `queue`.
    init(configuration: URLSessionConfiguration, queue: OperationQueue) {
        // The storage is the first session's: an ephemeral configuration may make its own only with a session. Set once,
        // before any session is made from the configuration again.
        let first = URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
        let storage = first.configuration.httpCookieStorage
        configuration.httpCookieStorage = storage
        cookieStorage = storage
        make = { URLSession(configuration: configuration, delegate: nil, delegateQueue: queue) }
        state = OSAllocatedUnfairLock(initialState: State(session: first))
    }

    /// One session that is never replaced.
    init(fixed session: URLSession) {
        make = nil
        cookieStorage = session.configuration.httpCookieStorage
        state = OSAllocatedUnfairLock(initialState: State(session: session))
    }

    var session: URLSession { state.withLock { $0.session } }

    /// A task for `request`, made under the lock that `replace` takes before it closes a session: a session is closed only
    /// after the tasks made on it, so none is made on a closed one.
    func dataTask(with request: URLRequest) -> URLSessionDataTask {
        state.withLock { $0.session.dataTask(with: request) }
    }

    /// A new session in place of `lost`, unless it already was replaced (by another request that found the connection
    /// gone), or the holder is closed.
    func replace(_ lost: URLSession) {
        guard let make else { return }
        let isReplaced = state.withLock { state -> Bool in
            guard !state.isInvalidated, state.session === lost else { return false }
            state.session = make()
            return true
        }
        if isReplaced { lost.finishTasksAndInvalidate() }
    }

    func invalidate() {
        let session = state.withLock { state -> URLSession in
            state.isInvalidated = true
            return state.session
        }
        session.invalidateAndCancel()
    }
}
