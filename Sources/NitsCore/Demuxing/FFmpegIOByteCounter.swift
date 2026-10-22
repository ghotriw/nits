import CFFmpeg
import Foundation

/// Counts the bytes an `AVFormatContext` reads from its inputs, as they come over the network: what packets leave out
/// too (container overhead, and what FFmpeg reads and drops: the HLS demuxer catches a variant it switches to up from
/// the start of a segment). Installed as the context's `io_open` / `io_close2`, which call FFmpeg's own and keep the
/// `AVIOContext`s they open: each counts its `bytes_read`. Nothing is wrapped, so the HTTP options FFmpeg reads back
/// from them (cookies, redirects) stay as they are. While an HLS master opens, what `HLSPlaylistPrefetcher`
/// downloaded is served from memory instead (`prefetched`), by inputs of its own.
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
    var prefetched: ((String, Int64) -> HLSPlaylistPrefetcher.Download?)?
    /// The inputs read from a download, by their `AVIOContext`: closed here, not by FFmpeg.
    private var prefetchedInputs: [UnsafeMutablePointer<AVIOContext>: PrefetchedInput] = [:]

    /// Bytes read so far by every input the context opened.
    var total: Int64 {
        open.reduce(closedBytes) { $0 + $1.pointee.bytes_read }
    }

    /// Takes over `ctx`'s `io_open` / `io_close2` and its `opaque`, before it opens anything. FFmpeg only takes C
    /// callbacks with an unretained pointer, so the caller keeps `self` alive for as long as `ctx` is open.
    func install(on ctx: UnsafeMutablePointer<AVFormatContext>) {
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
            if let s, let pb, let url, let input = counter.prefetchedInput(s, url, flags, options) {
                pb.pointee = input
                ret = 0
            } else {
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
            if let pb, let input = counter.prefetchedInputs.removeValue(forKey: pb) {
                input.close()
                Unmanaged<PrefetchedInput>.fromOpaque(pb.pointee.opaque).release()
                av_freep(&pb.pointee.buffer)
                var context: UnsafeMutablePointer<AVIOContext>? = pb
                avio_context_free(&context)
                return 0
            }
            return close(s, pb)
        }
    }

    /// An input reading what was downloaded for `url` from where FFmpeg asks for it (a byte range's `offset`, to its
    /// `end_offset`), if anything was. Past what was downloaded it reads on from the network, through FFmpeg's own
    /// `io_open` with the same options.
    private func prefetchedInput(
        _ s: UnsafeMutablePointer<AVFormatContext>, _ url: UnsafePointer<CChar>, _ flags: Int32,
        _ options: UnsafeMutablePointer<OpaquePointer?>?
    ) -> UnsafeMutablePointer<AVIOContext>? {
        let option = { (name: String) in
            av_dict_get(options?.pointee, name, nil, 0).flatMap { $0.pointee.value }.flatMap {
                Int64(String(cString: $0))
            }
        }
        let offset = option("offset") ?? 0
        guard let prefetched, let download = prefetched(String(cString: url), offset), let open = originalOpen,
            let close = originalClose
        else { return nil }
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
        let bufferSize: Int32 = 32 << 10
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self),
            let context = avio_alloc_context(
                buffer, bufferSize, 0, Unmanaged.passRetained(input).toOpaque(),
                { opaque, buffer, size in
                    guard let opaque, let buffer else { return -1 }
                    return Unmanaged<PrefetchedInput>.fromOpaque(opaque).takeUnretainedValue().read(buffer, size)
                }, nil,
                { opaque, offset, whence in
                    guard let opaque else { return -1 }
                    return Unmanaged<PrefetchedInput>.fromOpaque(opaque).takeUnretainedValue().seek(offset, whence)
                })
        else { return nil }
        prefetchedInputs[context] = input
        return context
    }
}

/// A download of `HLSPlaylistPrefetcher` read as an input (`FFmpegIOByteCounter.prefetchedInput`). Its C callbacks
/// reach it through the `AVIOContext`'s opaque, retained until the input is closed.
private final class PrefetchedInput {
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
