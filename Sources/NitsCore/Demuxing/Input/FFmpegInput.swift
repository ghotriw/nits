import CFFmpeg
import Foundation

/// An input FFmpeg opens and demuxes whole (`avformat_open_input`): a file, a network file, a DASH manifest. HLS is
/// `HLSInput`'s (FFmpeg's HLS demuxer is not built). See `DemuxerInput`.
///
/// Its network requests go through `ioBytes` (`FFmpegIOByteCounter`): counted for adaptive bitrate, served by
/// `HTTPSessionTransport` for DASH, and through a `LiveSegmentGate` for a live stream's history.
final class FFmpegInput: DemuxerInput, @unchecked Sendable {
    /// The open context; nil once closed.
    private(set) var context: UnsafeMutablePointer<AVFormatContext>?
    let ioBytes: FFmpegIOByteCounter
    /// Keeps the interrupt FFmpeg's callback points at alive for as long as the context.
    private let interrupt: FFmpegInterrupt
    let traits: DemuxerInputTraits
    let timelineOrigin: Int64
    let isNetworkSource: Bool
    private let isDASH: Bool

    /// Opens `url`; nil when FFmpeg can't (the error is recorded on `interrupt`).
    ///
    /// - Parameters:
    ///   - httpRequestSize: What a network input's HTTP requests ask for (`MediaLoadRequest.httpRequestSize`).
    ///   - liveHistory: A live stream's past as segments: its manifest's segments are asked for through its source, and
    ///     the timeline starts at its origin.
    ///   - onLiveHistoryChange: What the history's gate finds (a head further on, the end of the stream), on the
    ///     reading thread.
    init?(
        url: String, headers: [String: String], httpRequestSize: Int?, interrupt: FFmpegInterrupt,
        liveHistory: LiveHistory?, onLiveHistoryChange: @escaping @Sendable (LiveSegmentGate.Change) -> Void
    ) {
        self.interrupt = interrupt
        let ioBytes = FFmpegIOByteCounter()
        self.ioBytes = ioBytes
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocatedCtx = ctx else { return nil }

        // Setup interrupt callback to abort hung network requests cleanly. `self.interrupt` keeps it alive.
        interrupt.install(on: allocatedCtx)
        ioBytes.install(on: allocatedCtx)
        // The segments of a live stream's history are asked for through the source, and those to come are waited for.
        // What the gate finds (a head further on, the end of the stream) moves the window the engine is told of.
        if let history = liveHistory, let source = history.source {
            ioBytes.liveSegments = LiveSegmentGate(
                source: source,
                head: LiveHead(
                    number: history.headNumber, startTime: history.end - LiveSegmentGate.nominalSegmentDuration),
                onChange: onLiveHistoryChange)
        }
        // Until the opening is done (`finishOpening`, or a failure), the inputs a DASH demuxer opens for the start of
        // each rung of a ladder are not downloaded whole.
        ioBytes.isOpening = true

        var avOptions: OpaquePointer? = nil
        defer {
            if avOptions != nil {
                av_dict_free(&avOptions)
            }
        }

        let isNetworkSource = MediaURL.applySourceOptions(
            &avOptions, path: url, headers: headers, httpRequestSize: httpRequestSize)
        self.isNetworkSource = isNetworkSource
        if MediaURL.isInlineDASHManifest(url) {
            ioBytes.segmentRequestOptions = MediaURL.requestOptions(headers: headers)
        }
        // A DASH demuxer's requests go through `URLSession`, which tells their answers from their transfers and keeps the
        // connections open (`HTTPSessionTransport`, made for the first).
        if isNetworkSource {
            ioBytes.makeTransport = { [interrupt] in
                // The requests too give way to a seek that waits for the input (`yieldIO`), not just FFmpeg's own waits.
                HTTPSessionTransport(source: url, headers: headers) { interrupt.shouldInterruptFFmpeg }
            }
        }
        // A failed opening ends here, as `finishOpening` does.
        var opened = false
        defer {
            if !opened { ioBytes.endOpening() }
        }

        let ret = avformat_open_input(&ctx, url, nil, &avOptions)
        guard ret >= 0, let formatCtx = ctx else {
            let errorMsg = MediaDemuxer.ffmpegErrorDescription(ret)
            interrupt.recordError(code: ret, message: errorMsg)
            AppLog.error(
                .demuxer, "avformat_open_input failed with code \(ret) (\(errorMsg)) for '\(MediaURL.loggable(url))'")
            // Per FFmpeg avformat_open_input contract: user-allocated AVFormatContext is automatically freed on failure.
            return nil
        }

        let streamInfoRet = avformat_find_stream_info(formatCtx, nil)
        guard streamInfoRet >= 0 else {
            let errorMsg = MediaDemuxer.ffmpegErrorDescription(streamInfoRet)
            interrupt.recordError(code: streamInfoRet, message: errorMsg)
            AppLog.error(
                .demuxer,
                "avformat_find_stream_info failed with code \(streamInfoRet) (\(errorMsg)) for '\(MediaURL.loggable(url))'"
            )
            var closable: UnsafeMutablePointer<AVFormatContext>? = formatCtx
            avformat_close_input(&closable)
            return nil
        }
        context = formatCtx
        opened = true

        let formatName = formatCtx.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
        isDASH = formatName == "dash"
        traits = DemuxerInputTraits(
            hasIndex: Self.describesStreams(formatCtx), landsBetweenKeyframes: Self.isUnindexedStream(formatCtx),
            interleavesVariantsByPresentation: isDASH)

        var origin = Self.timelineOrigin(of: formatCtx)
        // The segments of a live stream's past carry the stream's time (hours in): the timeline starts at the first.
        if let liveHistory { origin = Int64((liveHistory.origin * Double(AV_TIME_BASE)).rounded()) }
        timelineOrigin = origin
        if origin != 0 {
            AppLog.info(
                .demuxer,
                "Rebasing timestamps to a zero timeline (start_time \(Double(origin) / Double(AV_TIME_BASE))s)")
        }
    }

