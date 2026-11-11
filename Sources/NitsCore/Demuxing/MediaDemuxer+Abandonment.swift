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
            "ABR abandon (not acted on): variant \(variant) (\(bandwidth(of: variant)) kbit/s) segment \(segment.sequence) "
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
