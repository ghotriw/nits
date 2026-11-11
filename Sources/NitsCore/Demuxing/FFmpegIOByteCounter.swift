import CFFmpeg
import Foundation

/// Counts the bytes an `AVFormatContext` reads from its inputs, as they come over the network: what packets leave out
/// too (container overhead, and what FFmpeg reads and drops). Installed as the context's `io_open` / `io_close2`, which
/// call FFmpeg's own and keep the `AVIOContext`s they open: each counts its `bytes_read`. Once the context is a DASH
/// demuxer's, its HTTP(S) requests go through `transport`. What FFmpeg opens itself it keeps as it is, so the HTTP
/// options it reads back from those inputs (cookies, redirects) stay.
///
/// Behind the demuxer's `lock`: FFmpeg opens and closes inputs inside the calls made under it.
final class FFmpegIOByteCounter: @unchecked Sendable {
    private typealias Open =
        @convention(c) (
            UnsafeMutablePointer<AVFormatContext>?, UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
            UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?
        ) -> Int32
    private typealias Close =
        @convention(c) (UnsafeMutablePointer<AVFormatContext>?, UnsafeMutablePointer<AVIOContext>?)
        -> Int32

    private var originalOpen: Open?
    private var originalClose: Close?
    private var open: Set<UnsafeMutablePointer<AVIOContext>> = []
    private var closedBytes: Int64 = 0
    /// The latest input opened, with `total` and `openSeconds` when it was asked for: a read that opened a segment
    /// transferred from `opened` on. What came before `asked`, but for the openings it took (playlist reloads), was a
    /// wait of the read's own (a live stream's edge); what follows, the request's latency.
    private(set) var lastOpen:
        (asked: ContinuousClock.Instant, opened: ContinuousClock.Instant, total: Int64, openSeconds: Double)?
    /// Seconds spent opening inputs: an HTTP input is open once its response's headers are in, so this is the
    /// requests' latency (connection, TLS, the server's answer), no transfer.
    private(set) var openSeconds = 0.0
    /// The inputs served here (`transport`'s requests), by their `AVIOContext`: closed here, not by FFmpeg.
    private var customInputs: [UnsafeMutablePointer<AVIOContext>: any FFmpegInputSource] = [:]
    /// Makes `transport`, when set before the context opens: a network source's.
    var makeTransport: (() -> HTTPSessionTransport)?
    /// The segments of a live stream's history, named by keys and numbers in its manifest, are opened through this: the
    /// source's address for each, and a wait for those past the head.
    var liveSegments: LiveSegmentGate?
    /// The demuxer is opening (`MediaDemuxer.init`): the inputs a DASH demuxer opens meanwhile are held to a few hundred
    /// kilobytes of download, which it reads the start of and leaves (`HTTPSessionInput.OpeningLimit`).
    var isOpening = false

    /// The demuxer has opened.
    func endOpening() {
        isOpening = false
        transport?.endOpening()
    }
    /// Serves the HTTP(S) inputs a DASH demuxer asks for (`isDASH`): made for its first, none for other formats.
    private(set) var transport: HTTPSessionTransport?
    /// The context installed on.
    private var context: UnsafeMutablePointer<AVFormatContext>?

    /// The context is a DASH demuxer's, known once probed, before its header is read: it opens a segment (or the range
    /// of a file) per request, which `transport` serves. A file read over HTTP, which seeks, never is.
    private var isDASH: Bool {
        context?.pointee.iformat.map { String(cString: $0.pointee.name) == "dash" } ?? false
    }

    /// The HTTP options (headers, user agent, timeouts) of the requests a DASH demuxer makes for its segments that
    /// FFmpeg opens itself: it copies them from the HTTP input its manifest was read from, which an inline manifest
    /// isn't, so they are added to each request here (`MediaURL.requestOptions`). The segments `transport` serves carry
    /// the source's headers already; these are the ones it leaves to FFmpeg, an answer redirected above all. Empty for
    /// other sources.
    var segmentRequestOptions: [(name: String, value: String)] = []

