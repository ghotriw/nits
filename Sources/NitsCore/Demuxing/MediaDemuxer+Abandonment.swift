import CFFmpeg
import Foundation

/// Whether the segment being downloaded should be given up for one of a lower variant
/// (`AdaptiveBitrateLogic.abandonment(of:among:buffer:roundTrip:)`). Step 5a: the decision is logged only, with where
/// the segment is against the playing position, to tell how often it could be undone by cutting the segment's queued
/// packets and how often it would need a re-read.
extension MediaDemuxer {
    /// A segment of a variant that is being downloaded, as the input tells it while the read waits for its bytes.
    struct InFlightSegment: Sendable, Equatable {
        /// The variants the lane belongs to (variants that differ in their audio group share a playlist).
        let variants: [Int]
        let sequence: Int
        /// Seconds on the timeline the segment starts at, and how long it is.
        let start: Double
        let duration: Double
        let progress: HTTPSessionInput.Progress
        /// The variant's own lane carries sound (muxed into the picture's segments, as in MPEG-TS), not a rendition.
        let hasMuxedAudio: Bool
    }

    /// The last segment a decision was logged for (variant, sequence): once each.
    struct AbandonmentLog {
        var last: (variant: Int, sequence: Int)?
    }

    /// Called on the read-ahead thread: while it waits for the download inside the read (`lock` held, `queueLock` released:
    /// what is written with both is read), or from its idle step (`pollInFlightSegments`: both held, `queueLockHeld`).
    func noteSegmentInFlight(
        _ segment: InFlightSegment, queueLockHeld: Bool = false, source: CheckSource = .wait
    ) {
        // A rendition's input (sound, subtitles) the thread waits on: the picture's download goes on meanwhile and nothing
        // else asks about it (the separate sound shares a slow link with the picture, and the thread stood on it for 7 s
        // with no check made). The pictures' lanes are asked from here: the same thread, `lock` held, `queueLock` released.
        guard !segment.variants.isEmpty else {
            trace(.foreignWait, segment, "thread waits on a rendition's input")
            input.pollSegments { noteSegmentInFlight($0, source: .foreignPoll) }
            return
        }
        guard variants.count > 1 else { return trace(source, segment, "no ladder") }
        let selection = variantSelection.withLock { $0 }
        guard selection.isAutomatic else { return trace(source, segment, "ABR off") }
        guard selection.requested == nil else { return trace(source, segment, "a switch is requested") }
        guard let variant = selection.selected, segment.variants.contains(variant) else {
            return trace(source, segment, "the variant read is not this lane's")
        }
        let ladder = abandonmentLadder(rejected: selection.rejected)
        let cursor = consumedSeconds
        let readPoint = readAheadState.withLock { $0 }
        guard cursor.isFinite, readPoint.isFinite else { return trace(source, segment, "no position yet") }
        // Before the segment starts what is queued of it can be dropped; inside it, only what is yet to be read.
        let isAhead = segment.start >= cursor
        let buffer = max((isAhead ? segment.start : readPoint) - cursor, 0)
        let progress = segment.progress
        let roundTrip = progress.firstAnswer ?? 0
        let download = AdaptiveBitrateLogic.Download(
            variant: variant, duration: segment.duration, bytes: progress.bytes, length: progress.length,
            elapsed: progress.elapsed, firstAnswer: progress.firstAnswer, transferring: progress.transferring,
            measuredBytes: progress.measuredBytes,
            isSuspended: progress.isSuspended)
        let evaluation = adaptiveBitrate.logic.evaluation(
            of: download, among: ladder, buffer: buffer, roundTrip: roundTrip, playlistLoad: isLive ? roundTrip : 0)
        guard case .abandon(let decision) = evaluation else {
            if case .keep(let refusal) = evaluation {
                return trace(source, segment, "kept: \(refusal.rawValue), buffer \(String(format: "%.1f", buffer)) s")
            }
            return
        }
        trace(source, segment, "gives up")
        if let last = adaptiveBitrate.abandonmentLog.last, last == (variant, segment.sequence) { return }
        adaptiveBitrate.abandonmentLog.last = (variant, segment.sequence)
        // Acted on only when asked for, and where the cut is the simple one: the segment is ahead of the position.
        var outcome = AbandonOutcome.refused("not asked for")
        if abandonsDownloads {
            outcome =
                isAhead
                ? requestAbandon(from: variant, to: decision.target, sequence: segment.sequence, start: segment.start)
                : .refused("the position is inside the segment")
        }
        let refusalText: String
        if case .refused(let reason) = outcome { refusalText = " (not acted on: \(reason))" } else { refusalText = "" }
        let format = { (value: Double) in String(format: "%.2f", value) }
        let rate = decision.loadRate.map { "\(Int($0 / 1000)) kbit/s" } ?? "estimate"
        let queued = queuedPosition(queueLockHeld: queueLockHeld)
        // What the cut at the new variant's first keyframe needs: the old packets from there on not handed out yet. Ahead of
        // the position, the segment's start is that keyframe. Inside it, the next keyframe the old variant has queued
        // is the nearest guess (a GOP of the new one is not known); none queued is a hole, which a re-read closes.
        let cutTime = isAhead ? segment.start : queued.nextKeyframe
        var verdict: String
        if isAhead {
            verdict = "segment ahead of the position (queued part can be cut)"
        } else if let next = queued.nextKeyframe, next < readPoint {
            verdict = "position inside the segment, next queued keyframe at \(format(next)) s (cut there)"
        } else {
            verdict = "position inside the segment, no keyframe queued ahead (re-read)"
        }
        // Sound muxed into the variant (TS) is cut with the picture: handed out past the cut, that keyframe will not do.
        // A separate rendition is not touched, whatever its cursor.
        if segment.hasMuxedAudio, let cursor = queued.audioCursor, let cutTime, cursor > cutTime {
            verdict += ", audio muxed and already past the cut (+\(format(cursor - cutTime)) s)"
        }
        let audio = queued.audioCursor.map { cursor in
            let ahead = cursor - self.consumedSeconds
            let kind = segment.hasMuxedAudio ? "muxed" : "separate"
            return "audio \(kind) \(format(cursor)) (\(ahead >= 0 ? "+" : "")\(format(ahead)) s of the video)"
        }
        AppLog.info(
            .demuxer,
            "ABR abandon\(refusalText): variant \(variant) (\(bandwidth(of: variant)) kbit/s) segment \(segment.sequence) "
                + "[\(format(segment.start))..\(format(segment.start + segment.duration)) s] to variant \(decision.target) (\(bandwidth(of: decision.target)) kbit/s): "
                + "\(progress.bytes >> 10)/\((progress.length ?? 0) >> 10) KB in \(format(progress.elapsed)) s at \(rate), "
                + "remaining \(format(decision.remaining)) s, buffer \(format(buffer)) s, lower \(format(decision.lower)) s; "
                + "video \(format(cursor)), \(audio ?? "no audio queued"), read to \(format(readPoint)), "
                + "GOP \(queued.gop.map(format) ?? "-") s, \(verdict)")
    }

