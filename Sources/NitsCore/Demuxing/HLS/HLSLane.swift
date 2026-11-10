import CFFmpeg
import Foundation

/// One rendition of an HLS stream being read: the variant's playlist (its video, and the sound muxed into it) or an
/// audio rendition's. It owns the rendition's timeline (reloaded while the stream is live), the reader of the run being
/// read (`HLSSegmentReader`) and the next packet it would hand out, which `HLSInput` compares with the other lanes'
/// to interleave them by decode time.
///
/// Reading is lazy: a seek or a track change only says where to start (`reposition(at:)`); the next `fill` opens the
/// run there. A run ends at a discontinuity, a change of init section or a gap in the playlist; the lane reads on from
/// the segment that ended it. At a live edge the lane waits for the playlist to list the next segment, reloading it on
/// its own schedule (RFC 8216 6.3.4: the target duration, half of it after a reload that changed nothing), and gives
/// way to an abort (`shouldAbort`: a seek that waits for the input, a close) at once. A playlist that stays unchanged
/// for `stuckTargetDurations` target durations ends the wait with an error.
///
/// Not thread-safe: the demuxer's read, seeks and selection all run behind its `lock`.
final class HLSLane: @unchecked Sendable {
    enum Kind { case primary, audio }

    /// A stream of the input's table that the lane hands out packets of.
    struct StreamSlot {
        let table: Int
        /// The timeline's seconds of the table stream's time base: the packet's timestamps are rescaled to it.
        let timebase: AVRational
        let type: AVMediaType
        var isRead = true
    }

    let kind: Kind
    /// The playlist's address as asked for, which a reload asks for again.
    let url: URL
    /// The master's variables, which the media playlist may import (`EXT-X-DEFINE`).
    private let variables: [String: String]
    private let loader: HLSSegmentLoader
    private let shouldAbort: () -> Bool
    private(set) var timeline: HLSTimeline
    /// The streams the lane hands out, in the order its readers find them (`slotIndex` matches a run's by kind).
    private(set) var streams: [StreamSlot] = []
    /// Whether the lane is read at all: one of its streams is. A lane nothing reads downloads nothing.
    private(set) var isRead = true

    private var reader: HLSSegmentReader?
    /// The segment the run being read is on: what the next one follows.
    private var current: HLSTimeline.Entry?
    /// Where the next run starts: a seek, the segment that ended the last run, the start.
    private var resume: HLSTimeline.Entry?
    /// The playlist ended and the last segment was read.
    private var isFinished = false
    /// Why the run's segments stopped before the end of the playlist: an abort, a failed reload. `read` returns it
    /// once the bytes left are read.
    private var stopCode: Int32?
    private let packet: UnsafeMutablePointer<AVPacket>
    private(set) var hasPending = false
    /// The pending packet's decode time, in seconds on the timeline.
    private(set) var pendingTime = 0.0
    /// The extradata the video last read had, to tell a run that brings others (a new `EXT-X-MAP`).
    private var lastExtradata: Data?
    private var needsExtradataCheck = false
    /// A forward seek's landing, not yet reached: packets before it are dropped.
    private var landing: Landing?
    /// The slot (`streams`) of each of the run's reader streams, `-1` for one not handed out: found at its first
    /// packet, fixed for the run.
    private var slotOfReaderStream: [Int: Int] = [:]
    // Reloading.
    private var lastLoad = ContinuousClock.now
    private var unchangedReloads = 0
    private var failedReloads = 0
    private var resetReloads = 0
    /// When a load last brought something new (the opening's counts: the lane is made from it).
    private var lastChange = ContinuousClock.now

    static let maxFailedReloads = 3
    /// Target durations a live playlist may stay unchanged before it is taken as stuck (ExoPlayer's coefficient).
    static let stuckTargetDurations = 3.5
    /// Segments that failed one after another before the lane gives the error up.
    static let maxSkippedSegments = 3
    private var skipped = 0

    init(
        kind: Kind, url: URL, timeline: HLSTimeline, variables: [String: String], loader: HLSSegmentLoader,
        shouldAbort: @escaping () -> Bool
    ) {
        self.kind = kind
        self.url = url
        self.timeline = timeline
        self.variables = variables
        self.loader = loader
        self.shouldAbort = shouldAbort
        packet = av_packet_alloc()
    }