    /// Adds `segmentRequestOptions` to the request for `url` a DASH demuxer is opening, unless it carries them.
    private func addSegmentRequestOptions(
        _ s: UnsafeMutablePointer<AVFormatContext>?, _ url: UnsafePointer<CChar>?,
        _ options: UnsafeMutablePointer<OpaquePointer?>?
    ) {
        guard !segmentRequestOptions.isEmpty, let options, let url, let format = s?.pointee.iformat,
            String(cString: format.pointee.name) == "dash", MediaURL.isNetworkURL(String(cString: url))
        else { return }
        for option in segmentRequestOptions {
            _ = av_dict_set(options, option.name, option.value, AV_DICT_DONT_OVERWRITE)
        }
    }

    /// Bytes read so far by every input the context opened.
    var total: Int64 {
        open.reduce(closedBytes) { $0 + $1.pointee.bytes_read }
    }

    /// Takes over `ctx`'s `io_open` / `io_close2` and its `opaque`, before it opens anything. FFmpeg only takes C
    /// callbacks with an unretained pointer, so the caller keeps `self` alive for as long as `ctx` is open.
    func install(on ctx: UnsafeMutablePointer<AVFormatContext>) {
        context = ctx
        originalOpen = ctx.pointee.io_open
        originalClose = ctx.pointee.io_close2
        // Nested contexts call back with their own context, carrying this opaque.
        ctx.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.io_open = { s, pb, url, flags, options in
            guard
                let counter = s?.pointee.opaque.map({ Unmanaged<FFmpegIOByteCounter>.fromOpaque($0) })?
                    .takeUnretainedValue(), let open = counter.originalOpen
            else { return -1 }
            let begin = ContinuousClock.now
            let openedBefore = counter.openSeconds
            let ret: Int32
            switch pb == nil ? nil : url.flatMap({ counter.transportInput($0, options) }) {
            case .input(let input)?:
                pb?.pointee = input
                ret = 0
            case .failed(let code)?:
                ret = code
            case nil:
                counter.addSegmentRequestOptions(s, url, options)
                ret = open(s, pb, url, flags, options)
            }
            let end = ContinuousClock.now
            counter.openSeconds += (end - begin) / .seconds(1)
            counter.lastOpen = (begin, end, counter.total, openedBefore)
            if ret >= 0, let opened = pb?.pointee { counter.open.insert(opened) }
            return ret
        }
        ctx.pointee.io_close2 = { s, pb in
            guard
                let counter = s?.pointee.opaque.map({ Unmanaged<FFmpegIOByteCounter>.fromOpaque($0) })?
                    .takeUnretainedValue(), let close = counter.originalClose
            else {
                // Not expected (`install` sets both); closed all the same, as FFmpeg's own would.
                return pb.map { avio_close($0) } ?? 0
            }
            if let pb, counter.open.remove(pb) != nil { counter.closedBytes += pb.pointee.bytes_read }
            if let pb, let input = counter.customInputs.removeValue(forKey: pb) {
                input.close()
                Unmanaged<InputBox>.fromOpaque(pb.pointee.opaque).release()
                av_freep(&pb.pointee.buffer)
                var context: UnsafeMutablePointer<AVIOContext>? = pb
                avio_context_free(&context)
                return 0
            }
            return close(s, pb)
        }
    }

    private enum TransportInput {
        case input(UnsafeMutablePointer<AVIOContext>)
        case failed(Int32)
    }

