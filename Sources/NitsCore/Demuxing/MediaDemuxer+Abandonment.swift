import CFFmpeg
import Foundation

/// Whether the segment being downloaded should be given up for one of a lower variant
/// (`AdaptiveBitrateLogic.abandonment(of:among:buffer:roundTrip:)`), and the cut that splices the lower one in. Each
/// decision is logged with where the segment is against the playing position. Background: "Adaptive bitrate" in
/// `docs/ARCHITECTURE.md`.
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

    /// What came of the checks of the segments in flight, so each is acted on and logged once: a segment is decided when
    /// its download was given up or refused for good (`AbandonRefusal.isFinal`); a passing refusal leaves it to the next
    /// check, and is logged once while it lasts.
    struct AbandonmentLog: Sendable {
        private(set) var decided: (variant: Int, sequence: Int)?
        private(set) var passing: (variant: Int, sequence: Int, refusal: AbandonRefusal)?

        func isDecided(variant: Int, sequence: Int) -> Bool {
            decided.map { $0 == (variant, sequence) } ?? false
        }

        /// Notes what came of a check of `variant`'s segment `sequence`; whether it is new to the log.
        mutating func record(_ outcome: AbandonOutcome, variant: Int, sequence: Int) -> Bool {
            if case .refused(let refusal) = outcome, !refusal.isFinal {
                if let passing, passing == (variant, sequence, refusal) { return false }
                passing = (variant, sequence, refusal)
                return true
            }
            decided = (variant, sequence)
            passing = nil
            return true
        }

        /// The segment is checked again: its download given up is read again (the switch did not come), on the same link.
        mutating func reopen(variant: Int, sequence: Int) {
            if isDecided(variant: variant, sequence: sequence) { decided = nil }
        }
    }

    /// Where the cut of a segment given up would be, against the position (`abandonPlace`).
    enum AbandonPlace: Equatable {
        /// The segment starts at or after the position: what is queued of it is cut at its start.
        case ahead
        /// The position is inside the segment and the old variant has a keyframe queued (not handed out) inside it, at
        /// `keyframe` seconds: the new variant's keyframe of that time is the cut, if the variants' GOPs line up.
        case inside(keyframe: Double)
        /// The position is inside the segment and nothing queued of it can be cut at.
        case insideWithoutKeyframe
    }

    /// Where a segment of `start` / `duration` seconds given up is cut, with the position at `cursor`. `keyframes` are the
    /// times of the old variant's queued keyframes not handed out, in order; `muxedSoundHandedOut` is the time of the last
    /// packet of the sound muxed into the old variant handed out, when it is muxed and one was: a keyframe at or before
    /// it is no cut, as the sound would be cut there too (`spliceAbandoned` refuses it).
    static func abandonPlace(
        start: Double, duration: Double, cursor: Double, keyframes: [Double], muxedSoundHandedOut: Double?
    ) -> AbandonPlace {
        if start >= cursor { return .ahead }
        let isCut = { (keyframe: Double) in
            keyframe >= start && keyframe < start + duration && muxedSoundHandedOut.map { keyframe > $0 } ?? true
        }
        guard let keyframe = keyframes.first(where: isCut) else { return .insideWithoutKeyframe }
        return .inside(keyframe: keyframe)
    }

    /// Where a give-up with the position inside the segment and nothing of it queued to cut at (`insideWithoutKeyframe`)
    /// expects the new variant's keyframe: the old variant's next one past what is read (`after`), by the spacing of the
    /// keyframes it has queued (`known`, in order, handed out or not: `KeyframeTrail`, which a live stream with no
    /// history keeps too); the variants of a ladder put theirs at the same times, and the splice takes the new variant's next one if
    /// not (`spliceAbandoned`). Nil when the lower variant is to join the next segment instead: fewer than two keyframes
    /// known (no spacing), or the next one falls at the segment's end, as with a keyframe a segment.
    static func expectedHoleCut(start: Double, duration: Double, after: Double, known: [Double]) -> Double? {
        let end = start + duration
        let read = known.filter { $0 <= after && $0 < end }
        let gaps = zip(read, read.dropFirst()).map { $1 - $0 }.filter { $0 > 0.01 }.suffix(8).sorted()
        guard let last = read.last, !gaps.isEmpty else { return nil }
        let gop = gaps[gaps.count / 2]
        var next = last + gop
        while next <= after { next += gop }
        return next < end - gop / 2 ? next : nil
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
        if let gate = abandonCheckGate, !gate(segment, cursor) { return trace(source, segment, "held by the test") }
        // Where the cut would be (`abandonPlace`); the queue is looked at only with the position inside the segment. What
        // plays before the new variant must bring the segment: up to its start when it is ahead, up to the cut inside it.
        var queued: QueuedPosition?
        let place: AbandonPlace
        if segment.start >= cursor {
            place = .ahead
        } else {
            let position = queuedPosition(queueLockHeld: queueLockHeld)
            queued = position
            place = Self.abandonPlace(
                start: segment.start, duration: segment.duration, cursor: cursor, keyframes: position.keyframes,
                muxedSoundHandedOut: segment.hasMuxedAudio ? position.soundHandedOut : nil)
        }
        // Inside the segment the lower variant must reach the keyframe it is cut in at (`cutOffset`: no hole). With
        // nothing of the segment queued to cut at, the old pictures play as they come: it is cut in past them, at the
        // keyframe expected next (`expectedHoleCut`) or at the next segment's start, and what is between is skipped
        // (`hole`). Refusing it left the download to play out: 15 → 1.5 Mbit/s at 3 s, 29.4 s of stall.
        let cut: Double?
        let playable: Double
        var cutOffset: Double?
        var hole: AdaptiveBitrateLogic.Hole?
        var joinSequence = segment.sequence
        switch place {
        case .ahead: (cut, playable) = (segment.start, segment.start)
        case .inside(let keyframe):
            (cut, playable) = (keyframe, keyframe)
            cutOffset = keyframe - segment.start
        case .insideWithoutKeyframe:
            let position = queued ?? queuedPosition(queueLockHeld: queueLockHeld)
            let expected =
                abandonExpectsKeyframes
                ? Self.expectedHoleCut(
                    start: segment.start, duration: segment.duration, after: readPoint,
                    known: position.readKeyframes) : nil
            let end = segment.start + segment.duration
            if expected == nil { joinSequence = segment.sequence + 1 }
            (cut, playable) = (expected ?? end, readPoint)
            hole = AdaptiveBitrateLogic.Hole(
                reach: expected.map { $0 - segment.start } ?? 0, skipped: max((expected ?? end) - readPoint, 0))
        }
        let buffer = max(playable - cursor, 0)
        let progress = segment.progress
        let roundTrip = progress.firstAnswer ?? 0
        let download = AdaptiveBitrateLogic.Download(
            variant: variant, duration: segment.duration, bytes: progress.bytes, length: progress.length,
            elapsed: progress.elapsed, firstAnswer: progress.firstAnswer, transferring: progress.transferring,
            measuredBytes: progress.measuredBytes,
            isSuspended: progress.isSuspended)
        let evaluation = adaptiveBitrate.logic.evaluation(
            of: download, among: ladder, buffer: buffer, roundTrip: roundTrip, playlistLoad: isLive ? roundTrip : 0,
            cutOffset: cutOffset, hole: hole)
        guard case .abandon(let decision) = evaluation else {
            if case .keep(let refusal) = evaluation {
                return trace(source, segment, "kept: \(refusal.rawValue), buffer \(String(format: "%.1f", buffer)) s")
            }
            return
        }
        trace(source, segment, "gives up")
        if adaptiveBitrate.abandonmentLog.isDecided(variant: variant, sequence: segment.sequence) { return }
        // The cut at the new variant's keyframe needs the old packets from there on not handed out yet: ahead of the
        // position, the segment's start; inside it, a keyframe the old variant has queued inside the segment, if the new
        // one has a keyframe of the same time (`spliceAbandoned`; else the ordinary splice, a gap); with none queued, a
        // keyframe past what is read, of this segment or the next (a hole).
        var outcome = AbandonOutcome.refused(.notAskedFor)
        // The give-up replaces a switch not spliced yet: it goes no higher than where that one was going (a target since
        // rejected is no bound).
        let target =
            replaceableSwitch.flatMap { pending -> Int? in
                guard !selection.rejected.contains(pending.target.id),
                    let chosen = variants.first(where: { $0.id == decision.target }),
                    chosen.bandwidth > pending.target.bandwidth
                else { return nil }
                return pending.target.id
            } ?? decision.target
        if abandonsDownloads {
            outcome = requestAbandon(
                from: variant, to: target, sequence: segment.sequence, start: segment.start,
                cut: place == .ahead ? nil : cut, joinSequence: joinSequence, download: download)
        }
        guard adaptiveBitrate.abandonmentLog.record(outcome, variant: variant, sequence: segment.sequence) else {
            return
        }
        let queuedNow = queued ?? queuedPosition(queueLockHeld: queueLockHeld)
        let refusalText: String
        if case .refused(let refusal) = outcome {
            refusalText = " (not acted on: \(refusal.text)\(refusal.isFinal ? "" : ", asked again"))"
        } else {
            refusalText = ""
        }
        let format = { (value: Double) in String(format: "%.2f", value) }
        let rate = decision.loadRate.map { "\(Int($0 / 1000)) kbit/s" } ?? "estimate"
        var verdict: String
        switch place {
        case .ahead:
            verdict = "segment ahead of the position (queued part can be cut)"
        case .inside(let keyframe):
            verdict = "position inside the segment, queued keyframe at \(format(keyframe)) s (cut there)"
        case .insideWithoutKeyframe:
            verdict = "position inside the segment, no keyframe of it queued ahead of the sound handed out"
            if let hole, let cut {
                verdict +=
                    joinSequence == segment.sequence
                    ? "; cut in at the keyframe expected at \(format(cut)) s, a hole of \(format(hole.skipped)) s"
                    : "; joins segment \(joinSequence) at \(format(cut)) s, a hole of \(format(hole.skipped)) s"
            }
        }
        // Sound muxed into the variant (TS) is cut with the picture: handed out past the cut, that keyframe will not do.
        // A separate rendition is not touched, whatever its cursor.
        if segment.hasMuxedAudio, let handedOut = queuedNow.soundHandedOut, let cut, handedOut >= cut {
            verdict += ", audio muxed and already handed out past the cut (+\(format(handedOut - cut)) s)"
        }
        let audio = queuedNow.audioCursor.map { cursor in
            let ahead = cursor - self.consumedSeconds
            let kind = segment.hasMuxedAudio ? "muxed" : "separate"
            return "audio \(kind) \(format(cursor)) (\(ahead >= 0 ? "+" : "")\(format(ahead)) s of the video)"
        }
        AppLog.info(
            .demuxer,
            "ABR abandon\(refusalText): \(streamingName): variant \(variant) (\(bandwidth(of: variant)) kbit/s) segment \(segment.sequence) "
                + "[\(format(segment.start))..\(format(segment.start + segment.duration)) s] to variant \(target) (\(bandwidth(of: target)) kbit/s): "
                + "\(progress.bytes >> 10)/\((progress.length ?? 0) >> 10) KB in \(format(progress.elapsed)) s at \(rate), "
                + "remaining \(format(decision.remaining)) s, buffer \(format(buffer)) s, lower \(format(decision.lower)) s; "
                + "video \(format(cursor)), \(audio ?? "no audio queued"), read to \(format(readPoint)), "
                + "GOP \(queuedNow.gop.map(format) ?? "-") s, \(verdict)")
    }

    /// Where the queues stand (seconds): the audio packet next to be taken, the last one handed out (an empty queue has
    /// no next packet, but the sound is handed out all the same), the video keyframes not handed out yet, in order, and
    /// the queued GOPs' average length.
    struct QueuedPosition {
        let audioCursor: Double?
        let soundHandedOut: Double?
        let keyframes: [Double]
        let gop: Double?
        /// The latest video keyframes queued, handed out or not, in order (`KeyframeTrail`: kept with no history too, live).
        let readKeyframes: [Double]
    }

    /// Takes `queueLock` (after `lock`) unless the caller holds it.
    private func queuedPosition(queueLockHeld: Bool) -> QueuedPosition {
        let read = { (demuxer: MediaDemuxer) -> QueuedPosition in
            func seconds(_ pts: Int64, _ dts: Int64, _ base: AVRational) -> Double? {
                let time = pts != Int64.min ? pts : dts
                return time != Int64.min && base.den > 0 ? Double(time) * Double(base.num) / Double(base.den) : nil
            }
            let audio = demuxer.audioQueue.peek().flatMap { seconds($0.pts, $0.dts, demuxer.audioTimebase) }
            let handedOut = seconds(demuxer.audioQueue.lastHandedOutPTS, Int64.min, demuxer.audioTimebase)
            // A video packet is read with its own time base: a switch changes it while older packets still wait.
            let queue = demuxer.videoQueue
            let time = { (index: Int) -> Double? in
                queue.peekAt(index).flatMap { seconds($0.pts, $0.dts, $0.format.timebase) }
            }
            let keyframes = queue.keyframeIndices.filter { $0 >= queue.readIndex }.compactMap(time)
            let gop =
                keyframes.count > 1
                ? (keyframes[keyframes.count - 1] - keyframes[0]) / Double(keyframes.count - 1) : nil
            return QueuedPosition(
                audioCursor: audio, soundHandedOut: handedOut, keyframes: keyframes, gop: gop,
                readKeyframes: demuxer.keyframeTrail.times)
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
            "ABR abandon trace: \(streamingName): t \(String(format: "%.1f", now)) s, checks wait \(counts[.wait] ?? 0) idle \(counts[.idle] ?? 0) polled-from-foreign \(counts[.foreignPoll] ?? 0) "
                + "foreign \(counts[.foreignWait] ?? 0); last segment seen: \(adaptiveBitrate.trace.seen); "
                + adaptiveBitrate.trace.last)
        adaptiveBitrate.trace.emittedAt = now
        adaptiveBitrate.trace.counts = [:]
        adaptiveBitrate.trace.last = "-"
    }
}