    /// Where the queues stand, for the log: the audio packet next to be taken, the first video keyframe not handed out
    /// yet, and the queued GOPs' average length. Takes `queueLock` (after `lock`) unless the caller holds it.
    private func queuedPosition(queueLockHeld: Bool) -> (audioCursor: Double?, nextKeyframe: Double?, gop: Double?) {
        let read = { (demuxer: MediaDemuxer) -> (audioCursor: Double?, nextKeyframe: Double?, gop: Double?) in
            func seconds(_ pts: Int64, _ dts: Int64, _ base: AVRational) -> Double? {
                let time = pts != Int64.min ? pts : dts
                return time != Int64.min && base.den > 0 ? Double(time) * Double(base.num) / Double(base.den) : nil
            }
            let audio = demuxer.audioQueue.peek().flatMap { seconds($0.pts, $0.dts, demuxer.audioTimebase) }
            // A video packet is read with its own time base: a switch changes it while older packets still wait.
            let keyframes = demuxer.videoQueue.keyframeIndices.compactMap { index -> Double? in
                guard index >= demuxer.videoQueue.readIndex, let packet = demuxer.videoQueue.peekAt(index) else {
                    return nil
                }
                return seconds(packet.pts, packet.dts, packet.format.timebase)
            }
            let gop =
                keyframes.count > 1
                ? (keyframes[keyframes.count - 1] - keyframes[0]) / Double(keyframes.count - 1) : nil
            return (audio, keyframes.first, gop)
        }
        // The idle step holds `queueLock` already; inside the read it is released.
        return queueLockHeld ? read(self) : readingDescription(read)
    }
}