    deinit {
        close()
    }

    func close() {
        guard context != nil else { return }
        avformat_close_input(&context)
    }

    func finishOpening() {
        ioBytes.endOpening()
    }

    // MARK: - Description

    var streamingName: String { isDASH ? "DASH" : "FFmpeg" }

    var durationSeconds: Double {
        guard let context, context.pointee.duration > 0 else { return 0 }
        return Double(context.pointee.duration) / Double(AV_TIME_BASE)
    }

    var chapters: [MediaChapter.Raw] {
        context.map(Self.readChapters) ?? []
    }

    var attachedFonts: [AssScript.Font] {
        context.map(EmbeddedSubtitleReader.attachedFonts) ?? []
    }

    var streamCount: Int {
        context?.streamCount ?? 0
    }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>? {
        context?.stream(at: index)
    }

    func title(ofStream index: Int) -> String {
        guard let stream = stream(index), let title = av_dict_get(stream.pointee.metadata, "title", nil, 0) else {
            return ""
        }
        return String(cString: title.pointee.value)
    }

    var network: (any NetworkReadAccount)? { ioBytes }

    // MARK: - Variants and live

    var openingLinkRate: Double? {
        isDASH ? ioBytes.transport?.openingThroughput : nil
    }

    /// The variants of a DASH ladder (`dashVariants`).
    func variantCandidates() -> [MediaDemuxer.VariantCandidate]? {
        guard isDASH, let formatCtx = context else { return nil }
        return Self.dashVariants(in: formatCtx)
    }

    /// The variants of a DASH manifest, when it lists a ladder of pictures: FFmpeg's DASH demuxer has one program and
    /// a stream for each representation, the picture ones with their `bandwidth` as `variant_bitrate`. Every picture is
    /// a variant; the sounds are the manifest's own, the same for all. Nil for a single picture.
    private static func dashVariants(
        in formatCtx: UnsafeMutablePointer<AVFormatContext>
    ) -> [MediaDemuxer.VariantCandidate]? {
        let indexes = 0..<Int(formatCtx.pointee.nb_streams)
        let ofType = { (type: AVMediaType) in
            indexes.filter { formatCtx.pointee.streams[$0]?.pointee.codecpar.pointee.codec_type == type }
        }
        let pictures = ofType(AVMEDIA_TYPE_VIDEO)
        let sounds = ofType(AVMEDIA_TYPE_AUDIO)
        guard pictures.count > 1 else { return nil }
        var found: [MediaDemuxer.VariantCandidate] = []
        for index in pictures {
            guard
                let entry = av_dict_get(formatCtx.pointee.streams[index]?.pointee.metadata, "variant_bitrate", nil, 0),
                let bandwidth = Int(String(cString: entry.pointee.value)), bandwidth > 0
            else { return nil }
            found.append(
                MediaDemuxer.VariantCandidate(
                    id: index, bandwidth: bandwidth,
                    streams: MediaDemuxer.VariantStreams(
                        video: index, audio: sounds, subtitles: [], all: [index] + sounds)))
        }
        return found
    }

    /// FFmpeg's formats have no live window of their own to tell: a DASH stream's history is told by the gate
    /// (`LiveSegmentGate`), and a live playlist is `HLSInput`'s.
    let isLivePlaylist = false

