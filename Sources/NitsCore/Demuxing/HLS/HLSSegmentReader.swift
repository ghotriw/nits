import CFFmpeg
import Foundation

enum HLSSegmentReaderError: Error, Equatable {
    case load(HLSSegmentLoadError)
    /// FFmpeg couldn't open or probe the segments' container (its error code).
    case open(Int32)
}

/// Demuxes a rendition's segments with FFmpeg's container demuxers (`mpegts`, `mov`, `aac`, `ac3`, `eac3`, `mp3`,
/// `webvtt`), on the playlist's timeline: what FFmpeg's `hls.c` and its patch (`ffmpeg-hls-timeline.patch`) do, and
/// nothing of the playlist's.
///
/// A reader is one **run**: the segments that follow each other in the same encoding (the same init section, no
/// discontinuity). Their bytes, the init section's first, are one stream to the container demuxer, which gets the next
/// segment as it comes to the end of the one it reads (`next`, which may wait: at a live stream's edge). The caller
/// ends the run (`next` returns nil) at a discontinuity or a change of init section, and opens another reader there;
/// a seek is a new reader too: no `av_seek_frame`.
///
/// **Timeline.** `timelineOffset` moves the media's own timestamps onto the playlist's: the run's first segment starts
/// at `start`, where the first picture's presentation time (else the first stream's) was, so one offset covers the run
/// and the timestamps drift only as much as the encoder's clock does. It is a rendition's own offset for audio and
/// video, which a segment's timestamps place; a WebVTT rendition has none of its own, and takes the shift of the media
/// it goes with (`timelineShift`). Timestamps that wrap (MPEG-TS) are unwrapped.
///
/// **WebVTT** segments are files with a header of their own (`X-TIMESTAMP-MAP`): each is opened as a context of its
/// own, and its cues put on the media's clock by the map, then on the timeline by `timelineShift`. The `streams`
/// of such a reader belong to the context being read: copy what's needed from them before reading on.
///
/// Not thread-safe: one thread reads, and closes.
final class HLSSegmentReader {
    private let loader: HLSSegmentLoader
    private let next: () -> HLSSegment?
    private let start: Double
    private let timelineShift: Double?
    /// The segments of a WebVTT run are read one context each.
    let isSegmentwise: Bool

    private var context: UnsafeMutablePointer<AVFormatContext>?
    private var io: SegmentIO?
    private var feed: SegmentFeed?
    /// Seconds to add to the media's timestamps for the timeline. Known once the run's first packet is read (or
    /// at the open, from the streams' start times).
    private(set) var timelineOffset: Double?
    private var unwrappers: [Int: TimestampUnwrapper] = [:]
    private var shifts: [Int: Int64] = [:]
    /// The segment's own shift of a WebVTT context, in seconds.
    private var segmentShift: Double = 0
    /// Why the run's bytes ended early, if they did (a segment that failed to load): `read` returns an error for it,
    /// not the end of the stream.
    private(set) var failure: HLSSegmentLoadError?
    /// `next` returned nil: it isn't asked again, as it would hand the next run's first segment to this one.
    private var isEnded = false

    /// Opens the run at `first`, which `start` seconds on the timeline. Waits for the first segment (and its init
    /// section): the caller's thread.
    init(
        loader: HLSSegmentLoader, first: HLSSegment, start: Double, timelineShift: Double? = nil,
        next: @escaping () -> HLSSegment?
    ) throws(HLSSegmentReaderError) {
        self.loader = loader
        self.start = start
        self.timelineShift = timelineShift
        self.next = next
        var head = Data()
        let data: Data
        do throws(HLSSegmentLoadError) {
            if let section = first.initSection { head = try loader.initSection(section) }
            data = try loader.segment(first)
        } catch {
            throw .load(error)
        }
        isSegmentwise =
            Self.isWebVTT(data)
            || (data.trimmedIsEmpty && ["vtt", "webvtt"].contains(first.url.pathExtension.lowercased()))
        if isSegmentwise {
            do { try openSegmentContext(data) } catch {
                close()
                throw error
            }
        } else {
            head.append(data)
            do { try openContinuousContext(head) } catch {
                close()
                throw error
            }
        }
    }

    deinit { close() }

    /// The streams of the open context (all of the segments').
    var streams: [UnsafeMutablePointer<AVStream>] {
        guard let context else { return [] }
        return (0..<Int(context.pointee.nb_streams)).compactMap { context.pointee.streams[$0] }
    }

    /// The next packet, its timestamps on the timeline; FFmpeg's `av_read_frame` result: `AVERROR_EOF` at the end of
    /// the run, the load's error (`failure`) when a segment failed.
    func read(_ packet: inout AVPacket) -> Int32 {
        while true {
            if context == nil {
                // A WebVTT run between two segments (or at an empty one): the next that has cues.
                guard isSegmentwise, failure == nil, !isEnded else { return endCode }
                if let code = advanceSegment() { return code }
                continue
            }
            let result = av_read_frame(context!, &packet)
            if result >= 0 {
                place(&packet)
                return result
            }
            guard result == MediaDemuxer.averrorEOF, isSegmentwise, failure == nil else {
                return result == MediaDemuxer.averrorEOF ? endCode : result
            }
            closeContext()
        }
    }

