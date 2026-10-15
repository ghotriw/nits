import CFFmpeg
import Foundation
import os

/// Reads a media resource's duration from its container header without decoding, so playlist rows
/// and totals are known before each item is played.
///
/// Only the header is read: Matroska stores the duration in the segment info and MP4 per track, so
/// `avformat_find_stream_info` (which reads packets) runs only for local files whose header has none
/// (e.g. MPEG-TS). Network resources never take that fallback.
enum MediaDurationProbe {
    /// Per-item limit, as in VLC's preparser: a stalled share or server must not hold up the queue.
    static let defaultTimeout: Duration = .seconds(5)

    private final class Interrupt: Sendable {
        let deadline: ContinuousClock.Instant
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(timeout: Duration) {
            deadline = .now + timeout
        }

        var shouldAbort: Bool {
            cancelled.withLock { $0 } || ContinuousClock.now >= deadline
        }

        func cancel() {
            cancelled.withLock { $0 = true }
        }
    }

    /// Duration in seconds, or `nil` if the resource can't be opened in time or declares none.
    static func duration(
        of url: URL,
        headers: [String: String] = [:],
        timeout: Duration = defaultTimeout
    ) async -> Double? {
        let path = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
        let interrupt = Interrupt(timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let duration = withExtendedLifetime(interrupt) {
                        readDuration(path: path, headers: headers, interrupt: interrupt)
                    }
                    continuation.resume(returning: duration)
                }
            }
        } onCancel: {
            interrupt.cancel()
        }
    }

    private static func readDuration(path: String, headers: [String: String], interrupt: Interrupt) -> Double? {
        guard !interrupt.shouldAbort else { return nil }

        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocatedCtx = formatCtx else { return nil }

        // FFmpeg only takes a C callback here; `interrupt` outlives the context via withExtendedLifetime.
        allocatedCtx.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(interrupt).toOpaque()
        allocatedCtx.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<Interrupt>.fromOpaque(opaque).takeUnretainedValue().shouldAbort ? 1 : 0
        }

        var options: OpaquePointer? = nil
        defer {
            if options != nil {
                av_dict_free(&options)
            }
        }
        let isNetwork = MediaDemuxer.isNetworkURL(path)
        if isNetwork {
            MediaDemuxer.applyNetworkOptions(&options, headers: headers)
        }

        // On failure avformat_open_input frees the context itself.
        let ret = avformat_open_input(&formatCtx, path, nil, &options)
        guard ret >= 0, let ctx = formatCtx else {
            AppLog.debug(
                .playlist, "Duration probe could not open '\(path)': \(MediaDemuxer.ffmpegErrorDescription(ret))")
            return nil
        }
        defer {
            avformat_close_input(&formatCtx)
        }

        if let duration = headerDuration(ctx) {
            return duration
        }
        guard !isNetwork, !interrupt.shouldAbort, avformat_find_stream_info(ctx, nil) >= 0 else { return nil }
        return headerDuration(ctx)
    }

    /// The container duration, else the longest stream duration (MP4 sets only per-track durations
    /// until `avformat_find_stream_info` derives the container's).
    private static func headerDuration(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Double? {
        let containerDuration = ctx.pointee.duration
        if containerDuration > 0 {
            return Double(containerDuration) / Double(AV_TIME_BASE)
        }

        var longest = 0.0
        for index in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[index] else { continue }
            let timebase = stream.pointee.time_base
            let streamDuration = stream.pointee.duration
            guard streamDuration > 0, timebase.den > 0 else { continue }
            longest = max(longest, Double(streamDuration) * Double(timebase.num) / Double(timebase.den))
        }
        return longest > 0 ? longest : nil
    }
}