extension MediaDemuxer {
    /// Whether the check gives a download up: on unless `NITS_ABR_ABANDON=0`, which leaves the decisions logged only (to
    /// compare). A test sets `abandonsDownloads` on its demuxer.
    static let abandonsEnabled = ProcessInfo.processInfo.environment["NITS_ABR_ABANDON"] != "0"

    /// A download given up for a lower variant's of the same segment: the switch is made at the next read.
    struct PendingAbandon: Sendable, Equatable {
        /// The variant whose download is given up, the one it is replaced by, and the segment (media sequence number).
        let from: Int
        let target: Int
        let sequence: Int
        /// Where the segment starts on the timeline (seconds).
        let start: Double
        /// With the position inside the segment, the old variant's queued keyframe (seconds) the new one is to be cut in
        /// at, or the keyframe expected past what is read when none is queued; nil when the segment is ahead of the
        /// position. For the log of the splice.
        var cut: Double? = nil
        /// The segment the new variant reads from its start, when not `sequence`: the next one, with nothing of `sequence`
        /// queued to cut at and no keyframe of it expected past what is read (`expectedHoleCut`); the rest of `sequence`
        /// is skipped. A switch that does not come reads `sequence` again all the same.
        var joinSequence: Int? = nil

        var joinedSequence: Int { joinSequence ?? sequence }
    }

