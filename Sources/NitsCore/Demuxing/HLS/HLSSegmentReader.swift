import CFFmpeg
import Foundation

enum HLSSegmentReaderError: Error, Equatable {
    case load(HLSSegmentLoadError)
    /// FFmpeg couldn't open or probe the segments' container (its error code).
    case open(Int32)

    /// FFmpeg's error code for it.
    var code: Int32 {
        switch self {
        case .load(let load): HLSSegmentReader.code(for: load)
        case .open(let code): code
        }
    }
}

/// Demuxes a rendition's segments with FFmpeg's container demuxers (`mpegts`, `mov`, `aac`, `ac3`, `eac3`, `mp3`,
/// `webvtt`), on the playlist's timeline, and nothing of the playlist's.
///
/// A reader is one **run**: the segments that follow each other in the same encoding (the same init section, no
/// discontinuity). Their bytes, the init section's first, are one stream to the container demuxer, which gets the next
/// segment as it comes to the end of the one it reads (`next`, which may wait: at a live stream's edge). The caller
/// ends the run (`next` returns nil) at a discontinuity or a change of init section, and opens another reader there;
/// a seek is a new reader too: no `av_seek_frame`.
///
/// **Timeline.** `timelineOffset` moves the media's own timestamps onto the playlist's. A reader with `anchoring` takes
/// the offset its stream's lanes share for the run's discontinuity sequence (`HLSTimestampAnchors`), or anchors it; one
/// without (a probe, a thumbnail, a test) anchors itself. Anchoring puts the run's first segment at `start`, where the
/// first picture's presentation time (else the first stream's) was. One offset covers the run, so the timestamps drift
/// only as much as the encoder's clock does. A WebVTT rendition has no timestamps of its own, and takes the offset of
/// the media it goes with in the segment's sequence (`timelineShift`). Timestamps that wrap (MPEG-TS) are unwrapped,
/// nearest where the playlist puts them.
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
    private let timelineShift: ((Int) -> Double?)?
    private let anchoring: Anchoring?
    /// The reorder depth of the run's picture when the caller has its streams described already (`openContext`).
    private let knownVideoDelay: Int?
    /// The segments of a WebVTT run are read one context each.
    let isSegmentwise: Bool

    /// The offsets a reader shares with the stream's other runs: `anchors`' for the run's discontinuity `sequence`,
    /// taken when they put its first packet within `tolerance` seconds of where the playlist does, as the reader's
    /// `role` may (`HLSTimestampAnchors.Role`).
    struct Anchoring {
        let anchors: HLSTimestampAnchors
        let sequence: Int
        let tolerance: Double
        let role: HLSTimestampAnchors.Role
        /// Told where the media puts each segment of the run: its sequence, and the time of its first picture (else its
        /// first stream's sound) on the timeline (`HLSTimeline.measure`). Not for a run that has no timestamps of its own.
        var onSegmentStart: ((HLSSegment, Double) -> Void)?
    }

    /// Container formats of elementary audio (packed audio), whose timestamps are counted from the run's first sample:
    /// their time is the first segment's ID3 `PRIV` (`packedTimestamp`).
    private static let packedFormats: Set<String> = ["aac", "ac3", "eac3", "mp3"]
    /// The `PRIV` timestamp of the run's first segment (90 kHz), when it starts with an ID3 tag that has one.
    private var packedTimestamp: Int64?
    /// The init section's length and the run's first segment, where `segmentStarts` begins.
    private var initBytes: Int64 = 0
    private var firstSegment: HLSSegment?

    private var context: UnsafeMutablePointer<AVFormatContext>?
    private var io: SegmentIO?
    private var feed: SegmentFeed?
    /// The segment being read of a continuous run, as it comes (`nextChunk`).
    private var body: HLSSegmentBody?
    /// The body of the run's first segment, which a lane may keep (`claimFirstBody`) to replay it.
    private var retainedFirst: HLSSegmentBody?
    private var isFirstClaimed = false
    /// Seconds to add to the media's timestamps for the timeline. Known once the run's first packet is read (or
    /// at the open, from the streams' start times).
    private(set) var timelineOffset: Double?
    private var unwrappers: [Int: TimestampUnwrapper] = [:]
    private var shifts: [Int: Int64] = [:]
    /// Where each segment's bytes start in what the context has read (init section and segments as one stream), for the
    /// segments whose packets may still come: a packet's `pos` says which it is from (`noteSegmentStart`).
    private var segmentStarts: [(offset: Int64, segment: HLSSegment, number: Int)] = []
    /// Bytes handed to the context so far.
    private var delivered: Int64 = 0
    /// The number (place in the run) of the last segment that told where it starts.
    private var toldThrough = -1
    private var segmentsStarted = 0
    /// The stream whose packets tell where a segment starts: the first picture, else the first stream.
    private var referenceStream: Int?
    /// Whether the run's segments tell where they start: not for packed audio without a `PRIV` (placed by its playlist).
    private var reportsStarts = true
    /// The first segment's start on the timeline by the streams' start times, from the open.
    private var openedStart: Double?
    /// The segment's own shift of a WebVTT context, in seconds.
    private var segmentShift: Double = 0
    /// Why the run's bytes ended early, if they did (a segment that failed to load): `read` returns an error for it,
    /// not the end of the stream.
    private(set) var failure: HLSSegmentLoadError?
    /// `next` returned nil: it isn't asked again, as it would hand the next run's first segment to this one.
    private var isEnded = false
    /// The segment being read (`body`) has handed out bytes: a failure of it ends the run inside a packet.
    private var bodyHasBytes = false

    /// How long the opening of the run took, by step (`HLSOpeningMeasure`): the measurement suites read it from the log.
    struct OpenTiming {
        /// Loading the init section, when the run has one.
        var initSection: Duration?
        /// Until the first segment's first bytes came (the init section included).
        var answer: Duration = .zero
        /// `avformat_open_input`: the container probed.
        var open: Duration = .zero
        /// `avformat_find_stream_info`: the streams analysed, which reads on into the media.
        var analyze: Duration = .zero
        /// Bytes handed to the container demuxer once the streams were analysed (the init section's included).
        var bytes: Int64 = 0

        var description: String {
            let ms = HLSOpeningMeasure.ms
            let steps = "answer=\(ms(answer)) open=\(ms(open)) analyze=\(ms(analyze)) bytes=\(bytes)"
            guard let initSection else { return steps }
            return "init=\(ms(initSection)) " + steps
        }
    }
    private(set) var openTiming = OpenTiming()

    /// Opens the run at `first`, which `start` seconds on the timeline. Waits for the first segment (and its init
    /// section): the caller's thread. A probe (`isProbe`) reads `first` only as far as FFmpeg's analysis goes, to
    /// describe the streams (`HLSLane.probe`): the run is not meant to be read on. `timelineShift` gives a WebVTT
    /// segment's offset by its discontinuity sequence. `knownVideoDelay`: the caller has the streams described already
    /// (a lane past its probe), and their picture's reorder depth (`video_delay`, 0 without a picture): the analysis
    /// only finds where the run starts (`openContext`). `onAnswer` is told once the first segment's first bytes came (its init
    /// section's before them): the server answers, whatever the analysis then takes.
    init(
        loader: HLSSegmentLoader, first: HLSSegment, start: Double, timelineShift: ((Int) -> Double?)? = nil,
        anchoring: Anchoring? = nil, isProbe: Bool = false, knownVideoDelay: Int? = nil,
        firstBody: HLSSegmentBody? = nil, onAnswer: (() -> Void)? = nil,
        next: @escaping () -> HLSSegment?
    ) throws(HLSSegmentReaderError) {
        self.loader = loader
        self.start = start
        self.knownVideoDelay = knownVideoDelay
        self.timelineShift = timelineShift
        self.anchoring = anchoring
        self.next = next
        var head = Data()
        var data = Data()
        var opened: HLSSegmentBody?
        let began = ContinuousClock.now
        do throws(HLSSegmentLoadError) {
            if let section = first.initSection {
                head = try loader.initSection(section)
                openTiming.initSection = ContinuousClock.now - began
            }
            // The segment's first bytes, as they come: enough to tell what it is.
            let body: HLSSegmentBody
            if let firstBody {
                body = firstBody
            } else {
                body = try loader.segmentBody(first, whileOpening: isProbe, retains: !isProbe)
            }
            opened = body
            retainedFirst = body
            while data.count < 16, let chunk = try body.next() { data.append(chunk) }
            // Packed audio starts with an ID3 tag that tells its time: read whole (a few dozen bytes; bounded).
            if let tag = HLSPackedAudioTag.length(data) {
                while data.count < min(tag, 1 << 20), let chunk = try body.next() { data.append(chunk) }
                packedTimestamp = HLSPackedAudioTag.transportStreamTimestamp(data)
            }
            openTiming.answer = ContinuousClock.now - began
            onAnswer?()
        } catch {
            opened?.close()
            throw .load(error)
        }
        isSegmentwise =
            Self.isWebVTT(data)
            || (data.trimmedIsEmpty && ["vtt", "webvtt"].contains(first.url.pathExtension.lowercased()))
        if isSegmentwise {
            // A cue file is small, and read whole.
            if let opened {
                do throws(HLSSegmentLoadError) { data.append(try opened.rest()) } catch {
                    opened.close()
                    throw .load(error)
                }
            }
            do { try openSegmentContext(data, sequence: first.discontinuitySequence) } catch {
                close()
                throw error
            }
        } else {
            initBytes = Int64(head.count)
            firstSegment = first
            head.append(data)
            body = opened
            bodyHasBytes = !data.isEmpty
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

    /// Stream `index` of the open context (what a packet's `stream_index` names), without making the list `streams` does.
    func stream(at index: Int) -> UnsafeMutablePointer<AVStream>? {
        context?.stream(at: index)
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
            try openSegmentContext(try loader.segment(segment), sequence: segment.discontinuitySequence)
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

    /// The first segment's body, which this reader no longer closes: the lane keeps it (`HLSSegmentBody.replayedBody`).
    func claimFirstBody() -> HLSSegmentBody? {
        isFirstClaimed = true
        return retainedFirst
    }

    func close() {
        if !(isFirstClaimed && body === retainedFirst) { body?.close() }
        body = nil
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
        let feed = SegmentFeed(head: head) { [weak self] in self?.nextChunk() ?? .end }
        self.feed = feed
        delivered = Int64(head.count)
        if let firstSegment { segmentStarts = [(initBytes, firstSegment, 0)] }
        segmentsStarted = 1
        try openContext(over: feed)
        openTiming.bytes = delivered
        timelineOffset = openedOffset()
        if reportsStarts, let anchoring, anchoring.role != .cues, let notify = anchoring.onSegmentStart,
            let openedStart,
            let firstSegment
        {
            toldThrough = 0
            notify(firstSegment, openedStart)
        }
    }

    /// The next bytes of a continuous run: what is left of the segment being read, else the first of the next segment
    /// (`next`, which may wait at a live edge), whose download starts as the previous one is read through.
    private func nextChunk() -> SegmentFeed.Chunk {
        while true {
            if let current = body {
                do throws(HLSSegmentLoadError) {
                    if let chunk = try current.next() {
                        bodyHasBytes = true
                        delivered += Int64(chunk.count)
                        return .data(chunk)
                    }
                } catch {
                    current.close()
                    body = nil
                    return fail(error)
                }
                body = nil
                retainedFirst = nil
            }
            guard let segment = next() else { return .end }
            bodyHasBytes = false
            segmentStarts.append((delivered, segment, segmentsStarted))
            segmentsStarted += 1
            do throws(HLSSegmentLoadError) {
                body = try loader.segmentBody(segment)
            } catch {
                return fail(error)
            }
        }
    }

    /// Ends the run's bytes for a segment that failed (`failure`, which `read` returns once the context is read through).
    /// One that failed before any of its bytes came ends them as the end of the stream does, so the container demuxer
    /// hands out what it still holds of the segment before (MPEG-TS's last packets, which only an end flushes); one
    /// that failed inside its bytes, or an abort, with the error (a packet cut short is not passed on).
    private func fail(_ error: HLSSegmentLoadError) -> SegmentFeed.Chunk {
        failure = error
        return bodyHasBytes || error == .interrupted ? .failed(Self.code(for: error)) : .end
    }

    /// A context over one WebVTT segment, of discontinuity `sequence`.
    private func openSegmentContext(_ data: Data, sequence: Int) throws(HLSSegmentReaderError) {
        closeContext()
        io?.free()
        io = nil
        // A rendition with nothing to show for a stretch serves an empty file.
        guard !data.trimmedIsEmpty else { return }
        let map = HLSTimestampMap.parse(webVTT: data) ?? HLSTimestampMap()
        // The map's MPEG-TS time wraps as the media's does: read it as the value nearest where the run is.
        // Asked at each segment: the sequence may not have been anchored when this run started.
        let shift = timelineShift?(sequence) ?? 0
        let expected = Int64((start - shift) * 90_000)
        let wrap = Int64(1) << 33
        let mpegts = map.mpegts + wrap * TimestampUnwrapper.wraps(from: map.mpegts, to: expected, wrap: wrap)
        let mapShift = Double(mpegts) / 90_000 - map.local
        segmentShift = mapShift + shift
        timelineOffset = shift
        let feed = SegmentFeed(head: data) { .end }
        self.feed = feed
        try openContext(over: feed)
        openTiming.bytes = Int64(data.count)
    }

    private func openContext(over feed: SegmentFeed) throws(HLSSegmentReaderError) {
        guard let io = SegmentIO(source: feed) else { throw .open(-ENOMEM) }
        self.io = io
        guard let allocated = avformat_alloc_context() else { throw .open(-ENOMEM) }
        allocated.pointee.pb = io.context
        allocated.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        var opened: UnsafeMutablePointer<AVFormatContext>? = allocated
        let began = ContinuousClock.now
        var result = avformat_open_input(&opened, nil, nil, nil)
        openTiming.open = ContinuousClock.now - began
        guard result >= 0 else {
            // A context that failed to open is freed by FFmpeg.
            throw .open(failure.map(Self.code(for:)) ?? result)
        }
        guard let ctx = opened else { throw .open(-ENOMEM) }
        // As `hls.c` bounds its own probing: a few seconds of media, read across the segments as they come (an end
        // of input faked at the first segment would stay: `mov` ends for good at one).
        if let knownVideoDelay {
            // The streams are described: the analysis is there for where the run starts (`start_time`, `openedOffset`),
            // the least presentation time of the frames it reads. FFmpeg's wait for 20 frames to guess the frame rate
            // read 3.2 MB of a 4K fMP4 segment before the first packet (1.4 s at 20 Mbit/s). A container with a header
            // reads as many frames as reach the earliest one shown: `fps_probe_size` counts the intervals between
            // frames, so the reorder depth reads one frame more than it (AV1, without reordering, its keyframe alone).
            // MPEG-TS, which may add streams as it reads (`AVFMTCTX_NOHEADER`), reads up to `max_analyze_duration`
            // whatever it found, and a frame count cut short there left its sound without decode times after the first
            // packet: it keeps FFmpeg's count, and the limit is a second, so that the picture's first frames are among
            // what it reads where the sound comes ahead of them.
            if ctx.pointee.ctx_flags & AVFMTCTX_NOHEADER == 0 {
                ctx.pointee.fps_probe_size = Int32(knownVideoDelay)
            }
            ctx.pointee.max_analyze_duration = Int64(AV_TIME_BASE)
        } else {
            ctx.pointee.max_analyze_duration = 4 * Int64(AV_TIME_BASE)
        }
        let analysing = ContinuousClock.now
        result = avformat_find_stream_info(ctx, nil)
        openTiming.analyze = ContinuousClock.now - analysing
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
        referenceStream = Int(stream.pointee.index)
        let offset = settleOffset(first: stream.pointee.start_time, of: stream)
        // Where the run's first segment starts by the media, known before any packet is read (`noteSegmentStart` tells
        // the later ones): a seek whose segment is not the one that holds its target restarts before anything is handed out.
        let index = Int(stream.pointee.index)
        let ticks = unwrappers[index]?.unwrapped(stream.pointee.start_time) ?? stream.pointee.start_time
        openedStart = Self.seconds(ticks, stream.pointee.time_base) + offset
        return offset
    }

    /// The run's offset, its first timestamp being `ticks` of `stream`: the sequence's shared one (`anchoring`), or its
    /// own. Starts the unwrapping of every stream where the offset puts the run.
    ///
    /// Packed audio counts its timestamps from the run's first sample: the media's clock is the first segment's `PRIV`
    /// time ahead of them, by which it takes the shared offset (33 bits wrap). Without a `PRIV` nothing tells its time on
    /// the media's clock: the run is anchored by the playlist alone, and the shared offsets are neither taken nor set.
    private func settleOffset(first ticks: Int64, of stream: UnsafeMutablePointer<AVStream>) -> Double {
        let base = stream.pointee.time_base
        var first = Self.seconds(ticks, base)
        /// Seconds the media's clock is ahead of the stream's timestamps.
        var ahead = 0.0
        var isPacked = false
        var wrap = TimestampUnwrapper(bits: stream.pointee.pts_wrap_bits).map { Self.seconds($0.wrap, base) }
        var anchoring = anchoring
        if let name = context?.pointee.iformat?.pointee.name, Self.packedFormats.contains(String(cString: name)) {
            if let packedTimestamp {
                ahead = Double(packedTimestamp) / 90_000
                isPacked = true
                first += ahead
                wrap = Double(Int64(1) << 33) / 90_000
            } else {
                anchoring = nil
                reportsStarts = false
            }
        }
        var offset = start - first
        if let anchoring {
            offset = anchoring.anchors.offset(
                of: anchoring.sequence, start: start, first: first, tolerance: anchoring.tolerance,
                role: anchoring.role
            ) { [first, wrap] media in
                wrap.map { TimestampUnwrapper.nearest(first, to: media, wrap: $0) } ?? first
            }
            // A packed run's PRIV has no unwrapper after it (its stream doesn't wrap): the whole wraps that bring it where
            // the offset puts the run are taken here (a sequence anchored before the 33-bit wrap, a run read after it).
            if isPacked, let wrap {
                ahead += TimestampUnwrapper.nearest(first, to: start - offset, wrap: wrap) - first
            }
        }
        // Where the run starts on the media's clock, for each stream's own wrap.
        let media = start - offset - ahead
        for stream in streams {
            let index = Int(stream.pointee.index)
            let base = stream.pointee.time_base
            let ticks = (media * Double(base.den) / Double(base.num)).rounded()
            guard unwrappers[index] != nil, base.num > 0, ticks.isFinite, abs(ticks) < 1e15 else { continue }
            unwrappers[index]?.expect(near: Int64(ticks))
        }
        return offset + ahead
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
        if timelineOffset == nil, !isSegmentwise {
            // Nothing told a start time: the first packet's (before the unwrapping, which the offset starts).
            if let ticks = packet.pts != Int64.min ? packet.pts : (packet.dts != Int64.min ? packet.dts : nil) {
                timelineOffset = settleOffset(first: ticks, of: stream)
            }
        }
        if var unwrapper = unwrappers[index] {
            let placed = unwrapper.unwrap(
                pts: packet.pts == Int64.min ? nil : packet.pts, dts: packet.dts == Int64.min ? nil : packet.dts)
            unwrappers[index] = unwrapper
            packet.pts = placed.pts ?? Int64.min
            packet.dts = placed.dts ?? Int64.min
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
        if reportsStarts, let anchoring, anchoring.role != .cues, let notify = anchoring.onSegmentStart, !isSegmentwise,
            timelineOffset != nil
        {
            noteSegmentStart(of: packet, stream: stream, notify)
        }
    }

    /// The first packet of the reference stream that comes from a segment (by its `pos` in the bytes handed to the
    /// context) is where the media puts the segment's start: told once for each segment, as it is read. A packet of
    /// no known place (`pos` unset) tells nothing.
    private func noteSegmentStart(
        of packet: AVPacket, stream: UnsafeMutablePointer<AVStream>, _ notify: (HLSSegment, Double) -> Void
    ) {
        if referenceStream == nil {
            let all = streams
            let picture = all.first {
                $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                    && $0.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0
            }
            referenceStream = (picture ?? all.first).map { Int($0.pointee.index) } ?? -1
        }
        guard Int(packet.stream_index) == referenceStream, packet.pos >= 0,
            let position = segmentStarts.lastIndex(where: { $0.offset <= packet.pos })
        else { return }
        let started = segmentStarts[position]
        guard started.number > toldThrough else { return }
        toldThrough = started.number
        segmentStarts.removeFirst(position)
        let ticks = packet.pts != Int64.min ? packet.pts : packet.dts
        if ticks != Int64.min { notify(started.segment, Self.seconds(ticks, stream.pointee.time_base)) }
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
