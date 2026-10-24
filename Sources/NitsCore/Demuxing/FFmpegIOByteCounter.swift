import CFFmpeg
import Foundation

/// Counts the bytes an `AVFormatContext` reads from its inputs, as they come over the network: what packets leave out
/// too (container overhead, and what FFmpeg reads and drops: the HLS demuxer catches a variant it switches to up from
/// the start of a segment). Installed as the context's `io_open` / `io_close2`, which call FFmpeg's own and keep the
/// `AVIOContext`s they open: each counts its `bytes_read`. While an HLS master opens, what `HLSPlaylistPrefetcher`
/// downloaded is served from memory instead (`prefetched`), by inputs of its own; and once the context is an HLS
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
    /// What was downloaded for a URL from an offset, while the context opens (`HLSPlaylistPrefetcher`): FFmpeg reads
    /// it instead of asking the server. Nil for others, which FFmpeg opens itself.
    var prefetched: ((String, Int64) -> HLSPlaylistPrefetcher.Answer?)?
    /// The inputs served here (a download, `transport`'s requests), by their `AVIOContext`: closed here, not by FFmpeg.
    private var customInputs: [UnsafeMutablePointer<AVIOContext>: any FFmpegInputSource] = [:]
    /// Makes `transport`, when set before the context opens: a network source's.
    var makeTransport: (() -> HTTPSessionTransport)?
    /// Serves the HTTP(S) inputs an HLS demuxer asks for (`isHLS`): made for its first, none for other formats.
    private(set) var transport: HTTPSessionTransport?
    /// The context installed on: nested ones (an HLS playlist's) call back with their own.
    private var context: UnsafeMutablePointer<AVFormatContext>?

    /// The context is an HLS demuxer's: known once probed, before its header is read, so its master playlist (the
    /// input probed) is FFmpeg's to open, and every request after `transport`'s. A file read over HTTP, which seeks,
    /// never is.
    private var isHLS: Bool {
        context?.pointee.iformat.map { String(cString: $0.pointee.name) == "hls" } ?? false
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
        // Nested contexts (the HLS demuxer's per playlist) call back with their own context, carrying this opaque.
        ctx.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.io_open = { s, pb, url, flags, options in
            guard
                let counter = s?.pointee.opaque.map({ Unmanaged<FFmpegIOByteCounter>.fromOpaque($0) })?
                    .takeUnretainedValue(), let open = counter.originalOpen
            else { return -1 }
            let begin = ContinuousClock.now
            let openedBefore = counter.openSeconds
            let ret: Int32
            let prefetched =
                pb == nil ? nil : s.flatMap { s in url.flatMap { counter.prefetchedInput(s, $0, flags, options) } }
            switch prefetched {
            case .input(let input)?:
                pb?.pointee = input
                ret = 0
            case .refused?:
                ret = -ENOENT
            case nil:
                switch pb == nil ? nil : url.flatMap({ counter.transportInput($0, options) }) {
                case .input(let input)?:
                    pb?.pointee = input
                    ret = 0
                case .failed(let code)?:
                    ret = code
                case nil:
                    ret = open(s, pb, url, flags, options)
                }
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

    private enum Prefetched {
        case input(UnsafeMutablePointer<AVIOContext>)
        /// Not to be opened (`HLSPlaylistPrefetcher.Answer.refused`).
        case refused
    }

    /// An input reading what was downloaded for `url` from where FFmpeg asks for it (a byte range's `offset`, to its
    /// `end_offset`), if anything was, or a refusal. Past what was downloaded it reads on from the network, through
    /// FFmpeg's own `io_open` with the same options.
    private func prefetchedInput(
        _ s: UnsafeMutablePointer<AVFormatContext>, _ url: UnsafePointer<CChar>, _ flags: Int32,
        _ options: UnsafeMutablePointer<OpaquePointer?>?
    ) -> Prefetched? {
        let option = { (name: String) in Self.intOption(name, in: options) }
        let offset = option("offset") ?? 0
        guard let prefetched, let answer = prefetched(String(cString: url), offset), let open = originalOpen,
            let close = originalClose
        else { return nil }
        guard case .download(let download) = answer else { return .refused }
        var restOptions: OpaquePointer?
        av_dict_copy(&restOptions, options?.pointee, 0)
        let restURL = strdup(url)
        let input = PrefetchedInput(
            download: download, offset: offset, end: option("end_offset") ?? download.fileSize,
            openRest: { offset in
                var opened: UnsafeMutablePointer<AVIOContext>?
                var copy: OpaquePointer?
                av_dict_copy(&copy, restOptions, 0)
                av_dict_set_int(&copy, "offset", offset, 0)
                let ret = open(s, &opened, restURL, flags, &copy)
                av_dict_free(&copy)
                return ret >= 0 ? opened : nil
            },
            closeRest: { rest in
                if let rest { _ = close(s, rest) }
                av_dict_free(&restOptions)
                free(restURL)
            })
        guard let context = makeContext(serving: input) else {
            input.close()
            return nil
        }
        return .input(context)
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
        guard isHLS, HTTPSessionTransport.serves(url) else { return nil }
        if transport == nil { transport = makeTransport?() }
        guard let transport else { return nil }
        let end = Self.intOption("end_offset", in: options).flatMap { $0 > 0 ? $0 : nil }
        // The cookies FFmpeg takes from the answers of the inputs it opens itself (the master's), for every request.
        let cookies = av_dict_get(options?.pointee, "cookies", nil, 0).flatMap { $0.pointee.value }.map {
            String(cString: $0)
        }
        switch transport.open(
            url, offset: Self.intOption("offset", in: options) ?? 0, end: end, cookies: cookies,
            cookieOrigin: cookies == nil ? nil : masterLocation)
        {
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

    /// Where the master was served from, after its redirects: the `location` FFmpeg's HTTP input of it tells, as the
    /// HLS demuxer reads it to resolve the master's URIs. Nil for a master that is a file.
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

/// A download of `HLSPlaylistPrefetcher` read as an input (`FFmpegIOByteCounter.prefetchedInput`).
private final class PrefetchedInput: FFmpegInputSource {
    private let download: HLSPlaylistPrefetcher.Download
    /// Where in the file `download` starts, and where the input ends (a byte range's end, else the file's), if known.
    private let offset: Int64
    private let end: Int64?
    private var position = 0
    private let openRest: (Int64) -> UnsafeMutablePointer<AVIOContext>?
    private let closeRest: (UnsafeMutablePointer<AVIOContext>?) -> Void
    private var rest: UnsafeMutablePointer<AVIOContext>?
    private var restFailed = false

    init(
        download: HLSPlaylistPrefetcher.Download, offset: Int64, end: Int64?,
        openRest: @escaping (Int64) -> UnsafeMutablePointer<AVIOContext>?,
        closeRest: @escaping (UnsafeMutablePointer<AVIOContext>?) -> Void
    ) {
        self.download = download
        self.offset = offset
        self.end = end
        self.openRest = openRest
        self.closeRest = closeRest
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, _ size: Int32) -> Int32 {
        // The download may hold more than a byte range ends at: the input ends there all the same.
        let available = min(download.data.count, end.map { Int(max($0 - offset, 0)) } ?? .max)
        if position < available {
            let count = min(Int(size), available - position)
            let start = download.data.startIndex + position
            download.data.copyBytes(to: buffer, from: start..<(start + count))
            position += count
            return Int32(count)
        }
        if let end, offset + Int64(position) >= end { return MediaDemuxer.averrorEOF }
        if rest == nil, !restFailed {
            rest = openRest(offset + Int64(position))
            restFailed = rest == nil
        }
        guard let rest else { return -EIO }
        let ret = avio_read(rest, buffer, size)
        return ret == 0 ? MediaDemuxer.averrorEOF : ret
    }

    /// Only the file's size (`avio_size`, which an init section's read asks): FFmpeg reads these inputs on from where
    /// they start.
    func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        guard whence & AVSEEK_SIZE != 0, let size = download.fileSize else { return Int64(-ENOSYS) }
        return size
    }

    func close() {
        closeRest(rest)
        rest = nil
    }
}