    /// Why a download the rule gives up is not.
    enum AbandonRefusal: Equatable, Sendable {
        /// `abandonsDownloads` is off: logged only.
        case notAskedFor
        /// A switch is spliced or took a download over itself, or another download given up waits for its switch.
        case switchUnderWay
        case rejected
        case join(JoinRefusal)

        /// Whether it holds for the segment for good; a passing one (the switch made, a target's playlist a reload behind) is asked again.
        var isFinal: Bool {
            switch self {
            case .switchUnderWay: false
            // A playlist of the target that lags a reload behind (live) lists the segment a moment later.
            case .join(let refusal): refusal != .noSegment
            case .notAskedFor, .rejected: true
            }
        }

        var text: String {
            switch self {
            case .notAskedFor: "not asked for"
            case .switchUnderWay: "a switch is under way"
            case .rejected: "the variant is rejected"
            case .join(let refusal): refusal.rawValue
            }
        }
    }

    /// What came of a request to give a download up.
    enum AbandonOutcome: Equatable {
        case requested
        case refused(AbandonRefusal)

        var isRequested: Bool { self == .requested }
    }

    /// The switch under way a give-up replaces: one not spliced yet that did not take a download over itself. The one
    /// place that says which (`requestAbandon`, and the bound on the give-up's target in `noteSegmentInFlight`).
    var replaceableSwitch: VariantSwitch? {
        variantSwitch.flatMap { $0.spliceTime == nil && !$0.isPreviousAbandoned ? $0 : nil }
    }