extension MediaDemuxer {
    /// A variant's bandwidth in kilobits a second, for the log.
    fileprivate func bandwidth(of id: Int) -> Int {
        (variants.first { $0.id == id }?.bandwidth ?? 0) / 1000
    }
}

extension MediaDemuxer {
    /// Seconds a ladder built for the check is kept: the variants' sizes and bandwidths do not change once opened.
    private static let ladderLifetime = 1.0
    /// Seconds between the checks made while the read-ahead is full and the thread idles.
    static let inFlightPollInterval = 0.1

    /// The switchable variants not rejected, as the rule takes them; rebuilt when a second old or `rejected` changed.
    fileprivate func abandonmentLadder(rejected: Set<Int>) -> [AdaptiveBitrateLogic.Variant] {
        let now = adaptiveTime
        if let cached = adaptiveBitrate.abandonmentLadder, cached.rejected == rejected,
            now - cached.builtAt < Self.ladderLifetime
        {
            return cached.ladder
        }
        let ladder = variants.filter { $0.isSwitchable && !rejected.contains($0.id) }.map {
            AdaptiveBitrateLogic.Variant(id: $0.id, bandwidth: $0.bandwidth, pixels: $0.width * $0.height)
        }
        adaptiveBitrate.abandonmentLadder = (now, rejected, ladder)
        return ladder
    }

    /// The check while the read-ahead is full: the thread idles, the segment goes on downloading in the background and
    /// nothing waits for it, so the wait's check does not run. Every `inFlightPollInterval`, behind `lock` and `queueLock`.
    func pollInFlightSegments() {
        let now = adaptiveTime
        guard now >= adaptiveBitrate.nextInFlightPoll, variants.count > 1 else { return }
        adaptiveBitrate.nextInFlightPoll = now + Self.inFlightPollInterval
        var polled = false
        input.pollSegments {
            polled = true
            noteSegmentInFlight($0, queueLockHeld: true, source: .idle)
        }
        if !polled { trace(.idle, nil, "idle poll: no picture download in flight (pollProgress nil)") }
    }
}

extension MediaDemuxer {
    /// Where a check of a download came from.
    enum CheckSource: String {
        /// The thread waits for this download's own bytes.
        case wait
        /// The read-ahead is full and the thread idles (`pollInFlightSegments`).
        case idle
        /// The thread waits on another input's bytes (a rendition's).
        case foreignWait
        /// The thread waits on another input's bytes and the picture's download is asked about from there.
        case foreignPoll
    }

    /// What the checks of the last second saw (`trace`).
    struct AbandonTrace {
        var emittedAt = 0.0
        var counts: [CheckSource: Int] = [:]
        var last = "-"
        var seen = "none"
    }

    /// Set `NITS_ABR_TRACE` to log, once a second while a download is watched, where the checks came from and why the rule
    /// kept the download: for a measurement of a check that never fires.
    static let isTracing = ProcessInfo.processInfo.environment["NITS_ABR_TRACE"] != nil

    fileprivate func trace(_ source: CheckSource, _ segment: InFlightSegment?, _ reason: String) {
        guard Self.isTracing else { return }
        adaptiveBitrate.trace.counts[source, default: 0] += 1
        if let segment {
            let progress = segment.progress
            adaptiveBitrate.trace.seen =
                "\(segment.variants.isEmpty ? "rendition" : "variant \(segment.variants)") segment \(segment.sequence), "
                + "\(progress.bytes >> 10) KB in \(String(format: "%.1f", progress.elapsed)) s"
        }
        // The picture's own reasons stand over a rendition's wait.
        if source != .foreignWait || adaptiveBitrate.trace.last == "-" { adaptiveBitrate.trace.last = reason }
        let now = adaptiveTime
        guard now - adaptiveBitrate.trace.emittedAt >= 1 else { return }
        let counts = adaptiveBitrate.trace.counts
        AppLog.info(
            .demuxer,
            "ABR abandon trace: t \(String(format: "%.1f", now)) s, checks wait \(counts[.wait] ?? 0) idle \(counts[.idle] ?? 0) polled-from-foreign \(counts[.foreignPoll] ?? 0) "
                + "foreign \(counts[.foreignWait] ?? 0); last segment seen: \(adaptiveBitrate.trace.seen); "
                + adaptiveBitrate.trace.last)
        adaptiveBitrate.trace.emittedAt = now
        adaptiveBitrate.trace.counts = [:]
        adaptiveBitrate.trace.last = "-"
    }
}

