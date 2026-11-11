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
    enum Kind { case primary, audio, subtitle }

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
    /// The offsets of the stream's timestamps, which its lanes share (`HLSTimestampAnchors`): a run of the lane's takes or
    /// sets its sequence's, a subtitle rendition's cues are placed by them.
    private let anchors: HLSTimestampAnchors
    private(set) var timeline: HLSTimeline
    /// Where the timeline ended when the lane was made, before any measure moved it (`contains`).
    private let initialEnd: Double
    /// The streams the lane hands out, in the order its readers find them (`slotIndex` matches a run's by kind).
    private(set) var streams: [StreamSlot] = []
    /// Whether the lane is read at all: one of its streams is. A lane nothing reads downloads nothing.
    private(set) var isRead = true

    private var reader: HLSSegmentReader?
    /// The body of the first segment of the run last opened (`HLSSegmentReader.claimFirstBody`): a seek or the demuxer's
    /// rewind to the start opens the same segment again, which then replays what was read and goes on with the same
    /// download (the opening reads the first segment to describe the picture, and the demuxer goes back to its start).
    /// Kept while the lane is read, until its run goes on to the next segment; one segment, not the stream's.
    private var startBody: HLSSegmentBody?
    private var startSegment: (url: URL, range: HLSByteRange?)?

    private func keepStart(of reader: HLSSegmentReader, _ segment: HLSSegment) {
        startBody?.close()
        startBody = reader.claimFirstBody()
        startSegment = (segment.url, segment.byteRange)
    }

    private func releaseStart() {
        startBody?.close()
        startBody = nil
    }

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
    /// The reorder depth of the lane's picture (0 without one), from its probe: its runs analyse only as many frames as
    /// tell where they start (`HLSSegmentReader.knownVideoDelay`). Nil for a lane not probed: its runs are analysed in full.
    private var videoDelay: Int?
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
        anchors: HLSTimestampAnchors, shouldAbort: @escaping () -> Bool
    ) {
        self.kind = kind
        self.url = url
        self.timeline = timeline
        self.variables = variables
        self.loader = loader
        self.shouldAbort = shouldAbort
        self.anchors = anchors
        initialEnd = timeline.end
        packet = av_packet_alloc()
    }

    /// How the lane's runs take the shared offsets: cues in a container (IMSC in fMP4, subtitles in MPEG-TS) are sparse,
    /// the first may be far into its segment, so they never anchor.
    private var anchorRole: HLSTimestampAnchors.Role {
        switch kind {
        case .primary: .picture
        case .audio: .sound
        case .subtitle: .cues
        }
    }

    /// What a WebVTT run of the lane places its cues by: the offset of each segment's sequence.
    private var timelineShift: (Int) -> Double? {
        { [anchors] in anchors.subtitleShift(for: $0) }
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
        nextRunReason = .open
        try startRun(at: entry)
    }

    /// Reads the start of the segment that holds `time` as far as FFmpeg's analysis goes, to describe the lane's streams, as
    /// `open(at:)` does with all of it. The run is not read on: `endProbe` drops it, and the lane is started with
    /// `reposition` or `catchUp`, or left unread. A probe anchors nothing (`HLSTimestampAnchors`): the lanes probed side by
    /// side would race for it, and the run read first anchors its sequence.
    /// `loader` stands in for the lane's own (one that gives way to an abort of the probe alone); `onAnswer` is told once
    /// the server answered (`HLSSegmentReader`).
    func probe(
        at time: Double, loader probeLoader: HLSSegmentLoader? = nil, onAnswer: (() -> Void)? = nil
    ) throws(HLSSegmentReaderError) {
        guard let entry = timeline.entry(at: time) else { throw .open(-EINVAL) }
        let began = ContinuousClock.now
        let probed = try HLSSegmentReader(
            loader: probeLoader ?? loader, first: entry.segment, start: entry.start, timelineShift: timelineShift,
            isProbe: true, onAnswer: onAnswer
        ) { nil }
        reader = probed
        slotOfReaderStream = [:]
        AppLog.debug(
            .demuxer,
            "\(HLSOpeningMeasure.run) probe \(label) seq=\(entry.sequence) \(probed.openTiming.description) "
                + "total=\(HLSOpeningMeasure.ms(ContinuousClock.now - began))")
    }

    /// The playlist's address shortened for the log: its folder and name (a ladder's playlists often share the name).
    var label: String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        return folder.isEmpty || folder == "/" ? url.lastPathComponent : "\(folder)/\(url.lastPathComponent)"
    }

    /// Why the next run opens, for the log (`HLSOpeningMeasure.run`).
    private enum RunReason: String {
        /// The lane's first run, of a media playlist alone (`open(at:)`).
        case open
        /// A start where the demuxer put the lane: the opening's after the probes, a seek, a rewind, a track read again.
        case reposition
        /// A variant switched to, catching up with the picture (`catchUp`).
        case `switch`
        /// The run after the last one ended: a discontinuity, a new init section, a failed segment skipped.
        case next
    }
    private var nextRunReason = RunReason.next
    /// The run opened and not yet logged: logged with its first packet (`fill`), or as redone.
    private var openedRun:
        (
            reason: RunReason, replayed: Bool, sequence: Int, timing: HLSSegmentReader.OpenTiming,
            began: ContinuousClock.Instant
        )?

    private func logOpenedRun(_ outcome: String) {
        guard let run = openedRun else { return }
        openedRun = nil
        AppLog.debug(
            .demuxer,
            "\(HLSOpeningMeasure.run) \(run.reason.rawValue)\(run.replayed ? "+replay" : "") \(label) seq=\(run.sequence) \(run.timing.description) "
                + "\(outcome)=\(HLSOpeningMeasure.ms(ContinuousClock.now - run.began))")
    }

    /// Ends a probe: the streams are described. The first picture the lane reads is compared with the probe's extradata
    /// (a stream's later init section brings new parameter sets then).
    func endProbe() {
        learnPicture(from: reader?.streams ?? [])
        dropRun()
    }

    /// What the lane's later runs need of its picture, from the streams that describe it (a probe's, or the first run of
    /// a lane described by another rung's probe): its reorder depth, and the extradata a later init section is compared
    /// with.
    private func learnPicture(from streams: [UnsafeMutablePointer<AVStream>]) {
        let picture = streams.first {
            HLSInput.keeps($0, in: kind) && $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
        }
        videoDelay = picture.map { max(Int($0.pointee.codecpar.pointee.video_delay), 0) } ?? 0
        if let video = streams.first(where: { HLSInput.keeps($0, in: kind) }),
            video.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
            let bytes = video.pointee.codecpar.pointee.extradata, video.pointee.codecpar.pointee.extradata_size > 0
        {
            lastExtradata = Data(bytes: bytes, count: Int(video.pointee.codecpar.pointee.extradata_size))
        }
    }

    /// A lane whose streams were described from another rung's probe (`HLSInput`'s clones): its first run's streams are
    /// handed to this before any packet, which describes them for good and says whether they are the ones described
    /// (the same kinds, as many). Nil once told, and for a lane probed itself.
    var describeFirstRun: (([UnsafeMutablePointer<AVStream>]) -> Bool)?

    /// A clone's runs are analysed as briefly as `model`'s (its probe's reorder depth, `knownVideoDelay`): the rungs of a
    /// ladder of one codec are encoded alike, and a full analysis of the first switched to (`max_analyze_duration`, 4K
    /// fMP4: some 3 MB before its first packet) would hold the read during playback. `describeFirstRun` still checks the
    /// streams it finds.
    func analyzesAs(_ model: HLSLane) {
        videoDelay = model.videoDelay
    }
    /// The first run's streams are not the ones described: the lane hands out nothing (`fill` returns `rejected`).
    private(set) var isRejected = false

    /// Describes a lane awaiting its first run (`describeFirstRun`) by a probe at `time` instead: a seek splices to a
    /// variant before it has been read. False when the probe fails (still to be described) or finds other streams.
    func describeByProbe(at time: Double) -> Bool {
        guard let describe = describeFirstRun else { return !isRejected }
        do throws(HLSSegmentReaderError) { try probe(at: time) } catch { return false }
        describeFirstRun = nil
        if describe(readerStreams) {
            endProbe()
            return true
        }
        isRejected = true
        dropRun()
        return false
    }

    /// What `fill` returns for a lane whose streams turned out other than described (`describeFirstRun`). No FFmpeg error
    /// (`FFERRTAG`'s form, `'HLSR'`).
    static let rejected: Int32 = -0x5253_4C48

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
        if !self.isRead { releaseStart() }
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

    /// Where the next run starts, decided by the next `fill`: the playlist of a live stream may have to be reloaded
    /// first, which a seek or a track change (under the demuxer's locks) must not wait for.
    private enum Start {
        /// The segment that holds the time (the lane's last, for a time past its end; the first for one before).
        case containing(Double)
        /// The segment after the one that holds the time: where a variant switched to catches up (`catchUp`).
        case following(Double)
    }
    private var start: Start?

    /// Starts the next run at the segment that holds `time`, dropping what comes before `landing`.
    func reposition(at time: Double, landing: Landing? = nil) {
        dropRun()
        skipped = 0
        start = .containing(time)
        nextRunReason = .reposition
        resume = nil
        current = nil
        self.landing = landing
        seekTarget = time
        redo = nil
        redoAttempts = 0
    }

    /// Where the last `reposition` was to start, until the run it opens has told where its first segment starts: the
    /// playlist's durations choose the segment, the media's timestamps may put its start elsewhere (`segmentStarted`).
    private var seekTarget: Double?
    /// The first segment of the run being read.
    private var runFirst: HLSTimeline.Entry?
    /// A better segment to start the run at, found once the first one's start was measured (`fill` restarts there).
    private var redo: HLSTimeline.Entry?
    private var redoAttempts = 0
    /// A run's reader is being opened (`startRun`), which is when its first segment's start is told.
    private var isOpening = false
    /// Restarts of a seek's run for a segment the durations chose wrongly. The target is kept while the run restarted is
    /// measured too, and dropped once a run holds it or these are used up.
    private static let maxRedos = 2

    /// The media says where `segment` starts (`HLSSegmentReader.Anchoring.onSegmentStart`): the timeline takes it
    /// (`HLSTimeline.measure`), and a seek's run, whose first segment the playlist's durations chose, restarts at the
    /// segment that holds the target by the corrected timeline when that is another (the chosen one started after the
    /// target, or ended before it).
    private func segmentStarted(_ segment: HLSSegment, at time: Double) {
        timeline.measure(sequence: segment.sequence, url: segment.url, byteRange: segment.byteRange, start: time)
        current = refreshed(current)
        resume = refreshed(resume)
        runFirst = refreshed(runFirst)
        // Only the measure taken as the run opens decides a restart (nothing has been handed out yet).
        guard isOpening, let first = runFirst, first.sequence == segment.sequence, let target = seekTarget else {
            return
        }
        guard redoAttempts < Self.maxRedos, let better = timeline.entry(at: target), better.sequence != first.sequence,
            better.epoch == first.epoch
        else {
            seekTarget = nil
            return
        }
        redoAttempts += 1
        redo = better
        AppLog.info(
            .demuxer,
            "HLS: segment \(first.sequence) starts at \(String(format: "%.3f", time)) s, not by its durations; \(String(format: "%.3f", target)) s is in segment \(better.sequence)"
        )
    }

    /// `entry` as the timeline lists it now (its start may have been measured since).
    private func refreshed(_ entry: HLSTimeline.Entry?) -> HLSTimeline.Entry? {
        guard let entry, let now = timeline.entry(sequence: entry.sequence), now.epoch == entry.epoch else {
            return entry
        }
        return now
    }

    /// Starts the next run at the first segment that begins after the one holding `time`: a variant switched to joins
    /// the picture at the keyframe of a segment ahead of what the demuxer read of the old one (a segment starts with
    /// one; the splice takes the first at or after the last picture read), not at the one it is reading, which would
    /// be downloaded to be dropped.
    func catchUp(after time: Double) {
        dropRun()
        skipped = 0
        start = .following(time)
        nextRunReason = .switch
        seekTarget = nil
        resume = nil
        current = nil
        landing = nil
    }

    /// Reloads a live playlist the server has moved on from (not loaded for a target duration). Nil to go on; else the
    /// error to stop with.
    private func reloadIfStale() -> Int32? {
        guard timeline.liveWindow != nil, !timeline.hasEnded,
            ContinuousClock.now - lastLoad > .seconds(timeline.targetDuration)
        else {
            return nil
        }
        return reload()
    }

    /// Settles `start` into `resume` / `current`. Nil to go on; else what `fill` returns.
    private func resolveStart() -> Int32? {
        guard let chosen = start else { return nil }
        // A lane left unread for long has a playlist the server has moved on from.
        if let code = reloadIfStale() { return code }
        start = nil
        switch chosen {
        case .containing(let time):
            // A time before the window (a rewind after it slid) is the window's first segment, not its edge.
            resume =
                time < timeline.start ? timeline.entries.first : (timeline.entry(at: time) ?? timeline.entries.last)
        case .following(let time):
            if time < timeline.start {
                resume = timeline.entries.first
            } else {
                // The segment after it, which `following` waits for at a live edge, or the end of the playlist.
                current = timeline.entry(at: time) ?? timeline.entries.last
            }
        }
        return nil
    }

    /// Whether `time` is within the timeline (a forward seek past the end is none). The end of the timeline as first
    /// loaded counts too: the length shown comes from it, and measuring may have moved the end back (durations listed
    /// too long).
    func contains(_ time: Double) -> Bool {
        timeline.index(at: time) != nil || (!timeline.isEmpty && time <= initialEnd)
    }

    var window: LiveWindow? { timeline.liveWindow }

    func close() {
        releaseStart()
        dropRun()
    }

    private func dropRun() {
        reader?.close()
        reader = nil
        openedRun = nil
        if hasPending {
            av_packet_unref(packet)
            hasPending = false
        }
        stopCode = nil
        isFinished = false
        needsExtradataCheck = false
    }

    // MARK: Reading

    /// What `fill(before:picture:)` returns for a lane held back: its next segment starts after the time given, or waits
    /// for the picture to anchor its sequence. No FFmpeg error (`FFERRTAG`'s form, `'HLSH'`): a reader's own never reads
    /// as it.
    static let held: Int32 = -0x4853_4C48

    /// Segments that start after this many seconds are not loaded yet (`fill(before:picture:)`); nil while nothing holds
    /// the lane back.
    private var readLimit: Double?
    /// The decode time of the picture's next packet (`fill(before:picture:)`): how far the picture is, which a rendition
    /// at a break waits for (`waitsForAnchor`); nil when the picture is read through, or for the picture's own lane.
    private var pictureTime: Double?

    /// Reads the packet that `read` hands out next into the lane: 0, or an FFmpeg error (`AVERROR_EOF` once the
    /// playlist is read to its end). With `limit`, no segment that starts after it is loaded: `held` until a later call
    /// allows it. A subtitle rendition is read so, as far as the picture is: its cues are sparse, and a lane with no
    /// packet pending holds the whole read (`HLSInput.read`), which would otherwise load every segment of a stretch
    /// without cues to find the next, and wait at a live edge in a silence while the picture's packets are ready. With
    /// `picture`, a rendition's run of a sequence the picture has not anchored yet waits for it (`waitsForAnchor`).
    func fill(before limit: Double? = nil, picture: Double? = nil) -> Int32 {
        guard isRead else { return MediaDemuxer.averrorEOF }
        if hasPending { return 0 }
        if isRejected { return Self.rejected }
        if let code = resolveStart() { return code }
        readLimit = limit
        pictureTime = picture
        defer {
            readLimit = nil
            pictureTime = nil
        }
        while true {
            if reader == nil {
                switch nextRunStart() {
                case .start(let entry):
                    do throws(HLSSegmentReaderError) { try startRun(at: entry) } catch {
                        seekTarget = nil
                        redo = nil
                        resume = entry
                        if let stop = recover(from: error.code) { return stop }
                        continue
                    }
                    if isRejected {
                        logOpenedRun("rejected")
                        dropRun()
                        return Self.rejected
                    }
                    if let again = redo {
                        // The media puts the first segment of a seek elsewhere than its durations did, and the one that
                        // holds the target is another: start there, before a packet is read.
                        redo = nil
                        let reason = openedRun?.reason ?? .next
                        logOpenedRun("redone")
                        dropRun()
                        resume = again
                        nextRunReason = reason
                    } else {
                        seekTarget = nil
                    }
                case .held:
                    return Self.held
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
                    logOpenedRun("firstPacket")
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
        releaseStart()
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
        guard let stream = reader.stream(at: index), HLSInput.keeps(stream, in: kind) else { return nil }
        let type = stream.pointee.codecpar.pointee.codec_type
        // By kind and place among the streams of that kind, as the table was described: a later run may list them in
        // another order.
        var ordinal = 0
        for candidate in 0..<index {
            if let other = reader.stream(at: candidate), HLSInput.keeps(other, in: kind),
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
        /// The next segment starts after `readLimit`.
        case held
        case ended
        case stopped(Int32)
    }

    /// Whether a segment that starts at `time` waits for a later `fill(before:)`.
    private func isHeld(at time: Double) -> Bool {
        readLimit.map { time > $0 } ?? false
    }

    /// Whether a rendition's run at `entry` waits for the picture to anchor its discontinuity sequence
    /// (`HLSTimestampAnchors`), so that at a break the picture anchors it whichever lane gets there first. A subtitle run
    /// takes the offset as it finds it, and before the picture anchors would find the one cues fall back on, the
    /// picture's old run's (which an old run whose timestamps go past the break, durations listed too short, keeps); a
    /// sound run would anchor it by its own first sample. Waited for until the picture is a target duration past the run's
    /// start at most: a sequence the picture never anchors (numbers of discontinuities that don't match across the
    /// playlists) is then anchored by the sound, and cues take the picture's offset.
    private func waitsForAnchor(_ entry: HLSTimeline.Entry) -> Bool {
        guard kind != .primary, let picture = pictureTime, !anchors.isAnchored(entry.segment.discontinuitySequence)
        else { return false }
        return picture < entry.start + max(timeline.targetDuration, 1)
    }

    private func nextRunStart() -> RunStart {
        if let entry = resume {
            if isHeld(at: entry.start) || waitsForAnchor(entry) { return .held }
            resume = nil
            return .start(entry)
        }
        if isFinished { return .ended }
        guard let last = current else { return .ended }
        // Before `following`, which waits at a live edge for the segment.
        if isHeld(at: last.end) { return .held }
        switch following(last) {
        case .entry(let entry, _):
            if waitsForAnchor(entry) {
                resume = entry
                return .held
            }
            return .start(entry)
        case .ended: return .ended
        case .stopped(let code): return .stopped(code)
        }
    }

    private func startRun(at first: HLSTimeline.Entry) throws(HLSSegmentReaderError) {
        let began = ContinuousClock.now
        let reason = nextRunReason
        nextRunReason = .next
        // Before the reader: probing reads on into the next segments, asking `nextSegment` for them from this one.
        var replay: HLSSegmentBody?
        if let kept = startBody {
            // Closed before the reader opens: what it still downloads would share the link with the segment waited for.
            startBody = nil
            if let id = startSegment, id.url == first.segment.url, id.range == first.segment.byteRange {
                replay = kept.replayedBody()
                if replay == nil { kept.close() }
            } else {
                kept.close()
            }
        }
        current = first
        runFirst = first
        runDescription = RunDescription(
            initSection: first.segment.initSection, discontinuity: first.segment.discontinuitySequence)
        isOpening = true
        defer { isOpening = false }
        let opened = try HLSSegmentReader(
            loader: loader, first: first.segment, start: first.start,
            timelineShift: kind == .subtitle ? timelineShift : nil,
            anchoring: .init(
                anchors: anchors, sequence: first.segment.discontinuitySequence,
                tolerance: max(timeline.targetDuration, 1), role: anchorRole,
                onSegmentStart: kind == .subtitle
                    ? nil : { [weak self] segment, time in self?.segmentStarted(segment, at: time) }),
            // The streams are the table's since the probe: the analysis only finds where the run starts. A lane opened
            // without a probe (a media playlist alone) analyses its runs in full.
            knownVideoDelay: kind == .subtitle ? nil : videoDelay,
            firstBody: replay
        ) {
            [weak self] in
            self?.nextSegment()
        }
        keepStart(of: opened, first.segment)
        reader = opened
        if let describe = describeFirstRun {
            describeFirstRun = nil
            if describe(opened.streams) {
                learnPicture(from: opened.streams)
            } else {
                isRejected = true
            }
        }
        openedRun = (reason, replay != nil, first.sequence, opened.openTiming, began)
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
        // The run is past its first segment: it is not replayed any more.
        releaseStart()
        guard let last = current, let run = runDescription else { return nil }
        // Held back: the run ends here, and the next `fill` that allows it starts another at the next segment.
        if isHeld(at: last.end) { return nil }
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
            // A live read that is behind has a window the server has moved on from: reload it before the next segment, as
            // hls.c does, so a segment that expired is skipped rather than asked for.
            // Only an abort stops the read here: segments are listed ahead, and a stuck or failing playlist is decided
            // at the edge (`waitForReload`).
            if let code = reloadIfStale(), code == HTTPSessionInput.averrorExit { return .stopped(code) }
            switch timeline.next(after: entry) {
            case .entry(let next):
                // Numbers that don't follow: segments missed (a late reload, `HLSTimeline.startRun`) between bytes that
                // are not one stream, whatever the discontinuity sequence says.
                return .entry(
                    next,
                    breaksRun: next.segment.isGap || entry.segment.isGap || next.sequence != entry.sequence + 1)
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
        return reload()
    }

    /// Loads the playlist again and merges it. Nil when the timeline may have changed; the error to stop the lane
    /// with otherwise.
    private func reload() -> Int32? {
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
