import CFFmpeg
import Foundation

/// What `ThumbnailGenerator` reads the packets of one video stream from, and seeks in: a context FFmpeg opens on the
/// file, or Nits' own HLS client for a finished HLS stream (`HLSInput`: the playlists are no file FFmpeg could open).
/// Timestamps are the container's own; `timelineOffset` is what a zero-based timeline lacks of them, in the stream's
/// time base (MPEG-TS / MPEG-PS start wherever the source clock was).
final class ThumbnailSource {
    let stream: UnsafeMutablePointer<AVStream>
    let streamIndex: Int32
    /// The container's length in seconds, 0 when it tells none.
    let containerDuration: Double
    let sampleAspect: AVRational
    let timelineOrigin: Int64
    let timelineOffset: Int64
    /// FFmpeg opened it as text (`tty`): it may be a playlist under a name that tells none.
    private(set) var isTextFormat = false

    private let readPacket: (UnsafeMutablePointer<AVPacket>) -> Int32
    private let seekToSeconds: (Double) -> Void
    private let seekToStart: () -> Void
    private let closeSource: () -> Void

    private init(
        stream: UnsafeMutablePointer<AVStream>, streamIndex: Int32, containerDuration: Double,
        sampleAspect: AVRational, timelineOrigin: Int64, timelineOffset: Int64,
        read: @escaping (UnsafeMutablePointer<AVPacket>) -> Int32, seek: @escaping (Double) -> Void,
        seekToStart: @escaping () -> Void, close: @escaping () -> Void
    ) {
        self.stream = stream
        self.streamIndex = streamIndex
        self.containerDuration = containerDuration
        self.sampleAspect = sampleAspect
        self.timelineOrigin = timelineOrigin
        self.timelineOffset = timelineOffset
        readPacket = read
        seekToSeconds = seek
        self.seekToStart = seekToStart
        closeSource = close
    }

    func read(_ packet: UnsafeMutablePointer<AVPacket>) -> Int32 { readPacket(packet) }
    /// Back to the keyframe at or before `seconds` on the zero-based timeline.
    func seek(toSeconds seconds: Double) { seekToSeconds(seconds) }
    func seekToBeginning() { seekToStart() }
    func close() { closeSource() }

    // MARK: FFmpeg