extension MediaDemuxer {
    /// Whether the check gives a download up (`NITS_ABR_ABANDON=1`): off by default, until the cut that makes the switch
    /// invisible is made (5b-3). A test sets `abandonsDownloads` on its demuxer.
    static let abandonsEnabled = ProcessInfo.processInfo.environment["NITS_ABR_ABANDON"] == "1"

    /// A download given up for a lower variant's of the same segment: the switch is made at the next read.
    struct PendingAbandon: Sendable, Equatable {
        /// The variant whose download is given up, the one it is replaced by, and the segment (media sequence number).
        let from: Int
        let target: Int
        let sequence: Int
        /// Where the segment starts on the timeline (seconds).
        let start: Double
    }

    /// What came of a request to give a download up.
    enum AbandonOutcome: Equatable {
        case requested
        /// Why not: said in the log.
        case refused(String)

        var isRequested: Bool { self == .requested }
    }

    /// Gives up the download in flight of variant `from`'s segment `sequence` for `target`'s, which reads it from its start
    /// (`DemuxerInput.joinNext`): the bytes stop now (the read that waits for them is interrupted), the switch itself is
    /// made at the next read (`beginRequestedVariantSwitch`), between packets, never inside the input's read. A target still
    /// described as another variant (a rung of a ladder that was probed once) is taken as that: its first read verifies it
    /// (`verifyVariantSwitchTarget`), and a switch that fails there is given up, the old variant read again. Refused, with the
    /// reason, when it cannot be done: a switch is under way, or `target` is rejected, or has not the segment
    /// to read from its start (`DemuxerInput.canJoin`: a discontinuity, a live playlist that moved on).
    func requestAbandon(from: Int, to target: Int, sequence: Int, start: Double) -> AbandonOutcome {
        guard variantSwitch == nil, adaptiveBitrate.pendingAbandon == nil else {
            return .refused("a switch is under way")
        }
        guard input.variantDescription(id: target) != .rejected else { return .refused("the variant is rejected") }
        if let refusal = input.canJoin(variant: target, sequence: sequence) { return .refused(refusal.rawValue) }
        adaptiveBitrate.pendingAbandon = PendingAbandon(from: from, target: target, sequence: sequence, start: start)
        input.abandonDownload(ofVariant: from)
        adaptiveBitrate.logic.noteAbandoned(at: adaptiveTime)
        return .requested
    }
}

// MARK: - The cut

extension MediaDemuxer {
    /// The sound the demuxer plays is the old variant's own, muxed into its segments (MPEG-TS), not a rendition both have.
    private func isOldAudioMuxed(_ pending: VariantSwitch) -> Bool {
        isAudioMuxed(oldStreams: pending.previous, newStreams: pending.streams)
    }

    private func isAudioMuxed(oldStreams: VariantStreams, newStreams: VariantStreams) -> Bool {
        audioStreamIndex >= 0 && Set(oldStreams.audio).subtracting(newStreams.audio).contains(audioStreamIndex)
    }

    /// `ticks` of the video time base in the audio's.
    private func audioTicks(fromVideo ticks: Int64) -> Int64 {
        av_rescale_q(ticks, timebase, audioTimebase)
    }

    private func videoTicks(fromAudio ticks: Int64) -> Int64 {
        av_rescale_q(ticks, audioTimebase, timebase)
    }

