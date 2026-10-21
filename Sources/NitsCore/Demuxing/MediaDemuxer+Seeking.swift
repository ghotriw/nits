import CFFmpeg
import Foundation
import os

extension MediaDemuxer {
    /// - Parameter forward: Keyframe (non-exact) seeks only. When `true`, lands on the first keyframe at or
    ///   after `seconds` instead of the one before it. Required for sparse-GOP streams (e.g. AV1 with 10 s+
    ///   keyframe intervals) where a backward search would snap a +5 s step back to the same keyframe.
    /// - Parameter audioDelay: Seconds audio plays late against the picture. When positive, the audio heard with the
    ///   landed keyframe precedes it and is read too (see `readAudioAhead`).
    public func seek(to seconds: Double, exact: Bool = true, forward: Bool = false, audioDelay: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx else { return }
        audioQueue.removeAll()
        videoQueue.removeAll()
        lastAudioPts = -1
        isEOFInternal = false
        let previousReadAhead = readAheadState.withLock { $0 }
        subtitleTracker.beginSeek(previousReadAhead: previousReadAhead)
        // After the seek's own reads: a keyframe search that backs off, or reads to the end, would leave them ahead.
        defer {
            readAheadState.withLock { $0 = seconds }
            subtitleTracker.endSeek(at: seconds)
        }
        if audioTimebase.den > 0 && audioTimebase.num > 0 {
            self.targetAudioPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        } else {
            self.targetAudioPts = -1
        }
        guard timebase.num > 0 else { return }
        let target = Int64(seconds * Double(timebase.den) / Double(timebase.num))
        // If not exact (keyframe seek), don't set targetPts threshold so that the keyframe sample is displayed immediately
        self.targetPts = exact ? target : -1
        let streamIdx = videoStreamIndex >= 0 ? videoStreamIndex : audioStreamIndex
        let useForward = forward && !exact
        let rawTarget = target + Self.timelineOffset(timelineOrigin, in: timebase)
        var ret: Int32 = -1
        if useForward {
            ret = seekTimeline(ctx, to: rawTarget, flags: 0)
        }
        if ret < 0 {
            // Backward search (also the fallback when no keyframe exists after target, e.g. near EOF)
            ret = seekTimeline(ctx, to: rawTarget, flags: AVSEEK_FLAG_BACKWARD)
        }
        AppLog.debug(
            .demuxer,
            "av_seek_frame to targetPts: \(target) (exact: \(exact), forward: \(useForward)), targetAudioPts: \(self.targetAudioPts) (seconds: \(seconds)), stream: \(streamIdx), ret: \(ret)"
        )
        if ret >= 0, videoStreamIndex >= 0, Self.isUnindexedStream(ctx) {
            syncToVideoKeyframe(ctx, target: target, requireAtOrBeforeTarget: exact)
        } else if ret >= 0, audioDelay > 0, videoStreamIndex >= 0, audioStreamIndex >= 0 {
            readAudioAhead(ctx, audioStartSeconds: exact ? seconds - audioDelay : nil, audioDelay: audioDelay)
        }
    }

    /// Seeks to the keyframe at or before (`AVSEEK_FLAG_BACKWARD`) or after `rawTarget`, in the seek stream's time
    /// base with the timeline offset applied.
    ///
    /// The Matroska and MP4 seeks clamp a target to the first entry of the searched stream's index. A video cut
    /// between keyframes starts up to a GOP after its audio and subtitles, so a target before its first keyframe
    /// would land there and skip what plays before it. Such a target is searched in the audio stream instead:
    /// Matroska indexes every audio block it reads (the opening scan reads the start of the file), MP4 every sample,
    /// and the MP4 seek then moves the video to its first sample.
    @discardableResult
    func seekTimeline(_ ctx: UnsafeMutablePointer<AVFormatContext>, to rawTarget: Int64, flags: Int32) -> Int32 {
        let streamIdx = videoStreamIndex >= 0 ? videoStreamIndex : audioStreamIndex
        guard videoStreamIndex >= 0, audioStreamIndex >= 0, Self.describesStreams(ctx),
            let videoStream = ctx.pointee.streams[videoStreamIndex],
            let audioStream = ctx.pointee.streams[audioStreamIndex],
            let firstVideo = avformat_index_get_entry(videoStream, 0)?.pointee.timestamp,
            let firstAudio = avformat_index_get_entry(audioStream, 0)?.pointee.timestamp,
            rawTarget < firstVideo,
            av_rescale_q(firstAudio, audioStream.pointee.time_base, videoStream.pointee.time_base) < firstVideo
        else {
            return av_seek_frame(ctx, Int32(streamIdx), rawTarget, flags)
        }
        let audioTarget = av_rescale_q(rawTarget, videoStream.pointee.time_base, audioStream.pointee.time_base)
        return av_seek_frame(ctx, Int32(audioStreamIndex), audioTarget, flags)
    }