    func liveWindow() -> LiveWindow? { nil }

    // MARK: - Reading

    func read(_ pkt: inout AVPacket) -> Int32 {
        guard let context else { return MediaDemuxer.averrorEOF }
        let ret = av_read_frame(context, &pkt)
        if ret >= 0 { Self.rebase(&pkt, origin: timelineOrigin, in: context) }
        return ret
    }

    /// The Matroska and MP4 seeks clamp a target to the first entry of the searched stream's index. A video cut
    /// between keyframes starts up to a GOP after its audio and subtitles, so a target before its first keyframe
    /// would land there and skip what plays before it. Such a target is searched in the audio stream instead:
    /// Matroska indexes every audio block it reads (the opening scan reads the start of the file), MP4 every sample,
    /// and the MP4 seek then moves the video to its first sample.
    func seek(to target: Int64, flags: Int32, streams: (video: Int, audio: Int)) -> Int32 {
        guard let ctx = context else { return -1 }
        let streamIdx = streams.video >= 0 ? streams.video : streams.audio
        guard let seekStream = stream(streamIdx) else { return -1 }
        let rawTarget = target + Self.timelineOffset(timelineOrigin, in: seekStream.pointee.time_base)
        guard streams.video >= 0, streams.audio >= 0, traits.hasIndex,
            let videoStream = stream(streams.video),
            let audioStream = stream(streams.audio),
            let firstVideo = avformat_index_get_entry(videoStream, 0)?.pointee.timestamp,
            let firstAudio = avformat_index_get_entry(audioStream, 0)?.pointee.timestamp,
            rawTarget < firstVideo,
            av_rescale_q(firstAudio, audioStream.pointee.time_base, videoStream.pointee.time_base) < firstVideo
        else {
            return av_seek_frame(ctx, Int32(streamIdx), rawTarget, flags)
        }
        let audioTarget = av_rescale_q(rawTarget, videoStream.pointee.time_base, audioStream.pointee.time_base)
        return av_seek_frame(ctx, Int32(streams.audio), audioTarget, flags)
    }

    func seek(stream index: Int, to target: Int64, flags: Int32) -> Int32 {
        guard let ctx = context, let seekStream = stream(index) else { return -1 }
        let rawTarget = target + Self.timelineOffset(timelineOrigin, in: seekStream.pointee.time_base)
        return av_seek_frame(ctx, Int32(index), rawTarget, flags)
    }

    /// Rewinds MPEG-TS / MPEG-PS to their first packet. A timestamp seek bisects and can land past it, dropping the
    /// keyframe that starts the file, so they rewind to their first byte. A format that can't seek by byte
    /// (`AVFMT_NO_BYTE_SEEK`) rewinds by timestamp.
    func rewind() {
        guard let ctx = context else { return }
        if let iformat = ctx.pointee.iformat, (iformat.pointee.flags & AVFMT_NO_BYTE_SEEK) != 0 {
            _ = av_seek_frame(ctx, -1, timelineOrigin - Int64(AV_TIME_BASE), AVSEEK_FLAG_BACKWARD)
        } else {
            _ = avformat_seek_file(ctx, -1, Int64.min, 0, 0, AVSEEK_FLAG_BYTE)
        }
    }

    func setReading(_ isRead: Bool, stream index: Int) {
        stream(index)?.pointee.discard = isRead ? AVDISCARD_DEFAULT : AVDISCARD_ALL
    }

    /// Whether stream `index` is read (tests).
    func isReading(stream index: Int) -> Bool {
        stream(index).map { $0.pointee.discard != AVDISCARD_ALL } ?? false
    }

    /// FFmpeg's DASH demuxer opens every representation of a ladder, and closes those discarded only when it reads a
    /// packet (`recheck_discard_flags`): a seek before the first read goes through all of them, each one reading its
    /// file up to the target when it has no index it can use (a single file: 19 s for a ladder of 7, 7 s once the
    /// others are closed). One packet read first, dropped by the seek, closes them.
    func closeUnusedRepresentations() {
        guard isDASH, let ctx = context else { return }
        var pkt = AVPacket()
        // A packet the probing of the streams left is handed out first, with no word to the DASH demuxer: dropped,
        // as the seek does.
        avformat_flush(ctx)
        if av_read_frame(ctx, &pkt) >= 0 { av_packet_unref(&pkt) }
    }

    /// FFmpeg's DASH demuxer, once a stream was read to its end, closes its input and sets the stream to
    /// `AVDISCARD_ALL`, so that it stays closed: a seek back moves its segment number, but nothing opens the input
    /// again, and the stream reads nothing. The streams playing are enabled again before the seek.
    func prepareSeek(reading indices: [Int]) {
        guard isDASH else { return }
        for index in indices where index >= 0 {
            setReading(true, stream: index)
        }
    }