    /// Loads the next WebVTT segment and opens it, unless it is empty (a stretch without cues): nil, or what `read`
    /// returns when there is none.
    private func advanceSegment() -> Int32? {
        guard let segment = next() else {
            isEnded = true
            return MediaDemuxer.averrorEOF
        }
        do {
            try openSegmentContext(try loader.segment(segment))
            return nil
        } catch let error as HLSSegmentLoadError {
            failure = error
        } catch let error as HLSSegmentReaderError {
            switch error {
            case .load(let load): failure = load
            case .open(let code): failure = .failed(code)
            }
        } catch {
            failure = .failed(-EIO)
        }
        return endCode
    }

    private func closeContext() {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&ctx)
        context = nil
    }

    func close() {
        closeContext()
        io?.free()
        io = nil
        feed = nil
    }

    /// What reading returns at the end of the bytes: the end of the stream, or the error of the load that ended them.
    private var endCode: Int32 {
        failure.map(Self.code(for:)) ?? MediaDemuxer.averrorEOF
    }

    static func code(for error: HLSSegmentLoadError) -> Int32 {
        switch error {
        case .interrupted: HTTPSessionInput.averrorExit
        case .failed(let code): code
        default: -EIO
        }
    }

    // MARK: Opening

    private static func isWebVTT(_ data: Data) -> Bool {
        var prefix = data.prefix(8)
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) { prefix = data.dropFirst(3).prefix(6) }
        return prefix.starts(with: Array("WEBVTT".utf8))
    }

    /// One context over the init section and the segments, the first given; the others pulled from `next`.
    private func openContinuousContext(_ head: Data) throws(HLSSegmentReaderError) {
        let feed = SegmentFeed(head: head) { [loader, next, weak self] in
            guard let segment = next() else { return .end }
            do throws(HLSSegmentLoadError) {
                return .data(try loader.segment(segment))
            } catch {
                self?.failure = error
                return .failed(Self.code(for: error))
            }
        }
        self.feed = feed
        try openContext(over: feed)
        timelineOffset = openedOffset()
    }

    /// A context over one WebVTT segment.
    private func openSegmentContext(_ data: Data) throws(HLSSegmentReaderError) {
        closeContext()
        io?.free()
        io = nil
        // A rendition with nothing to show for a stretch serves an empty file.
        guard !data.trimmedIsEmpty else { return }
        let map = HLSTimestampMap.parse(webVTT: data) ?? HLSTimestampMap()
        // The map's MPEG-TS time wraps as the media's does: read it as the value nearest where the run is.
        let expected = Int64((start - (timelineShift ?? 0)) * 90_000)
        let wrap = Int64(1) << 33
        var mpegts = map.mpegts
        mpegts += wrap * Int64((Double(expected - mpegts) / Double(wrap)).rounded())
        let shift = Double(mpegts) / 90_000 - map.local
        segmentShift = shift + (timelineShift ?? 0)
        timelineOffset = timelineShift ?? 0
        let feed = SegmentFeed(head: data) { .end }
        self.feed = feed
        try openContext(over: feed)
    }

    private func openContext(over feed: SegmentFeed) throws(HLSSegmentReaderError) {
        guard let io = SegmentIO(source: feed) else { throw .open(-ENOMEM) }
        self.io = io
        guard let allocated = avformat_alloc_context() else { throw .open(-ENOMEM) }
        allocated.pointee.pb = io.context
        allocated.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        var opened: UnsafeMutablePointer<AVFormatContext>? = allocated
        var result = avformat_open_input(&opened, nil, nil, nil)
        guard result >= 0 else {
            // A context that failed to open is freed by FFmpeg.
            throw .open(failure.map(Self.code(for:)) ?? result)
        }
        guard let ctx = opened else { throw .open(-ENOMEM) }
        // As `hls.c` bounds its own probing: a few seconds of media, read across the segments as they come (an end
        // of input faked at the first segment would stay: `mov` ends for good at one).
        ctx.pointee.max_analyze_duration = 4 * Int64(AV_TIME_BASE)
        result = avformat_find_stream_info(ctx, nil)
        guard result >= 0 else {
            avformat_close_input(&opened)
            throw .open(failure.map(Self.code(for:)) ?? result)
        }
        context = ctx
        unwrappers = [:]
        shifts = [:]
        for stream in streams {
            let index = Int(stream.pointee.index)
            if let unwrapper = TimestampUnwrapper(bits: stream.pointee.pts_wrap_bits) {
                unwrappers[index] = unwrapper
            }
        }
    }

    // MARK: Timeline

    /// The offset for the timeline from what the open found: the first picture's start (else the first stream with one).
    private func openedOffset() -> Double? {
        let candidates = streams.filter { $0.pointee.start_time != Int64.min }
        let isPicture: (UnsafeMutablePointer<AVStream>) -> Bool = {
            $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                && $0.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0
        }
        guard let stream = candidates.first(where: isPicture) ?? candidates.first else { return nil }
        return start - Self.seconds(stream.pointee.start_time, stream.pointee.time_base)
    }

    private static func seconds(_ ticks: Int64, _ base: AVRational) -> Double {
        Double(ticks) * Double(base.num) / Double(base.den)
    }

    /// Puts a packet on the timeline.
    private func place(_ packet: inout AVPacket) {
        guard let context, packet.stream_index >= 0, Int(packet.stream_index) < Int(context.pointee.nb_streams),
            let stream = context.pointee.streams[Int(packet.stream_index)]
        else { return }
        let index = Int(packet.stream_index)
        if var unwrapper = unwrappers[index] {
            let placed = unwrapper.unwrap(
                pts: packet.pts == Int64.min ? nil : packet.pts, dts: packet.dts == Int64.min ? nil : packet.dts)
            unwrappers[index] = unwrapper
            packet.pts = placed.pts ?? Int64.min
            packet.dts = placed.dts ?? Int64.min
        }
        if timelineOffset == nil {
            // Nothing told a start time: the first packet's.
            if let ticks = packet.pts != Int64.min ? packet.pts : (packet.dts != Int64.min ? packet.dts : nil) {
                timelineOffset = start - Self.seconds(ticks, stream.pointee.time_base)
            }
        }
        let seconds = isSegmentwise ? segmentShift : (timelineOffset ?? 0)
        let shift: Int64
        if let cached = shifts[index] {
            shift = cached
        } else {
            let base = stream.pointee.time_base
            let ticks = (seconds * Double(base.den) / Double(base.num)).rounded()
            shift = ticks.isFinite && abs(ticks) < 1e15 ? Int64(ticks) : 0
            // A WebVTT context's shift changes with the segment: not kept.
            if !isSegmentwise, timelineOffset != nil { shifts[index] = shift }
        }
        if packet.pts != Int64.min { packet.pts = packet.pts &+ shift }
        if packet.dts != Int64.min { packet.dts = packet.dts &+ shift }
    }
}