    /// Gives up the download in flight of variant `from`'s segment `sequence` for `target`'s, which reads it from its start
    /// (`DemuxerInput.joinNext`): the bytes stop now (the read that waits for them is interrupted), the switch itself is
    /// made at the next read (`beginRequestedVariantSwitch`), between packets, never inside the input's read. A target still
    /// described as another variant (a rung of a ladder that was probed once) is taken as that: its first read verifies it
    /// (`verifyVariantSwitchTarget`), and a switch that fails there is given up, the old variant read again. Refused, with the
    /// reason, when it cannot be done: a switch is spliced or took a download over itself (one not spliced yet is replaced),
    /// or another download given up waits for its switch, or `target` is rejected, or has not the segment
    /// to read from its start (`DemuxerInput.canJoin`: a discontinuity, a live playlist that moved on, or not there yet).
    /// `cut` is the keyframe the cut is expected at when the position is inside the segment; `joinSequence` the segment
    /// the new variant reads from its start, when not `sequence` (`PendingAbandon.joinSequence`); `download` is what the
    /// rule judged, which the estimate learns from (`AdaptiveBitrateLogic.noteAbandoned`).
    func requestAbandon(
        from: Int, to target: Int, sequence: Int, start: Double, cut: Double? = nil, joinSequence: Int? = nil,
        download: AdaptiveBitrateLogic.Download? = nil
    ) -> AbandonOutcome {
        // A switch not spliced yet is replaced (`replaceableSwitch`; `beginRequestedVariantSwitch` gives it up): it joined
        // the segment after this one, and would splice only once this download came whole, sharing the link with the new variant's (on the
        // shaping proxy, 2 Mbit/s after ~90: 35 s for 8 s of the top variant, a stall of 7.3 s). hls.js checks a fragment
        // of another level than the one chosen for the same reason (`fragBlockingSwitch`). A switch spliced, or one that
        // took a download over itself, is left to finish.
        if variantSwitch != nil, replaceableSwitch == nil {
            return .refused(.switchUnderWay)
        }
        guard adaptiveBitrate.pendingAbandon == nil else { return .refused(.switchUnderWay) }
        guard input.variantDescription(id: target) != .rejected else { return .refused(.rejected) }
        let joins = joinSequence ?? sequence
        if let refusal = input.canJoin(variant: target, sequence: joins) { return .refused(.join(refusal)) }
        adaptiveBitrate.pendingAbandon = PendingAbandon(
            from: from, target: target, sequence: sequence, start: start, cut: cut,
            joinSequence: joins == sequence ? nil : joins)
        input.abandonDownload(ofVariant: from)
        let before = adaptiveBitrate.logic.estimate
        adaptiveBitrate.logic.noteAbandoned(
            at: adaptiveTime, download: download, targetBandwidth: variants.first { $0.id == target }?.bandwidth,
            abandonedBandwidth: variants.first { $0.id == from }?.bandwidth)
        let kbps = { (value: Double?) in value.map { "\(Int($0 / 1000)) kbit/s" } ?? "none" }
        let (was, now) = (kbps(before), kbps(adaptiveBitrate.logic.estimate))
        if was != now {
            AppLog.info(.demuxer, "ABR abandon estimate: \(streamingName): \(was) -> \(now) for variant \(target)")
        }
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

    /// The new variant's keyframe at `time` (its own time base), with the old variant's download given up, spliced in as
    /// ExoPlayer splices a chunk (`SampleQueue.attemptSplice`): the old pictures not handed out are cut from the first one in
    /// decode order presented at or after the keyframe, whatever the old variant's keyframes (the variants' segments need
    /// not start on keyframes of the same time); what is kept is a prefix in decode order, all of it decodable and presented
    /// before the keyframe, so the variants never mix (a B-frame presented just before it may be lost: a picture repeated,
    /// not a hole). Refused, and the next keyframe of the new variant tried, when a picture presented at or after it is
    /// handed out already (`largestHandedOutPTS`, not the last one: with B-frames that one is not the latest).
    ///
    /// The sound the old variant has of its own (muxed into it, or a rendition the new one does not share) is cut on its
    /// own: from the keyframe's time or, handed out past it, from just after what is handed out; the new variant's, held
    /// until now, takes over from the same time, at its first packet there or after (ExoPlayer splices each queue at its
    /// own first sample past the cut); what it has before is dropped.
    func spliceAbandoned(at time: Int64, keyframe: Data?, pending: VariantSwitch) -> Bool {
        let newBase = pending.streams.video.flatMap { input.stream($0)?.pointee.time_base } ?? timebase
        // The old pictures are in the old time base, which is the demuxer's until the splice.
        let cut = av_rescale_q(time, newBase, timebase)
        let toSeconds = { (ticks: Int64, base: AVRational) in
            Double(ticks) * Double(base.num) / Double(max(base.den, 1))
        }
        let format = { (value: Double) in String(format: "%.3f", value) }
        let handedOut = videoQueue.largestHandedOutPTS
        if handedOut != Int64.min, handedOut >= cut {
            logSpliceRefusal(
                "keyframe at \(format(toSeconds(cut, timebase))) s is not cut at: a picture at "
                    + "\(format(toSeconds(handedOut, timebase))) s is handed out")
            return false
        }
        let isOwnAudio = isOldAudioMuxed(pending)
        // The old sound's cut (its time base), and the same time in the new sound's.
        var audioCut: Int64?
        var newAudioCut: Int64?
        if isOwnAudio {
            var from = av_rescale_q(time, newBase, audioTimebase)
            if audioQueue.lastHandedOutPTS != Int64.min { from = max(from, audioQueue.lastHandedOutPTS + 1) }
            audioCut = from
            let newAudioBase = input.stream(pending.audioStream)?.pointee.time_base ?? audioTimebase
            newAudioCut = av_rescale_q(from, audioTimebase, newAudioBase)
        }
        let index = videoQueue.firstIndex(atOrAfterPTS: cut)
        // For the log: what of the old variant is cut, and the pictures presented before the keyframe among it (lost).
        let (cutCount, lost) = countCut(from: index, before: cut)
        let lastOld = videoQueue.lastElement?.effectivePTS
        guard spliceVariantVideo(at: time, keyframe: keyframe) else { return false }
        let seconds = toSeconds(time, newBase)
        cutQueuedTail(videoIndex: index, audioPTS: audioCut, atSeconds: seconds)
        var how: String
        if index != nil {
            how = " (\(cutCount) old pictures cut, \(lost) of them presented before it)"
        } else if let lastOld, lastOld != Int64.min {
            // The old pictures end before the keyframe: what is between is a hole.
            let end = toSeconds(lastOld, timebase)
            how =
                " (nothing queued of it past that; the old pictures end at \(format(end)) s: a hole of "
                + "\(format(max(seconds - end, 0))) s)"
        } else {
            how = " (nothing of the old variant queued)"
        }
        if let expected = pending.abandoned?.cut {
            how += ", given up inside the segment, expected at \(format(expected)) s"
        }
        if let audioCut {
            how += "; its own sound cut at \(format(toSeconds(audioCut, audioTimebase))) s"
        }
        AppLog.info(
            .demuxer,
            "\(streamingName): the download of variant \(pending.abandoned?.from ?? -1) given up was cut at \(format(seconds)) s"
                + how)
        // The old variant's sound is read no more: the new one's takes over from the cut, from what is held of it now, or
        // at its first packet there read later (`admitDuringVariantSwitch`).
        if let newAudioCut, (pending.heldAudio.last?.pts ?? Int64.min) < newAudioCut {
            variantSwitch?.abandonedAudioCut = newAudioCut
        } else if variantSwitch != nil {
            spliceVariantAudio(releasingHeld: true, fromAudioPTS: newAudioCut)
        }
        return true
    }

    /// A keyframe of a switch that took a download over refused: said at most twice a second, for the measurement.
    private func logSpliceRefusal(_ text: String) {
        let now = adaptiveTime
        guard now - adaptiveBitrate.lastSpliceRefusal >= 0.5 else { return }
        adaptiveBitrate.lastSpliceRefusal = now
        AppLog.info(.demuxer, "\(streamingName): \(text)")
    }

    /// A download given up and read again (`restartAbandonedDownload`): what the old variant reads again of the segment is
    /// spliced into what it had queued of it as a chunk of another variant is (ExoPlayer splices a chunk reloaded after a
    /// cancel so: `HlsMediaChunk.shouldSpliceIn`), with no use of the timeline, whose start of a segment may be the media's
    /// less up to a second.
    struct RestartSplice: Sendable, Equatable {
        /// The old variant's picture, and the sound the demuxer plays (its own, read again with it, or a rendition read on).
        let video: Int
        let audio: Int?
        /// Where the pictures were cut (the first keyframe read again past what is handed out), and the sound.
        private(set) var videoCut: Int64?
        private(set) var audioCut: Int64?
        /// The sound has gone past its cut since: nothing more of it is read twice.
        private(set) var isAudioThrough = false

        init(video: Int, audio: Int?) {
            self.video = video
            self.audio = audio
        }

        /// What is done with a packet read again: the queue cut from `cut` (its time base) first, when one is given, and the
        /// packet handed on or dropped.
        struct Admission: Equatable {
            var cut: Int64?
            var passes: Bool

            static let pass = Admission(cut: nil, passes: true)
            static let drop = Admission(cut: nil, passes: false)
        }

        /// The splice is made for both: nothing more to look at.
        var isDone: Bool { videoCut != nil && (audio == nil || isAudioThrough) }

        /// A picture read again (`time` its presentation time; `handedOut` the latest picture handed out, if any). Dropped up
        /// to the first keyframe presented after it; the queue is cut there, from the first queued packet in decode order
        /// presented at or after it, and every picture after passes. The same variant is read again, so the keyframe is
        /// one the queue holds: what decodes after it and is presented before it (an open GOP's leading pictures) is after
        /// it in the queue too, cut with it and read again once, never twice.
        mutating func admitVideo(isKeyframe: Bool, time: Int64?, handedOut: Int64?) -> Admission {
            if videoCut != nil { return .pass }
            guard isKeyframe, let time else { return .drop }
            if let handedOut, handedOut >= time { return .drop }
            videoCut = time
            return Admission(cut: time, passes: true)
        }

        /// A packet of the sound (`handedOut` the last one handed out, if any). At the first, the queued sound is cut from its
        /// time, or just after what is handed out; what is read again before that is dropped, and the rest passes.
        mutating func admitAudio(time: Int64?, handedOut: Int64?) -> Admission {
            guard let time else { return .pass }
            var newCut: Int64?
            if audioCut == nil {
                newCut = max(time, handedOut.map { $0 + 1 } ?? time)
                audioCut = newCut
            }
            let passes = time >= (audioCut ?? time)
            if passes { isAudioThrough = true }
            return Admission(cut: newCut, passes: passes)
        }
    }

    /// Gives up a download given up for a switch that did not come (`beginRequestedVariantSwitch` could not make it, or the
    /// switch was given up before its splice): the old variant reads the segment again from its start, spliced in by
    /// `admitRestarted`, so the decoder does not get the same times twice.
    func restartAbandonedDownload(_ abandoned: PendingAbandon) {
        // Read again over the same link, it may be as slow: the check may give it up again.
        adaptiveBitrate.abandonmentLog.reopen(variant: abandoned.from, sequence: abandoned.sequence)
        let video = variantStreams[abandoned.from]?.video ?? videoStreamIndex
        adaptiveBitrate.restart = RestartSplice(video: video, audio: audioStreamIndex >= 0 ? audioStreamIndex : nil)
        input.restartDownload(ofVariant: abandoned.from, atSequence: abandoned.sequence)
    }

    /// Whether a packet read while a download given up is read again is handed on (`readPacket`), as `RestartSplice`
    /// decides, cutting the queues where it says. Behind `lock` and `queueLock`. The state ends once both are spliced, or
    /// at a seek, a switch begun or the end of the input.
    func admitRestarted(_ pkt: inout AVPacket) -> Bool {
        guard var restart = adaptiveBitrate.restart else { return true }
        defer { adaptiveBitrate.restart = restart.isDone ? nil : restart }
        let index = Int(pkt.stream_index)
        let raw = pkt.pts != Int64.min ? pkt.pts : pkt.dts
        let time = raw == Int64.min ? nil : raw
        let seconds = { (ticks: Int64, base: AVRational) in Double(ticks) * Double(base.num) / Double(max(base.den, 1))
        }
        if index == restart.video {
            let handedOut = videoQueue.largestHandedOutPTS
            let admission = restart.admitVideo(
                isKeyframe: pkt.flags & AV_PKT_FLAG_KEY != 0, time: time,
                handedOut: handedOut == Int64.min ? nil : handedOut)
            if let cut = admission.cut {
                let cutIndex = videoQueue.firstIndex(atOrAfterPTS: cut)
                let (count, lost) = countCut(from: cutIndex, before: cut)
                cutQueuedTail(videoIndex: cutIndex, audioPTS: nil, atSeconds: seconds(cut, timebase))
                AppLog.info(
                    .demuxer,
                    "\(streamingName): a download given up is read again from \(String(format: "%.3f", seconds(cut, timebase))) s "
                        + "(\(count) queued pictures cut, \(lost) of them presented before it)")
            }
            return admission.passes
        }
        guard let audio = restart.audio, index == audio else { return true }
        let handedOut = audioQueue.lastHandedOutPTS
        let admission = restart.admitAudio(time: time, handedOut: handedOut == Int64.min ? nil : handedOut)
        if let cut = admission.cut {
            cutQueuedTail(videoIndex: nil, audioPTS: cut, atSeconds: seconds(cut, audioTimebase))
        }
        return admission.passes
    }

    /// For the log: how many queued pictures a cut from `index` takes, and how many of them are presented before `time`.
    private func countCut(from index: Int?, before time: Int64) -> (count: Int, lost: Int) {
        guard var position = index else { return (0, 0) }
        var count = 0
        var lost = 0
        while let packet = videoQueue.peekAt(position) {
            count += 1
            if packet.effectivePTS < time { lost += 1 }
            position += 1
        }
        return (count, lost)
    }
}

extension MediaDemuxer {
    /// The times (seconds) of the latest video keyframes queued, apart from the packets, which a live read-ahead does not
    /// keep once handed out (`backBytes` 0): what a give-up with nothing of its segment queued places its cut by
    /// (`expectedHoleCut`). Started again at a seek; where the times go back, what is not before them goes.
    struct KeyframeTrail: Sendable, Equatable {
        /// As many as the spacing is taken from (`expectedHoleCut` looks at eight gaps).
        static let capacity = 9
        private(set) var times: [Double] = []

        mutating func note(_ time: Double) {
            if let last = times.last {
                if abs(time - last) < 0.001 { return }
                // Read again from further back (a download given up and read again, its tail cut) the later ones go; at a
                // break, whose times start over, all of them.
                if time < last { times.removeAll { $0 >= time - 0.001 } }
            }
            times.append(time)
            if times.count > Self.capacity { times.removeFirst(times.count - Self.capacity) }
        }
    }
}