    /// Opens `path` with FFmpeg and takes its best video stream. Nil (logged) when it can't.
    static func openFFmpeg(
        path: String, headers: [String: String], httpRequestSize: Int?, interrupt: FFmpegInterrupt,
        failureCode: inout Int32
    ) -> ThumbnailSource? {
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let fmtCtx = formatCtx else { return nil }
        // `interrupt` is owned by the generator, which outlives the context closed with the source.
        interrupt.install(on: fmtCtx)

        var avOptions: OpaquePointer? = nil
        defer { if avOptions != nil { av_dict_free(&avOptions) } }
        if MediaURL.isNetworkURL(path) {
            MediaURL.applyNetworkOptions(&avOptions, headers: headers, httpRequestSize: httpRequestSize)
        }
        let cleanPath = MediaURL.normalizeMediaPath(path)

        var ret = avformat_open_input(&formatCtx, cleanPath, nil, &avOptions)
        guard ret >= 0, let context = formatCtx else {
            failureCode = ret
            AppLog.error(
                .engine,
                "ThumbnailGenerator: avformat_open_input failed with code \(ret) "
                    + "(\(MediaDemuxer.ffmpegErrorDescription(ret))) for '\(cleanPath)'")
            return nil
        }
        func closeContext() {
            var temporary: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&temporary)
        }
        guard !interrupt.isCancelled else {
            closeContext()
            return nil
        }
        ret = avformat_find_stream_info(context, nil)
        guard ret >= 0 else {
            AppLog.error(
                .engine,
                "ThumbnailGenerator: avformat_find_stream_info failed with code \(ret) "
                    + "(\(MediaDemuxer.ffmpegErrorDescription(ret)))")
            closeContext()
            return nil
        }
        let index = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let stream = context.pointee.streams[Int(index)] else {
            AppLog.error(.engine, "ThumbnailGenerator: No video stream found in '\(cleanPath)'")
            closeContext()
            return nil
        }
        let timebase = stream.pointee.time_base
        let origin = FFmpegInput.timelineOrigin(of: context)
        let containerDuration =
            context.pointee.duration > 0 ? Double(context.pointee.duration) / Double(AV_TIME_BASE) : 0
        let source = ThumbnailSource(
            stream: stream, streamIndex: index, containerDuration: containerDuration,
            sampleAspect: av_guess_sample_aspect_ratio(context, stream, nil), timelineOrigin: origin,
            timelineOffset: FFmpegInput.timelineOffset(origin, in: timebase),
            read: { av_read_frame(context, $0) },
            seek: { seconds in
                guard timebase.den > 0 else { return }
                let offset = FFmpegInput.timelineOffset(origin, in: timebase)
                let targetPts = Int64(round(seconds * Double(timebase.den) / Double(timebase.num))) + offset
                // Seek backward to keyframe (try stream-level seek first, then format-level)
                if av_seek_frame(context, index, targetPts, AVSEEK_FLAG_BACKWARD) < 0 {
                    let targetAV = Int64(round(seconds * Double(AV_TIME_BASE))) + origin
                    _ = av_seek_frame(context, -1, targetAV, AVSEEK_FLAG_BACKWARD)
                }
            },
            seekToStart: { _ = av_seek_frame(context, -1, 0, AVSEEK_FLAG_BACKWARD) },
            close: closeContext)
        source.isTextFormat = FFmpegInput.isTextFormat(context)
        return source
    }

    // MARK: HLS

    /// Opens the finished HLS stream at `url` through the client, on its cheapest variant with a picture: thumbnails are
    /// small, and a lane nothing reads downloads nothing. Nil for a live stream (no timeline to sample) or one that doesn't open.
    static func openHLS(url: String, headers: [String: String], interrupt: FFmpegInterrupt) -> ThumbnailSource? {
        guard let input = HLSInput(url: url, headers: headers, interrupt: interrupt), !input.isLivePlaylist else {
            return nil
        }
        let withPicture = (input.variantCandidates()?.filter { $0.streams.video != nil } ?? [])
            .sorted { $0.bandwidth < $1.bandwidth }
        // The cheapest rung that is described. One described as another (`DemuxerInput.variantDescription`) is described
        // by its first read, before the decoder is made from its stream: read once, then back to the start (which replays
        // what was read). One whose read fails or finds other streams gives way to the next cheapest.
        var chosen: MediaDemuxer.VariantCandidate?
        for candidate in withPicture {
            guard let video = candidate.streams.video else { continue }
            if input.variantDescription(id: candidate.id) == .pending {
                for index in 0..<input.streamCount { input.setReading(index == video, stream: index) }
                var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
                if let packet { _ = input.read(&packet.pointee) }
                av_packet_free(&packet)
                input.rewind()
            }
            if input.variantDescription(id: candidate.id) == .described {
                input.setReading(true, stream: video)
                chosen = candidate
                break
            }
            input.setReading(false, stream: video)
        }
        let picture =
            chosen?.streams.video
            ?? (0..<input.streamCount).first {
                input.stream($0)?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
            }
        guard let picture, let stream = input.stream(picture) else {
            input.close()
            return nil
        }
        for index in 0..<input.streamCount { input.setReading(index == picture, stream: index) }
        let timebase = stream.pointee.time_base
        return ThumbnailSource(
            stream: stream, streamIndex: Int32(picture), containerDuration: input.durationSeconds,
            sampleAspect: stream.pointee.codecpar.pointee.sample_aspect_ratio, timelineOrigin: 0, timelineOffset: 0,
            read: { input.read(&$0.pointee) },
            seek: { seconds in
                guard timebase.den > 0 else { return }
                let target = Int64(round(seconds * Double(timebase.den) / Double(timebase.num)))
                _ = input.seek(stream: picture, to: target, flags: AVSEEK_FLAG_BACKWARD)
            },
            seekToStart: { input.rewind() },
            close: { input.close() })
    }
}