// MARK: - Bytes

/// The bytes a run's context reads: a head (the init section and the first segment), then each segment as it is
/// asked for.
private final class SegmentFeed: FFmpegInputSource {
    enum Chunk {
        case data(Data)
        case end
        /// FFmpeg's error for a load that failed.
        case failed(Int32)
    }

    private var chunk: Data
    private var position = 0
    private var ended = false
    private let provider: () -> Chunk

    init(head: Data, provider: @escaping () -> Chunk) {
        chunk = head
        self.provider = provider
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, _ size: Int32) -> Int32 {
        while position >= chunk.count {
            if ended { return MediaDemuxer.averrorEOF }
            switch provider() {
            case .data(let data):
                chunk = data
                position = 0
            case .end:
                ended = true
                return MediaDemuxer.averrorEOF
            case .failed(let code):
                ended = true
                return code
            }
        }
        let count = min(Int(size), chunk.count - position)
        chunk.withUnsafeBytes { source in
            buffer.update(
                from: source.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: position), count: count)
        }
        position += count
        return Int32(count)
    }

    func seek(_ offset: Int64, _ whence: Int32) -> Int64 { Int64(-ENOSYS) }

    func close() {}
}

/// An `AVIOContext` that reads a `SegmentFeed`, which its opaque holds retained until `free`: FFmpeg's C callbacks have
/// no other way to reach it (see "API choices" in AGENTS.md).
private final class SegmentIO {
    let context: UnsafeMutablePointer<AVIOContext>
    private var box: Unmanaged<Box>?

    private final class Box {
        let source: any FFmpegInputSource
        init(_ source: any FFmpegInputSource) { self.source = source }
    }

    init?(source: any FFmpegInputSource) {
        let size: Int32 = 32 << 10
        guard let buffer = av_malloc(Int(size))?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let box = Unmanaged.passRetained(Box(source))
        guard
            let context = avio_alloc_context(
                buffer, size, 0, box.toOpaque(),
                { opaque, buffer, size in
                    guard let opaque, let buffer else { return -1 }
                    return Unmanaged<Box>.fromOpaque(opaque).takeUnretainedValue().source.read(buffer, size)
                }, nil, nil)
        else {
            box.release()
            av_free(buffer)
            return nil
        }
        self.context = context
        self.box = box
    }

    func free() {
        guard let box else { return }
        self.box = nil
        // FFmpeg may have replaced the buffer (probing grows it): the context's own is the one to free.
        av_freep(&context.pointee.buffer)
        var pointer: UnsafeMutablePointer<AVIOContext>? = context
        avio_context_free(&pointer)
        box.release()
    }
}

extension Data {
    /// No bytes but whitespace.
    fileprivate var trimmedIsEmpty: Bool {
        allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
    }
}