    // MARK: - FFmpeg's formats

    /// MPEG-TS / MPEG-PS: no index, and timestamps that continue the source clock. Seeking there bisects on
    /// timestamps and lands on whichever packet is nearest, not on a keyframe.
    /// Matroska and MP4: their header describes every stream (codec, parameters, time base) and their index comes from
    /// the file (Cues, the sample table), with a timeline that starts at zero.
    static func describesStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        guard let iformat = ctx.pointee.iformat else { return false }
        let name = String(cString: iformat.pointee.name)
        return name.hasPrefix("matroska") || name.hasPrefix("mov")
    }

    package static func isUnindexedStream(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        guard let iformat = ctx.pointee.iformat else { return false }
        return (iformat.pointee.flags & AVFMT_TS_DISCONT) != 0
    }

    /// Start of the playback timeline in `AV_TIME_BASE` units. MPEG-TS / MPEG-PS timestamps continue the
    /// source's clock (a DVD starts around 0.5 s, a broadcast capture hours in), so their first timestamp
    /// becomes zero. Other containers already start near zero (or slightly before, via edit lists) and
    /// are left as they are; a negative start (MPEG-PS, FLV, Ogg, ...) is kept as it was.
    package static func timelineOrigin(of ctx: UnsafeMutablePointer<AVFormatContext>) -> Int64 {
        guard isUnindexedStream(ctx), ctx.pointee.start_time != Int64.min else { return 0 }
        if ctx.pointee.start_time > 0 { return ctx.pointee.start_time }
        return 0
    }

    /// Whether `ctx` was opened by FFmpeg's `tty` demuxer (ANSI art): it takes `.txt` by its extension and accepts any
    /// small text, so a playlist under that name opens as one instead of failing (`HLSInput.sniffsAsPlaylist`).
    static func isTextFormat(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        guard let name = ctx.pointee.iformat?.pointee.name else { return false }
        return String(cString: name) == "tty"
    }

    /// Whether the input was opened as a text format (`isTextFormat`).
    var isTextFormat: Bool { context.map(Self.isTextFormat) ?? false }

    /// `origin` (`AV_TIME_BASE` units) in the time base of `stream`.
    package static func timelineOffset(_ origin: Int64, in timebase: AVRational) -> Int64 {
        guard origin != 0, timebase.num > 0, timebase.den > 0 else { return 0 }
        return av_rescale_q(origin, AVRational(num: 1, den: AV_TIME_BASE), timebase)
    }

    /// Moves a packet's timestamps onto the zero-based timeline (see `timelineOrigin(of:)`).
    package static func rebase(
        _ pkt: inout AVPacket, origin: Int64, in ctx: UnsafeMutablePointer<AVFormatContext>
    ) {
        guard origin != 0, pkt.stream_index >= 0, pkt.stream_index < Int32(ctx.pointee.nb_streams),
            let stream = ctx.pointee.streams[Int(pkt.stream_index)]
        else { return }
        let offset = timelineOffset(origin, in: stream.pointee.time_base)
        if pkt.pts != Int64.min { pkt.pts -= offset }
        if pkt.dts != Int64.min { pkt.dts -= offset }
    }

    /// Container chapters as FFmpeg exports them (MKV default edition, flattened; MP4 chapter track or
    /// Nero `chpl`). Chapters without a start are skipped; an unset end stays `nil`.
    static func readChapters(from formatCtx: UnsafeMutablePointer<AVFormatContext>) -> [MediaChapter.Raw] {
        let count = Int(formatCtx.pointee.nb_chapters)
        guard count > 0, let list = formatCtx.pointee.chapters else { return [] }
        let noPTS = Int64.min  // AV_NOPTS_VALUE
        return (0..<count).compactMap { index in
            guard let chapter = list[index]?.pointee, chapter.start != noPTS,
                chapter.time_base.num > 0, chapter.time_base.den > 0
            else { return nil }
            let num = Double(chapter.time_base.num)
            let den = Double(chapter.time_base.den)
            let title = av_dict_get(chapter.metadata, "title", nil, 0).map { String(cString: $0.pointee.value) }
            return MediaChapter.Raw(
                title: title,
                start: Double(chapter.start) * num / den,
                end: chapter.end != noPTS && chapter.end > chapter.start ? Double(chapter.end) * num / den : nil
            )
        }
    }
}

extension FFmpegIOByteCounter: NetworkReadAccount {
    var transferMeter: NetworkTransferMeter? { transport?.meter }
}
