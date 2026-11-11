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

    /// Called on the read-ahead thread, inside the read (`queueLock` released): reads what is behind its own lock alone.
    func noteSegmentInFlight(_ segment: InFlightSegment) {
        guard variants.count > 1 else { return }
        let selection = variantSelection.withLock { $0 }
        guard selection.isAutomatic, selection.requested == nil, let variant = selection.selected,
            segment.variants.contains(variant)
        else { return }
        let rejected = selection.rejected
        let ladder = variants.filter { $0.isSwitchable && !rejected.contains($0.id) }.map {
            AdaptiveBitrateLogic.Variant(id: $0.id, bandwidth: $0.bandwidth, pixels: $0.width * $0.height)
        }
        let cursor = consumedSeconds
        let readPoint = readAheadState.withLock { $0 }
        guard cursor.isFinite, readPoint.isFinite else { return }
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
        guard
            let decision = adaptiveBitrate.logic.abandonment(
                of: download, among: ladder, buffer: buffer, roundTrip: roundTrip,
                playlistLoad: isLive ? roundTrip : 0)
        else { return }
        if let last = adaptiveBitrate.abandonmentLog.last, last == (variant, segment.sequence) { return }
        adaptiveBitrate.abandonmentLog.last = (variant, segment.sequence)
        let format = { (value: Double) in String(format: "%.2f", value) }
        let rate = decision.loadRate.map { "\(Int($0 / 1000)) kbit/s" } ?? "estimate"
        let queued = queuedPosition()
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
    /// yet, and the queued GOPs' average length. Takes `queueLock` (after `lock`, as the read thread does).
    private func queuedPosition() -> (audioCursor: Double?, nextKeyframe: Double?, gop: Double?) {
        readingDescription { demuxer in
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
    }
}

extension MediaDemuxer {
    /// A variant's bandwidth in kilobits a second, for the log.
    fileprivate func bandwidth(of id: Int) -> Int {
        (variants.first { $0.id == id }?.bandwidth ?? 0) / 1000
    }
}