    /// Takes the tail of the queues out, from the picture at queue index `videoIndex` (nil: no picture is cut) and the
    /// sound muxed into the old variant from `audioPTS` (nil: it is not): what the new variant reads again from its
    /// keyframe. The account of what was read follows: the last picture's decode time (a tick before the cut when nothing is
    /// left, so the next switch does not wait for a keyframe that is behind it), and the point the read-ahead has reached,
    /// which a read of the new variant sets up again (`recordReadAhead` only goes forward). False when the sound was
    /// handed out past `audioPTS` and could not be cut (nothing of it is taken, the pictures' tail is).
    @discardableResult
    private func cutQueuedTail(videoIndex: Int?, audioPTS: Int64?, atSeconds seconds: Double) -> Bool {
        let firstCut = videoIndex.flatMap { videoQueue.peekAt($0) }
        if let videoIndex { videoQueue.truncate(from: videoIndex) }
        var isSoundCut = true
        if let audioPTS { isSoundCut = audioQueue.truncate(fromPTS: audioPTS) }
        if let last = videoQueue.lastElement {
            lastVideoReadTime = last.dts != Int64.min ? last.dts : last.pts
        } else if let firstCut {
            let time = firstCut.dts != Int64.min ? firstCut.dts : firstCut.pts
            if time != Int64.min { lastVideoReadTime = time - 1 }
        }
        readAheadState.withLock { $0 = min($0, seconds) }
        return isSoundCut
    }

    /// The new variant's keyframe at `time`, with the old variant's download given up: the old variant's pictures from the
    /// keyframe of the same presentation time are cut, and its sound (muxed into it) from the time in the audio's time
    /// base, and the new variant's take over at once. Only when nothing at or after the cut is handed out: the old
    /// keyframe is ahead of the cursor, and the sound's cursor is before the cut; else false, and the next keyframe of the
    /// new variant is tried (each refusal for the sound is logged, as the cost of a cursor that runs ahead of the picture
    /// is for the measurement to show). With no old keyframe of that time and the old pictures ending before this one,
    /// there is nothing to cut: the ordinary splice (the old variant's partial segment ended earlier, which leaves a hole).
    func spliceAbandoned(at time: Int64, keyframe: Data?, pending: VariantSwitch) -> Bool {
        let oldIndex = videoQueue.keyframeIndex(withPTS: time)
        if oldIndex == nil, time < pending.previousVideoTime { return false }
        let isMuxed = isOldAudioMuxed(pending)
        let audioTime = audioTicks(fromVideo: time)
        // The sound is past the cut: this keyframe will not do.
        if isMuxed, audioQueue.lastHandedOutPTS >= audioTime {
            let now = adaptiveTime
            if now - adaptiveBitrate.lastSpliceRefusal >= 0.5 {
                adaptiveBitrate.lastSpliceRefusal = now
                let seconds = { (ticks: Int64, base: AVRational) in Double(ticks) * Double(base.num) / Double(base.den)
                }
                AppLog.info(
                    .demuxer,
                    "\(streamingName): keyframe at \(String(format: "%.2f", seconds(time, timebase))) s is not cut at: the sound is handed out to "
                        + "\(String(format: "%.2f", seconds(audioQueue.lastHandedOutPTS, audioTimebase))) s")
            }
            return false
        }
        guard spliceVariantVideo(at: time, keyframe: keyframe) else { return false }
        let seconds = Double(time) * Double(timebase.num) / Double(timebase.den)
        cutQueuedTail(videoIndex: oldIndex, audioPTS: isMuxed ? audioTime : nil, atSeconds: seconds)
        AppLog.info(
            .demuxer,
            "\(streamingName): the download of variant \(pending.abandoned?.from ?? -1) given up was cut at \(String(format: "%.2f", seconds)) s"
                + (oldIndex == nil ? " (nothing queued of it past that)" : ""))
        // The old variant's sound is read no more: the new one's, held until now, takes over, not a second on.
        if variantSwitch != nil { spliceVariantAudio(releasingHeld: true) }
        return true
    }

    /// What reading a download given up again does with what is queued of it.
    enum AbandonedRestart: Equatable {
        /// Cut the pictures at the queued keyframe at `index` (and the sound muxed into the variant at its time): `atStart`
        /// is the keyframe the segment starts with, read again from its start; else a later one, inside the segment, and
        /// the segment is read again with what comes before that keyframe dropped (a landing), the start being handed out.
        case cut(index: Int, atStart: Bool)
        /// Nothing of the segment is queued, but playback has got to its start: what was not read is lost, and the
        /// variant reads on from the segment after.
        case nextSegment
        /// Nothing of it is queued, and nothing handed out: from its start.
        case fromStart
    }

