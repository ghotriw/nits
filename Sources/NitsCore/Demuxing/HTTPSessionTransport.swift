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

    /// The demuxer has opened: the inputs opened meanwhile are held no longer (see `HTTPSessionInput.OpeningLimit`).
    func endOpening() {
        openingLimit.lift()
    }

    /// Asks for `url` from `offset` (to `end`, a byte range's, when given) and waits for the answer. `cookies` is
    /// FFmpeg's option of that name: `Set-Cookie` values, a line each, from the answer of `cookieOrigin` (where the
    /// master was served from, after its redirects).
    func open(
        _ url: String, offset: Int64, end: Int64?, cookies: String?, cookieOrigin: String?, whileOpening: Bool = false,
        followsRedirects: Bool = false
    ) -> Opened {
        guard let requestURL = URL(string: url) else { return .notServed }
        if let cookies {
            store(cookies, from: cookieOrigin.flatMap(URL.init(string:)) ?? self.cookieOrigin ?? requestURL)
        }
        var request = URLRequest(url: requestURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let input = HTTPSessionInput(
            holder: holder, request: request, offset: offset, end: end, meter: meter,
            openingLimit: whileOpening ? openingLimit : nil, followsRedirects: followsRedirects,
            shouldAbort: shouldAbort)
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

        init(bytes: Int, seconds: Double, linkBytes: Int? = nil) {
            self.bytes = bytes
            self.seconds = seconds
            self.linkBytes = max(linkBytes ?? bytes, bytes)
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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

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
    }

    static let highWater = 32 << 20
    static let lowWater = 8 << 20
    /// While the demuxer opens (`OpeningLimit`): it reads the start of each of a ladder's rungs, and a body downloaded
    /// whole for those few kilobytes (a rung of 4.5 Mbit/s: 2.7 MB) costs seconds of a slow link, with all the rungs.
    static let openingHighWater = 256 << 10
    static let openingLowWater = 64 << 10

    /// Held to `openingHighWater` while `isLimited`: shared by the inputs a DASH demuxer opens while it opens, and lifted
    /// when it has (`HTTPSessionTransport.endOpening`), the buffers of those it keeps reading then growing as any.
    final class OpeningLimit: Sendable {
        private struct State {
            var isLimited = true
            /// Inputs transferring now, since when any did, for how long any did, and what they brought meanwhile.
            var active = 0
            var busySince: ContinuousClock.Instant?
            var busySeconds = 0.0
            var bytes = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        var isLimited: Bool { state.withLock { $0.isLimited } }
        /// Ends the measuring: what the inputs do from now on is not the opening's.
        func lift() {
            state.withLock { state in
                state.isLimited = false
                if let since = state.busySince {
                    state.busySeconds += (ContinuousClock.now - since) / .seconds(1)
                    state.busySince = nil
                }
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
            state.withLock { if $0.isLimited { $0.bytes += count } }
        }

        /// Bits a second the inputs brought together over the time any of them transferred (the ladder's rungs read
        /// side by side share the link: each one's own rate is a share of it), once there is enough to say.
        var throughput: Double? {
            state.withLock { state in
                var seconds = state.busySeconds
                if let since = state.busySince { seconds += (ContinuousClock.now - since) / .seconds(1) }
                guard state.bytes >= HTTPSessionInput.openingHighWater, seconds >= 0.5 else { return nil }
                return Double(state.bytes) * 8 / seconds
            }
        }
    }

    private let openingLimit: OpeningLimit?
    /// A redirect is followed here, and the answer of where it leads is the input's. For a request whose address is whole
    /// and whose answer needs no other address to be read (a live stream's segment, `LiveSegmentGate`); an HLS playlist's
    /// is FFmpeg's, which resolves the relative addresses in it against where it was served from.
    private let followsRedirects: Bool
    private var highWater: Int { openingLimit?.isLimited == true ? Self.openingHighWater : Self.highWater }
    private var lowWater: Int { openingLimit?.isLimited == true ? Self.openingLowWater : Self.lowWater }
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
        openingLimit: OpeningLimit? = nil, followsRedirects: Bool = false, shouldAbort: @escaping @Sendable () -> Bool
    ) {
        self.followsRedirects = followsRedirects
        self.openingLimit = openingLimit
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
    /// (`OpeningLimit`), to `openingHighWater` bytes only, so the server sends no more (a suspended task's socket still
    /// takes in what the kernel buffers: megabytes of a slow link) and `startContinuation` asks for the rest.
    /// Made behind `state`'s lock, as the task is its `task`.
    private func makeTask(from position: Int64, in state: inout State) -> URLSessionDataTask {
        var request = request
        var last = end.map { $0 - 1 }
        state.isChunked = false
        state.isOpeningTask = openingLimit?.isLimited == true
        if openingLimit?.isLimited == true {
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
            makeTask(from: offset, in: &state).resume()
        }
    }

    /// Waits for `condition` on the state, checking `shouldAbort` every 50 ms: false when interrupted.
    private func wait(until condition: (State) -> Bool) -> Bool {
        while !state.withLockUnchecked({ condition($0) }) {
            if shouldAbort() { return false }
            _ = changed.wait(timeout: .now() + .milliseconds(50))
        }
        return true
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
        meter.add(.init(bytes: bytes - state.untimed, seconds: seconds, linkBytes: state.meterBytes))
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
