import CFFmpeg
import Foundation

/// Counts the bytes an `AVFormatContext` reads from its inputs, as they come over the network: what packets leave out
/// too (container overhead, and what FFmpeg reads and drops: the HLS demuxer catches a variant it switches to up from
/// the start of a segment). Installed as the context's `io_open` / `io_close2`, which call FFmpeg's own and keep the
/// `AVIOContext`s they open: each counts its `bytes_read`. Nothing is wrapped, so the HTTP options FFmpeg reads back
/// from them (cookies, redirects) stay as they are.
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
    /// When the latest input was opened, and `total` then: a read that opened a segment transferred from there on.
    private(set) var lastOpen: (time: ContinuousClock.Instant, total: Int64)?

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
            counter.lastOpen = (.now, counter.total)
            let ret = open(s, pb, url, flags, options)
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
            return close(s, pb)
        }
    }
}