    /// `url` served by `transport`, from where FFmpeg asks for it (a byte range's `offset`, to its `end_offset`), or
    /// the server's error; nil when FFmpeg opens it itself.
    private func transportInput(_ url: UnsafePointer<CChar>, _ options: UnsafeMutablePointer<OpaquePointer?>?)
        -> TransportInput?
    {
        let url = String(cString: url)
        guard isDASH, HTTPSessionTransport.serves(url) else { return nil }
        if transport == nil { transport = makeTransport?() }
        guard let transport else { return nil }
        let end = Self.intOption("end_offset", in: options).flatMap { $0 > 0 ? $0 : nil }
        // The cookies FFmpeg takes from the answers of the inputs it opens itself (the master's), for every request.
        let cookies = av_dict_get(options?.pointee, "cookies", nil, 0).flatMap { $0.pointee.value }.map {
            String(cString: $0)
        }
        let offset = Self.intOption("offset", in: options) ?? 0
        let cookieOrigin = cookies == nil ? nil : masterLocation
        let opening: HTTPSessionInput.Opening? = isOpening ? .held : nil
        let opened: HTTPSessionTransport.Opened
        if let gate = liveSegments, let segment = gate.request(for: url) {
            opened = gate.open(segment, shouldAbort: transport.shouldAbort) { address in
                // The CDN may redirect a segment (YouTube's 4K tier does, to another server), and its address is whole.
                transport.open(
                    address.absoluteString, offset: offset, end: end, cookies: cookies, cookieOrigin: cookieOrigin,
                    opening: opening, followsRedirects: true)
            }
        } else {
            opened = transport.open(
                url, offset: offset, end: end, cookies: cookies, cookieOrigin: cookieOrigin,
                opening: opening)
        }
        switch opened {
        case .input(let input):
            guard let context = makeContext(serving: input) else {
                input.close()
                return nil
            }
            // Read on from where it starts, as FFmpeg's HTTP inputs of a stream are.
            context.pointee.seekable = 0
            return .input(context)
        case .failed(let code):
            return .failed(code)
        case .notServed:
            return nil
        }
    }

    /// Where the manifest was served from, after its redirects: the `location` FFmpeg's HTTP input of it tells. Nil for
    /// a manifest that is a file.
    private var masterLocation: String? {
        guard let pb = context?.pointee.pb else { return nil }
        var location: UnsafeMutablePointer<UInt8>?
        guard av_opt_get(UnsafeMutableRawPointer(pb), "location", AV_OPT_SEARCH_CHILDREN, &location) >= 0,
            let location
        else { return nil }
        defer { av_free(location) }
        return String(cString: location)
    }

    private static func intOption(_ name: String, in options: UnsafeMutablePointer<OpaquePointer?>?) -> Int64? {
        av_dict_get(options?.pointee, name, nil, 0).flatMap { $0.pointee.value }.flatMap {
            Int64(String(cString: $0))
        }
    }

    /// An `AVIOContext` reading `input`, which it retains until closed through `io_close2`.
    private func makeContext(serving input: any FFmpegInputSource) -> UnsafeMutablePointer<AVIOContext>? {
        let bufferSize: Int32 = 32 << 10
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let box = Unmanaged.passRetained(InputBox(input))
        guard
            let context = avio_alloc_context(
                buffer, bufferSize, 0, box.toOpaque(),
                { opaque, buffer, size in
                    guard let opaque, let buffer else { return -1 }
                    return Unmanaged<InputBox>.fromOpaque(opaque).takeUnretainedValue().source.read(buffer, size)
                }, nil,
                { opaque, offset, whence in
                    guard let opaque else { return -1 }
                    return Unmanaged<InputBox>.fromOpaque(opaque).takeUnretainedValue().source.seek(offset, whence)
                })
        else {
            box.release()
            av_free(buffer)
            return nil
        }
        customInputs[context] = input
        return context
    }
}

/// An input served by Nits instead of FFmpeg's protocols (`FFmpegIOByteCounter`): its `AVIOContext`'s callbacks.
protocol FFmpegInputSource: AnyObject {
    func read(_ buffer: UnsafeMutablePointer<UInt8>, _ size: Int32) -> Int32
    /// `avio_seek`'s `offset` and `whence` (`AVSEEK_SIZE` among them).
    func seek(_ offset: Int64, _ whence: Int32) -> Int64
    /// The input is closed: what it holds is let go.
    func close()
}

/// What an input's `AVIOContext` holds, through its opaque: C callbacks take no existential.
private final class InputBox {
    let source: any FFmpegInputSource

    init(_ source: any FFmpegInputSource) {
        self.source = source
    }
}