    deinit {
        close()
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pointer)
    }

    // MARK: Opening

    /// Opens the first run at the segment that holds `time` and probes its streams: the first reader the lane keeps.
    func open(at time: Double) throws(HLSSegmentReaderError) {
        guard let entry = timeline.entry(at: time) else { throw .open(-EINVAL) }
        try startRun(at: entry)
    }

    /// The streams the lane's reader found, to describe in the input's table.
    var readerStreams: [UnsafeMutablePointer<AVStream>] {
        reader?.streams ?? []
    }

    /// Takes the slots of the table's streams, in the order of the streams the reader found that the input keeps
    /// (`HLSInput.keeps`): readers of later runs map by the same order.
    func setStreams(_ slots: [StreamSlot]) {
        streams = slots
    }

    // MARK: State

    func setReading(_ isRead: Bool, slot: Int) {
        guard streams.indices.contains(slot) else { return }
        streams[slot].isRead = isRead
        let was = self.isRead
        self.isRead = streams.contains { $0.isRead }
        // Nothing is downloaded for a lane nothing reads; one read again starts afresh where the picture is read (`reposition`).
        if !self.isRead || !was { dropRun() }
    }

    /// Where a forward seek lands: what the lane reads before it is dropped, as `hls.c` drops packets before its
    /// `seek_timestamp`. The segment that holds the target starts at a keyframe before it.
    struct Landing {
        /// Seconds on the timeline.
        let time: Double
        /// The lane's stream the seek is for: its first keyframe at or after `time` ends the dropping. Nil for a lane
        /// without it (another rendition): the first packet at or after `time` of any of its streams.
        let keyframeOf: AVMediaType?
    }

    /// Starts the next run at the segment that holds `time` (the lane's last, for a time past its end; the first for
    /// one before), dropping what comes before `landing`.
    func reposition(at time: Double, landing: Landing? = nil) {
        dropRun()
        skipped = 0
        resume = timeline.entry(at: time) ?? timeline.entries.last
        current = nil
        self.landing = landing
    }

    /// Whether `time` is within the timeline (a forward seek past the end is none).
    func contains(_ time: Double) -> Bool {
        timeline.index(at: time) != nil
    }

    var window: LiveWindow? { timeline.liveWindow }

    func close() {
        dropRun()
    }

    private func dropRun() {
        reader?.close()
        reader = nil
        if hasPending {
            av_packet_unref(packet)
            hasPending = false
        }
        stopCode = nil
        isFinished = false
        needsExtradataCheck = false
    }

    // MARK: Reading

    /// Reads the packet that `read` hands out next into the lane: 0, or an FFmpeg error (`AVERROR_EOF` once the
    /// playlist is read to its end).
    func fill() -> Int32 {
        guard isRead else { return MediaDemuxer.averrorEOF }
        if hasPending { return 0 }
        while true {
            if reader == nil {
                switch nextRunStart() {
                case .start(let entry):
                    do throws(HLSSegmentReaderError) { try startRun(at: entry) } catch {
                        resume = entry
                        if let stop = recover(from: error.code) { return stop }
                    }
                case .ended:
                    isFinished = true
                    return MediaDemuxer.averrorEOF
                case .stopped(let code):
                    return code
                }
            }
            guard let active = reader else { continue }
            let code = active.read(&packet.pointee)
            if code >= 0 {
                if place() {
                    skipped = 0
                    return 0
                }
                continue
            }
            // The run ended, or failed.
            reader?.close()
            reader = nil
            if code == MediaDemuxer.averrorEOF {
                if let stop = stopCode {
                    stopCode = nil
                    return stop
                }
                continue
            }
            resume = current
            if let stop = recover(from: code) { return stop }
        }
    }

    /// After a load or a demux failed (`resume` is the segment): the segment is skipped at once (a run of its own: a hole
    /// in time), as `hls.c` does with `seg_max_retry` 0 (a retry would hold the demuxer's lock, which a seek waits for,
    /// and repeat the packets a demux error came after); a lane whose segments fail `maxSkippedSegments` in a row gives
    /// the error up. Nil to go on reading; else what `fill` returns.
    private func recover(from code: Int32) -> Int32? {
        if code == HTTPSessionInput.averrorExit { return code }
        skipped += 1
        guard skipped < Self.maxSkippedSegments, let failed = resume else { return code }
        switch following(failed) {
        case .entry(let next, _):
            AppLog.warning(.demuxer, "HLS: segment \(failed.sequence) failed (\(code)), skipped")
            resume = next
            return nil
        case .ended:
            resume = nil
            isFinished = true
            return MediaDemuxer.averrorEOF
        case .stopped(let stop):
            return stop
        }
    }

    /// Stops reading the lane: an optional rendition that failed, the stream plays without it.
    func giveUp() {
        dropRun()
        isRead = false
    }

    /// Takes the packet just read to the input's streams: maps its index, puts it on the table stream's time base and
    /// tells a changed extradata. False when it is dropped (a stream the input doesn't keep, or one not read).
    private func place() -> Bool {
        guard let reader else {
            av_packet_unref(packet)
            return false
        }
        let readerIndex = Int(packet.pointee.stream_index)
        let slot: Int
        if let known = slotOfReaderStream[readerIndex] {
            slot = known
        } else {
            slot = slotIndex(of: readerIndex, in: reader) ?? -1
            slotOfReaderStream[readerIndex] = slot
        }
        guard slot >= 0, streams[slot].isRead, let source = reader.stream(at: readerIndex) else {
            av_packet_unref(packet)
            return false
        }
        let target = streams[slot]
        if source.pointee.time_base.num != target.timebase.num || source.pointee.time_base.den != target.timebase.den {
            av_packet_rescale_ts(packet, source.pointee.time_base, target.timebase)
        }
        // Before the extradata: a keyframe dropped must not take the change it brings with it.
        if !hasLanded(type: target.type, timebase: target.timebase) {
            av_packet_unref(packet)
            return false
        }
        if needsExtradataCheck, source.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
            packet.pointee.flags & AV_PKT_FLAG_KEY != 0
        {
            needsExtradataCheck = false
            attachNewExtradata(of: source)
        }
        packet.pointee.stream_index = Int32(target.table)
        let ticks = packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
        pendingTime =
            ticks == Int64.min
            ? -Double.infinity : Double(ticks) * Double(target.timebase.num) / Double(target.timebase.den)
        hasPending = true
        return true
    }

    /// Whether the packet just read is past the landing of a forward seek, or there is none; the packet that reaches
    /// it ends it. A packet without timestamps ends it too (as `hls.c`'s).
    private func hasLanded(type: AVMediaType, timebase: AVRational) -> Bool {
        guard let landing else { return true }
        if let keyed = landing.keyframeOf, keyed != type { return false }
        let ticks = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        if ticks != Int64.min {
            let seconds = Double(ticks) * Double(timebase.num) / Double(timebase.den)
            guard seconds >= landing.time - 0.001 else { return false }
            if landing.keyframeOf != nil, packet.pointee.flags & AV_PKT_FLAG_KEY == 0 { return false }
        }
        self.landing = nil
        return true
    }

    /// The position in `streams` of the reader's stream `index`: the streams the input keeps, in order.
    private func slotIndex(of index: Int, in reader: HLSSegmentReader) -> Int? {
        guard let stream = reader.stream(at: index), HLSInput.keeps(stream) else { return nil }
        let type = stream.pointee.codecpar.pointee.codec_type
        // By kind and place among the streams of that kind, as the table was described: a later run may list them in
        // another order.
        var ordinal = 0
        for candidate in 0..<index {
            if let other = reader.stream(at: candidate), HLSInput.keeps(other),
                other.pointee.codecpar.pointee.codec_type == type
            {
                ordinal += 1
            }
        }
        let sameKind = streams.indices.filter { streams[$0].type == type }
        return ordinal < sameKind.count ? sameKind[ordinal] : nil
    }

    /// The first video keyframe of a run whose init section differs from the last one read carries the new
    /// extradata, as the demuxer follows a stream's change of parameter sets (`AV_PKT_DATA_NEW_EXTRADATA`).
    private func attachNewExtradata(of stream: UnsafeMutablePointer<AVStream>) {
        let parameters = stream.pointee.codecpar.pointee
        guard parameters.extradata_size > 0, let bytes = parameters.extradata else { return }
        let extradata = Data(bytes: bytes, count: Int(parameters.extradata_size))
        defer { lastExtradata = extradata }
        guard let last = lastExtradata, last != extradata else { return }
        if let side = av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, extradata.count) {
            extradata.copyBytes(to: side, count: extradata.count)
        }
    }

    /// Moves the pending packet into `destination`.
    func take(into destination: inout AVPacket) {
        av_packet_move_ref(&destination, packet)
        hasPending = false
    }

    // MARK: Runs

    private enum RunStart {
        case start(HLSTimeline.Entry)
        case ended
        case stopped(Int32)
    }

    private func nextRunStart() -> RunStart {
        if let entry = resume {
            resume = nil
            return .start(entry)
        }
        if isFinished { return .ended }
        guard let last = current else { return .ended }
        switch following(last) {
        case .entry(let entry, _): return .start(entry)
        case .ended: return .ended
        case .stopped(let code): return .stopped(code)
        }
    }

    private func startRun(at first: HLSTimeline.Entry) throws(HLSSegmentReaderError) {
        // Before the reader: probing reads on into the next segments, asking `nextSegment` for them from this one.
        current = first
        runDescription = RunDescription(
            initSection: first.segment.initSection, discontinuity: first.segment.discontinuitySequence)
        let opened = try HLSSegmentReader(loader: loader, first: first.segment, start: first.start) {
            [weak self] in
            self?.nextSegment()
        }
        reader = opened
        slotOfReaderStream = [:]
        needsExtradataCheck = true
        resetReloads = 0
    }

    private struct RunDescription {
        let initSection: HLSInitSection?
        let discontinuity: Int
    }
    private var runDescription: RunDescription?

    /// What the run's reader asks for when it has read a segment through: the next of the same run, nil at its end
    /// (the playlist's, a break that starts another run, or a stop).
    private func nextSegment() -> HLSSegment? {
        guard let last = current, let run = runDescription else { return nil }
        switch following(last) {
        case .entry(let entry, let breaksRun):
            if breaksRun || entry.segment.initSection != run.initSection
                || entry.segment.discontinuitySequence != run.discontinuity
            {
                resume = entry
                return nil
            }
            current = entry
            return entry.segment
        case .ended:
            isFinished = true
            return nil
        case .stopped(let code):
            stopCode = code
            return nil
        }
    }

    private enum Step {
        /// The segment that follows; `breaksRun`: it can't be read as the same stream (a gap, a skip over expired segments).
        case entry(HLSTimeline.Entry, breaksRun: Bool)
        case ended
        case stopped(Int32)
    }

    /// The segment after `entry`, waiting for a live playlist to list it.
    private func following(_ entry: HLSTimeline.Entry) -> Step {
        while true {
            switch timeline.next(after: entry) {
            case .entry(let next):
                return .entry(next, breaksRun: next.segment.isGap || entry.segment.isGap)
            case .expired(let next):
                return .entry(next, breaksRun: true)
            case .ended:
                return .ended
            case .pending:
                if let code = waitForReload() { return .stopped(code) }
            }
        }
    }

    // MARK: Reloading

    /// Waits until the playlist is due again, and reloads it. Nil when the timeline may have changed; the error to stop
    /// the lane with otherwise (`AVERROR_EXIT` for an abort).
    private func waitForReload() -> Int32? {
        let interval = timeline.targetDuration * (unchangedReloads == 0 ? 1 : 0.5)
        let due = lastLoad + .seconds(max(interval, 0.5))
        let wake = DispatchSemaphore(value: 0)
        while ContinuousClock.now < due {
            if shouldAbort() { return HTTPSessionInput.averrorExit }
            // The read waits for the live stream's next segment with its thread, as FFmpeg's does inside `av_read_frame`.
            _ = wake.wait(timeout: .now() + .milliseconds(50))
        }
        if shouldAbort() { return HTTPSessionInput.averrorExit }
        do throws(HLSSegmentLoadError) {
            let loaded = try loader.playlist(url)
            lastLoad = .now
            guard case .media(let playlist) = try Self.parse(loaded, variables: variables) else {
                failedReloads += 1
                return failedReloads >= Self.maxFailedReloads ? -EIO : nil
            }
            failedReloads = 0
            return apply(timeline.reload(playlist), playlist)
        } catch {
            lastLoad = .now
            if error == .interrupted { return HTTPSessionInput.averrorExit }
            failedReloads += 1
            return failedReloads >= Self.maxFailedReloads ? HLSSegmentReader.code(for: error) : nil
        }
    }

    private static func parse(
        _ loaded: (data: Data, servedFrom: URL), variables: [String: String]
    ) throws(HLSSegmentLoadError) -> HLSPlaylist {
        do {
            return try HLSPlaylist.parse(loaded.data, url: loaded.servedFrom, variables: variables)
        } catch {
            throw .failed(-EIO)
        }
    }

    /// Takes what a reload did. Nil to go on waiting; `-ETIMEDOUT` for a playlist that is stuck: it has not changed for
    /// `stuckTargetDurations` target durations (ExoPlayer's `PlaylistStuckException`), a server that stopped
    /// updating it without ending it.
    private func apply(_ change: HLSTimeline.ReloadChange, _ playlist: HLSMediaPlaylist) -> Int32? {
        switch change {
        case .updated, .restarted:
            unchangedReloads = 0
            resetReloads = 0
            lastChange = .now
            return nil
        case .unchanged, .stale:
            unchangedReloads += 1
        case .reset:
            // Wholly behind the window: a lagging edge or a server that restarted. Once more tells which.
            resetReloads += 1
            unchangedReloads += 1
            if resetReloads >= 2 {
                resetReloads = 0
                _ = timeline.restart(playlist)
                unchangedReloads = 0
                lastChange = .now
                return nil
            }
        }
        let still = (ContinuousClock.now - lastChange) / .seconds(1)
        guard still > Self.stuckTargetDurations * timeline.targetDuration else { return nil }
        AppLog.warning(.demuxer, "HLS: the playlist has not changed for \(Int(still)) s, taken as stuck")
        return -ETIMEDOUT
    }
}