    /// Reads the audio that plays with the landed keyframe when audio is delayed against the picture.
    ///
    /// A seek lands on a keyframe and reads on from there, but the muxer stores audio next to video of the same
    /// time: the audio for `audioDelay` before the keyframe lies before it in the file and would be skipped, leaving
    /// that much silence after every keyframe seek. Once the keyframe is known, this seeks back to one at or before
    /// the audio start and reads up to the landed keyframe again, keeping the audio and dropping the video before it
    /// (nothing extra is decoded). Reading then continues after the keyframe as it would have.
    ///
    /// - Parameter audioStartSeconds: Where audio must start (exact seeks), or `nil` for the keyframe minus
    ///   `audioDelay` (keyframe seeks).
    func readAudioAhead(
        _ ctx: UnsafeMutablePointer<AVFormatContext>, audioStartSeconds: Double?, audioDelay: Double
    ) {
        // The landed keyframe, with the audio stored before it, as plain reading would queue them.
        var pkt = AVPacket()
        var keyframe: DemuxedVideoPacket?
        while keyframe == nil, readPacket(ctx, &pkt) >= 0 {
            defer { av_packet_unref(&pkt) }
            if pkt.stream_index == audioStreamIndex {
                audioQueue.append(DemuxedAudioPacket(pkt))
            } else if pkt.stream_index == videoStreamIndex {
                subtitleTracker.processVideoPacket(&pkt)
                keyframe = DemuxedVideoPacket(pkt)
            }
        }
        guard let keyframe else { return }
        videoQueue.append(keyframe)

        let keyTime = keyframe.pts != Int64.min ? keyframe.pts : keyframe.dts
        let keySeconds = Double(keyTime) * Double(timebase.num) / Double(timebase.den)
        let audioStart = max(audioStartSeconds ?? keySeconds - audioDelay, 0)
        guard audioStart < keySeconds else { return }

        let rawStart =
            Int64(audioStart * Double(timebase.den) / Double(timebase.num))
            + Self.timelineOffset(timelineOrigin, in: timebase)
        guard seekTimeline(ctx, to: rawStart, flags: AVSEEK_FLAG_BACKWARD) >= 0 else {
            restoreAfterAudioAhead(ctx, keyTime: keyTime)
            return
        }
        var audio: [DemuxedAudioPacket] = []
        var budget = 50_000
        while budget > 0, readPacket(ctx, &pkt) >= 0 {
            budget -= 1
            defer { av_packet_unref(&pkt) }
            if pkt.stream_index == audioStreamIndex {
                audio.append(DemuxedAudioPacket(pkt))
            } else if pkt.stream_index == videoStreamIndex, (pkt.pts != Int64.min ? pkt.pts : pkt.dts) == keyTime {
                // Back at the keyframe, already queued: the audio read on the way replaces the audio queued above.
                audioQueue.removeAll()
                for packet in audio {
                    audioQueue.append(packet)
                }
                return
            }
        }
        AppLog.warning(.demuxer, "Keyframe at \(keySeconds)s not reached again while reading audio ahead of it")
        restoreAfterAudioAhead(ctx, keyTime: keyTime)
    }