    /// Chooses what to do with the queued part of a segment whose download was given up and is read again. `keyframes` are
    /// the old variant's queued keyframes not handed out, in order (queue index, presentation time); `start` is the
    /// segment's start and `slack` how far the media's may be from the timeline's, in the video time base. `soundHandedOut` is
    /// where the sound muxed into the old variant is handed out to (video time base), when it is and has been.
    ///
    /// The first keyframe at or after the segment's start (less `slack`), and after the sound handed out (a cut behind
    /// the sound would leave its read again over what is handed out), is the cut. It is the segment's own start only when
    /// within `slack` of it: a later one is inside the segment, whose start is handed out already, and cutting there while
    /// reading the segment from its start would queue what is before it twice.
    static func restartPlan(
        start: Int64, slack: Int64, keyframes: [(index: Int, pts: Int64)], isStartHandedOut: Bool,
        soundHandedOut: Int64?
    ) -> AbandonedRestart {
        var minimum = start - slack
        if let soundHandedOut { minimum = max(minimum, soundHandedOut + 1) }
        if let key = keyframes.first(where: { $0.pts >= minimum }) {
            return .cut(index: key.index, atStart: abs(key.pts - start) <= slack)
        }
        let isSoundIn = soundHandedOut.map { $0 >= start - slack } ?? false
        return isStartHandedOut || isSoundIn ? .nextSegment : .fromStart
    }

    /// A download given up for a switch that did not come (`beginRequestedVariantSwitch` could not make it, or the switch was
    /// given up before its splice): the old variant reads the segment again. What it had queued of it is cut first, so the
    /// decoder does not get the same times twice (`restartPlan`).
    func restartAbandonedDownload(_ abandoned: PendingAbandon) {
        let perSecond = Double(timebase.den) / Double(max(timebase.num, 1))
        let start = Int64((abandoned.start * perSecond).rounded())
        // The timeline's start of a segment is summed from durations, and the media's may differ a little.
        let slack = Int64(0.1 * perSecond)
        let keyframes = videoQueue.keyframeIndices.compactMap { index -> (index: Int, pts: Int64)? in
            guard index >= videoQueue.readIndex, let packet = videoQueue.peekAt(index) else { return nil }
            return (index, packet.effectivePTS)
        }
        let isMuxed =
            variantStreams[abandoned.from].flatMap { old in
                variantStreams[abandoned.target].map { isAudioMuxed(oldStreams: old, newStreams: $0) }
            } ?? false
        let sound =
            isMuxed && audioQueue.lastHandedOutPTS != Int64.min
            ? videoTicks(fromAudio: audioQueue.lastHandedOutPTS) : nil
        let plan = Self.restartPlan(
            start: start, slack: slack, keyframes: keyframes,
            isStartHandedOut: consumedSeconds >= abandoned.start - 0.1,
            soundHandedOut: sound)
        switch plan {
        case .cut(let index, let atStart):
            let key = videoQueue.peekAt(index)?.effectivePTS ?? start
            // The lane lands on the first keyframe at or after the time given: a hair before this one is the same landing, and
            // a time rounded up past it would miss the keyframe and land on the next, a GOP on.
            let seconds = Double(key) / perSecond
            let isSoundCut = cutQueuedTail(
                videoIndex: index, audioPTS: isMuxed ? audioTicks(fromVideo: key) : nil, atSeconds: seconds)
            if isSoundCut {
                input.restartDownload(
                    ofVariant: abandoned.from, atSequence: abandoned.sequence,
                    landingSeconds: atStart ? nil : seconds - 0.005)
            } else {
                // Cannot happen (the plan keeps behind the sound handed out): read on after the segment, with no repeat.
                AppLog.warning(
                    .demuxer, "\(streamingName): the sound could not be cut; the rest of a segment given up is lost")
                input.restartDownload(
                    ofVariant: abandoned.from, atSequence: abandoned.sequence + 1, landingSeconds: nil)
            }
        case .nextSegment:
            AppLog.warning(
                .demuxer,
                "\(streamingName): a download given up is read again after playback reached its segment: the rest of it is lost"
            )
            input.restartDownload(ofVariant: abandoned.from, atSequence: abandoned.sequence + 1, landingSeconds: nil)
        case .fromStart:
            input.restartDownload(ofVariant: abandoned.from, atSequence: abandoned.sequence, landingSeconds: nil)
        }
    }
}