    /// Returns to just after the landed keyframe (already queued, with the audio stored before it) when reading audio
    /// ahead of it failed.
    func restoreAfterAudioAhead(_ ctx: UnsafeMutablePointer<AVFormatContext>, keyTime: Int64) {
        let rawKey = keyTime + Self.timelineOffset(timelineOrigin, in: timebase)
        guard av_seek_frame(ctx, Int32(videoStreamIndex), rawKey, AVSEEK_FLAG_BACKWARD) >= 0 else { return }
        var pkt = AVPacket()
        while readPacket(ctx, &pkt) >= 0 {
            defer { av_packet_unref(&pkt) }
            if pkt.stream_index == videoStreamIndex, (pkt.pts != Int64.min ? pkt.pts : pkt.dts) >= keyTime {
                return
            }
        }
    }

    /// MPEG-TS / MPEG-PS have no index: `av_seek_frame` bisects on timestamps and lands on whatever
    /// packet is nearest, usually mid-GOP, which the decoder can't start from. Skips ahead to the next
    /// video keyframe and queues it; for exact seeks, backs off further each time that keyframe is past
    /// the target.
    ///
    /// The muxer interleaves audio up to ~0.7 s away from the video of the same time, so audio read
    /// before the keyframe can still be needed: on the attempt that lands it is queued like any audio
    /// read ahead of video (`nextAudioPacket` drops what precedes `targetAudioPts`). Subtitle cues are
    /// kept on every attempt; re-reading them after a back-off is deduplicated.
    func syncToVideoKeyframe(
        _ ctx: UnsafeMutablePointer<AVFormatContext>, target: Int64, requireAtOrBeforeTarget: Bool
    ) {
        let oneSecond = Int64(Double(timebase.den) / Double(timebase.num))
        let maxAttempts = 5
        var seekTarget = target + Self.timelineOffset(timelineOrigin, in: timebase)
        for attempt in 0..<maxAttempts {
            var pkt = AVPacket()
            var landed = false
            var budget = 20_000
            var audioBeforeKeyframe: [DemuxedAudioPacket] = []
            while budget > 0, readPacket(ctx, &pkt) >= 0 {
                budget -= 1
                defer { av_packet_unref(&pkt) }
                if pkt.stream_index == audioStreamIndex {
                    audioBeforeKeyframe.append(DemuxedAudioPacket(pkt))
                    continue
                }
                guard pkt.stream_index == videoStreamIndex, (pkt.flags & AV_PKT_FLAG_KEY) != 0 else { continue }
                let keyPts = pkt.pts != Int64.min ? pkt.pts : pkt.dts
                let isLastChance = attempt == maxAttempts - 1
                if requireAtOrBeforeTarget && keyPts > target && !isLastChance {
                    break
                }
                subtitleTracker.processVideoPacket(&pkt)
                videoQueue.append(DemuxedVideoPacket(pkt))
                landed = true
                break
            }
            if landed {
                for packet in audioBeforeKeyframe {
                    audioQueue.append(packet)
                }
                return
            }
            seekTarget -= oneSecond << attempt
            // Before the first timestamp the bisection fails: restart from the first byte instead.
            if av_seek_frame(ctx, Int32(videoStreamIndex), seekTarget, AVSEEK_FLAG_BACKWARD) < 0 {
                _ = avformat_seek_file(ctx, -1, Int64.min, 0, 0, AVSEEK_FLAG_BYTE)
            }
        }
        AppLog.warning(.demuxer, "No video keyframe found while syncing seek to \(target)")
    }

    /// Adjusts the target audio presentation timestamp (e.g. to align with the actual decoded keyframe PTS).
    public func setTargetAudioPts(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        if audioTimebase.den > 0 && audioTimebase.num > 0 {
            self.targetAudioPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        } else {
            self.targetAudioPts = -1
        }
    }

    /// Discards any audio packets queued prior to the specified target time in seconds.
    /// This prevents stale audio packets accumulated during video preroll/seeking from corrupting the synchronizer.
    public func purgeAudio(beforeSeconds seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard audioTimebase.den > 0 && audioTimebase.num > 0 else {
            audioQueue.removeAll()
            return
        }
        let thresholdPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        audioQueue.removeAll { $0.pts < thresholdPts }
    }
}
