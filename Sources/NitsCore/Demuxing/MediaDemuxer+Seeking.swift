import CFFmpeg
import Foundation
import os

extension MediaDemuxer {
    /// - Parameter forward: Keyframe (non-exact) seeks only. When `true`, lands on the first keyframe at or
    ///   after `seconds` instead of the one before it. Required for sparse-GOP streams (e.g. AV1 with 10 s+
    ///   keyframe intervals) where a backward search would snap a +5 s step back to the same keyframe.
    /// - Parameter audioDelay: Seconds audio plays late against the picture. When positive, the audio heard with the
    ///   landed keyframe precedes it and is read too (see `readAudioAhead`).
    /// - Returns: Whether the seek is exact: asked to be, or a forward one with no keyframe after `seconds` (past the
    ///   last one). That one goes to `seconds` exactly, from the keyframe before, rather than back to that keyframe,
    ///   seconds before the target near the end.
    @discardableResult
    public func seek(
        to seconds: Double, exact: Bool = true, forward: Bool = false, audioDelay: Double = 0
    ) -> Bool {
        seekReportingCache(to: seconds, exact: exact, forward: forward, audioDelay: audioDelay).isExact
    }

    /// `seek`, also telling whether the packet cache served it (no input was read or moved).
    @discardableResult
    func seekReportingCache(
        to seconds: Double, exact: Bool = true, forward: Bool = false, audioDelay: Double = 0
    ) -> (isExact: Bool, fromCache: Bool) {
        if let isExact = serveSeekFromCache(to: seconds, exact: exact, forward: forward, audioDelay: audioDelay) {
            return (isExact, true)
        }
        return (performSlowSeek(to: seconds, exact: exact, forward: forward, audioDelay: audioDelay), false)
    }

    private func performSlowSeek(
        to seconds: Double, exact: Bool = true, forward: Bool = false, audioDelay: Double = 0
    ) -> Bool {
        lockIO(yielding: isLive)
        defer { lock.unlock() }
        queueLock.lock()
        defer { queueLock.unlock() }
        guard let ctx = formatCtx else { return exact }
        completeVariantSwitchBeforeSeek(in: ctx, at: seconds)
        // A track selected before the seek is read from its target (an audio track switch seeks for this).
        applyChangedStreamSelection(in: ctx)
        reenableEndedDASHStreams(in: ctx)
        // Splices read ahead past the target are gone: the variant read now plays from it.
        reportVariant(at: seconds)
        audioQueue.removeAll()
        videoQueue.removeAll()
        lastAudioPts = -1
        lastVideoReadTime = Int64.min
        inputEndedOnDemand = false
        // The read-ahead thread reads on from where this seek leaves the input; one started held for a start position
        // (`startReadAhead(held:)`) too, as a seek issued before it was positioned there takes its place.
        selectionOutdatesCache = false
        readAheadEnded = false
        reportsVideoSizeAtNextKeyframe = true
        readAheadHitEOF = false
        readAheadControl.withLock { $0.isHeld = false }
        consumedSeconds = seconds
        defer { readAheadWake.signal() }
        let previousReadAhead = readAheadState.withLock { $0 }
        subtitleTracker.beginSeek(previousReadAhead: previousReadAhead)
        secondarySubtitleTracker.beginSeek(previousReadAhead: previousReadAhead)
        // After the seek's own reads: a keyframe search that backs off, or reads to the end, would leave them ahead.
        defer {
            readAheadState.withLock { $0 = seconds }
            subtitleTracker.endSeek(at: seconds)
            secondarySubtitleTracker.endSeek(at: seconds)
        }
        if audioTimebase.den > 0 && audioTimebase.num > 0 {
            self.targetAudioPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        } else {
            self.targetAudioPts = -1
        }
        guard timebase.num > 0 else { return exact }
        // Nothing selected to position: no picture, and the audio heard comes from another input. Seeking stream -1
        // would take the target in `AV_TIME_BASE`, not this time base.
        guard videoStreamIndex >= 0 || audioStreamIndex >= 0 else { return exact }
        let target = Int64(seconds * Double(timebase.den) / Double(timebase.num))
        // If not exact (keyframe seek), don't set targetPts threshold so that the keyframe sample is displayed immediately
        self.targetPts = exact ? target : -1
        var isExact = exact
        // No keyframe after the target: the samples before it, from the keyframe the search falls back to, are only
        // decoded, as for an exact seek.
        let goExactly = {
            isExact = true
            self.targetPts = target
        }
        let streamIdx = videoStreamIndex >= 0 ? videoStreamIndex : audioStreamIndex
        let useForward = forward && !exact
        let rawTarget = target + Self.timelineOffset(timelineOrigin, in: timebase)
        let streams = (video: videoStreamIndex, audio: audioStreamIndex)
        var ret: Int32 = -1
        if useForward {
            ret = withoutQueueLock { seekTimeline(ctx, to: rawTarget, flags: 0, streams: streams) }
            if ret < 0 { goExactly() }
        }
        if ret < 0 {
            // Backward search (also the fallback when no keyframe exists after target, e.g. near EOF)
            ret = withoutQueueLock { seekTimeline(ctx, to: rawTarget, flags: AVSEEK_FLAG_BACKWARD, streams: streams) }
        }
        if ret >= 0, videoStreamIndex >= 0, Self.isUnindexedStream(ctx) {
            // The bisection lands near the target, its keyframe search reads on from there: backing off means it found
            // none to the end.
            let backedOff = !syncToVideoKeyframe(ctx, target: target, requireAtOrBeforeTarget: isExact)
            if useForward && backedOff && !isExact { goExactly() }
        } else if ret >= 0, audioDelay > 0, videoStreamIndex >= 0, audioStreamIndex >= 0 {
            readAudioAhead(ctx, audioStartSeconds: isExact ? seconds - audioDelay : nil, audioDelay: audioDelay)
        }
        AppLog.debug(
            .demuxer,
            "av_seek_frame to targetPts: \(target) (exact: \(isExact), forward: \(useForward)), targetAudioPts: \(self.targetAudioPts) (seconds: \(seconds)), stream: \(streamIdx), ret: \(ret)"
        )
        return isExact
    }

    /// Attempts an instant in-cache seek using packets currently held in RAM without network I/O.
    ///
    /// Acquires `queueLock` internally. Must not be called while holding `queueLock`. Returns `true`
    /// if the target was satisfied from cache; returns `false` on cache miss, live stream, track change, etc.,
    /// leaving the demuxer state intact so that `seek(to:)` can be called as fallback.
    @discardableResult
    func seekWithinCache(
        to seconds: Double, exact: Bool = true, forward: Bool = false, audioDelay: Double = 0
    ) -> Bool {
        serveSeekFromCache(to: seconds, exact: exact, forward: forward, audioDelay: audioDelay) != nil
    }

    /// `seekWithinCache`, telling whether the seek it served lands on its target exactly (see `seek`).
    func serveSeekFromCache(
        to seconds: Double, exact: Bool = true, forward: Bool = false, audioDelay: Double = 0
    ) -> Bool? {
        queueLock.lock()
        defer { queueLock.unlock() }

        // 1. Check prerequisites
        guard readsAhead, !isLive, !selectionOutdatesCache else {
            return nil
        }
        // A ladder with a variant chosen by hand: the choice is the picture's from the seek on (the engine re-reads at
        // the position), so the packets must be of the variant read now. Not while it is asked for (`requested`) or
        // being switched to (`variantSwitch`: the read-ahead takes `requested` as soon as it reads, long before the
        // splice), and not from one it left.
        let isLadder = variants.count > 1
        var needsCurrentVariant = false
        if isLadder {
            let selection = variantSelection.withLock { $0 }
            if !selection.isAutomatic {
                guard selection.requested == nil, variantSwitch == nil else { return nil }
                needsCurrentVariant = true
            }
        }
        // A break in the timestamps (a discontinuity): the cursor on the older timeline, or a stream that has reached
        // it before the other, compares a position and a target of different timelines. Both clear with a slow seek.
        guard !videoQueue.isBeforeBreak, !audioQueue.isBeforeBreak else { return nil }
        if hasVideo, videoStreamIndex >= 0, audioStreamIndex >= 0, videoQueue.breakCount != audioQueue.breakCount {
            return nil
        }
        guard formatCtx != nil else { return nil }
        guard timebase.num > 0, timebase.den > 0 else { return nil }
        guard videoStreamIndex >= 0 || audioStreamIndex >= 0 else { return nil }

        // An ended read-ahead keeps its end through the seek, so it must be the media's: a dropped connection also
        // reads as EOF, and the playback would end where it dropped. Trusted only when the cache reaches the end of a
        // duration the container told.
        if readAheadEnded {
            guard readAheadHitEOF, durationSeconds > 0, cachedFrontierSeconds >= durationSeconds - 1.0 else {
                return nil
            }
        }

        // Decoders of these keep state across packets (a seek back would show what they remember of the wrong place).
        let hasStatefulSubtitleSelected = [selectedSubtitleTrackId, selectedSecondarySubtitleTrackId].contains { id in
            guard let id, let track = subtitleTracks.first(where: { $0.id == id }) else { return false }
            return track.format == .bitmap || track.closedCaptionField != nil
        }
        if hasStatefulSubtitleSelected {
            return nil
        }

        // 2. Video keyframe search
        let targetVideoPTS = Int64(seconds * Double(timebase.den) / Double(timebase.num))
        // Whether the seek lands on its target: asked to, or a forward one past the last keyframe (below).
        var landsExactly = exact
        var videoTargetIndex: Int? = nil
        var landedVideoSeconds: Double? = nil
        if hasVideo && videoStreamIndex >= 0 {
            let startTolerance = Int64(0.25 * Double(timebase.den) / Double(timebase.num))
            var keyframe = videoQueue.findKeyframeIndex(
                targetPTS: targetVideoPTS, forward: forward && !exact, startTolerancePTS: startTolerance)
            if keyframe == nil, forward, !exact, readAheadEnded {
                // Past the last keyframe of an input read to its end (the prerequisites above hold the end to be the
                // media's): as the slow seek does, to the target exactly from the keyframe before it.
                keyframe = videoQueue.findKeyframeIndex(
                    targetPTS: targetVideoPTS, forward: false, startTolerancePTS: startTolerance)
                landsExactly = true
            }
            guard let kfIndex = keyframe else {
                return nil
            }
            // A ladder: the picture lands in the variant it is at now (the one the engine shows); a splice between the
            // two is a slow seek's.
            if isLadder, !videoQueue.keyframesShare(from: kfIndex, withCursorBy: { $0.format.variantGeneration }) {
                return nil
            }
            if needsCurrentVariant, videoQueue.peekAt(kfIndex)?.format.variantGeneration != variantGeneration {
                return nil
            }
            videoTargetIndex = kfIndex
            if let kfPkt = videoQueue.peekAt(kfIndex), timebase.den > 0 {
                landedVideoSeconds = Double(kfPkt.effectivePTS) * Double(timebase.num) / Double(timebase.den)
            }
        }

        // 3. Audio coverage check
        var audioTargetIndex: Int? = nil
        if audioStreamIndex >= 0, audioTimebase.den > 0, audioTimebase.num > 0 {
            let baseSeconds = (!landsExactly && landedVideoSeconds != nil) ? landedVideoSeconds! : seconds
            let targetAudioSec = max(0, baseSeconds - audioDelay)
            let targetAudioPTS = Int64(targetAudioSec * Double(audioTimebase.den) / Double(audioTimebase.num))
            let primingTolerance = Int64(Double(audioTimebase.den) / 10.0)
            guard
                let aIndex = audioQueue.findAudioPacketIndex(
                    targetPTS: targetAudioPTS, primingTolerancePTS: primingTolerance)
            else {
                return nil
            }
            audioTargetIndex = aIndex
            self.targetAudioPts = targetAudioPTS
        } else {
            self.targetAudioPts = -1
        }

        // 4. Reposition cursors
        if let videoTargetIndex {
            videoQueue.seekTo(elementIndex: videoTargetIndex)
        }
        if let audioTargetIndex {
            audioQueue.seekTo(elementIndex: audioTargetIndex)
        }

        self.targetPts = (hasVideo && videoStreamIndex >= 0 && landsExactly) ? targetVideoPTS : -1

        // 5. Reset consumer state (matching demuxer.seek(to:))
        lastAudioPts = -1
        inputEndedOnDemand = false
        readAheadControl.withLock { $0.isHeld = false }
        consumedSeconds = landedVideoSeconds ?? seconds

        // 6. Prune history and wake waiters/read-ahead if forward space opened
        videoQueue.pruneGOPs()
        pruneAudioQueueIfNeeded()
        wakePacketWaiters()
        readAheadWake.signal()

        AppLog.info(
            .demuxer,
            "In-cache seek succeeded to seconds: \(seconds) (exact: \(exact), forward: \(forward))"
        )
        return landsExactly
    }

    /// Before the first seek of a load, to its start position: the representations of a ladder that are not played are
    /// closed first, so that the seek does not move them (`closeUnusedDASHRepresentations`).
    public func prepareFirstSeek() {
        lockIO()
        defer { lock.unlock() }
        queueLock.lock()
        defer { queueLock.unlock() }
        guard let ctx = formatCtx else { return }
        closeUnusedDASHRepresentations(in: ctx)
    }

    /// FFmpeg's DASH demuxer opens every representation of a ladder, and closes those discarded only when it reads a
    /// packet (`recheck_discard_flags`): a seek before the first read goes through all of them, each one reading its
    /// file up to the target when it has no index it can use (a single file: 19 s for a ladder of 7, 7 s once the
    /// others are closed). One packet read first, dropped by the seek, closes them. Behind `lock` and `queueLock`.
    ///
    /// For the seek to a start position a load makes (`prepareFirstSeek`) only: once playback has read, they are closed,
    /// and a packet read before a seek in the middle of it would be a request for nothing.
    func closeUnusedDASHRepresentations(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard !dashDiscardsApplied, variants.count > 1, streamingName == "DASH" else { return }
        dashDiscardsApplied = true
        var pkt = AVPacket()
        // A packet the probing of the streams left is handed out first, with no word to the DASH demuxer: dropped,
        // as the seek does.
        avformat_flush(ctx)
        if withoutQueueLock({ av_read_frame(ctx, &pkt) }) >= 0 { av_packet_unref(&pkt) }
    }

    /// FFmpeg's DASH demuxer, once a stream was read to its end, closes its input and sets the stream to
    /// `AVDISCARD_ALL`, so that it stays closed: a seek back moves its segment number, but nothing opens the input
    /// again, and the stream reads nothing. The streams playing are enabled again before the seek. Behind `lock` and
    /// `queueLock`.
    func reenableEndedDASHStreams(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard let format = ctx.pointee.iformat, String(cString: format.pointee.name) == "dash" else { return }
        for index in [videoStreamIndex, audioStreamIndex] + selectedSubtitleStreamIndices where index >= 0 {
            ctx.pointee.streams[index]?.pointee.discard = AVDISCARD_DEFAULT
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
    /// `streams` are the video and audio streams read: a seek takes them before it releases `queueLock` for this,
    /// as an audio track switch changes them behind it.
    @discardableResult
    func seekTimeline(
        _ ctx: UnsafeMutablePointer<AVFormatContext>, to rawTarget: Int64, flags: Int32,
        streams: (video: Int, audio: Int)
    ) -> Int32 {
        let streamIdx = streams.video >= 0 ? streams.video : streams.audio
        guard streams.video >= 0, streams.audio >= 0, Self.describesStreams(ctx),
            let videoStream = ctx.pointee.streams[streams.video],
            let audioStream = ctx.pointee.streams[streams.audio],
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
        while keyframe == nil, readPacket(ctx, &pkt, releasingQueueLock: true) >= 0 {
            defer { av_packet_unref(&pkt) }
            if pkt.stream_index == audioStreamIndex {
                audioQueue.append(DemuxedAudioPacket(pkt))
            } else if pkt.stream_index == videoStreamIndex {
                subtitleTracker.processVideoPacket(&pkt)
                keyframe = videoPacket(from: pkt)
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
        let streams = (video: videoStreamIndex, audio: audioStreamIndex)
        guard withoutQueueLock({ seekTimeline(ctx, to: rawStart, flags: AVSEEK_FLAG_BACKWARD, streams: streams) }) >= 0
        else {
            restoreAfterAudioAhead(ctx, keyTime: keyTime)
            return
        }
        var audio: [DemuxedAudioPacket] = []
        var budget = 50_000
        while budget > 0, readPacket(ctx, &pkt, releasingQueueLock: true) >= 0 {
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
        let video = Int32(videoStreamIndex)
        guard withoutQueueLock({ av_seek_frame(ctx, video, rawKey, AVSEEK_FLAG_BACKWARD) }) >= 0 else {
            return
        }
        var pkt = AVPacket()
        while readPacket(ctx, &pkt, releasingQueueLock: true) >= 0 {
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
    ///
    /// - Returns: Whether it found the keyframe without backing off. A search that backs off found none from where the
    ///   bisection landed to the end (or, with `requireAtOrBeforeTarget`, only ones past the target).
    @discardableResult
    func syncToVideoKeyframe(
        _ ctx: UnsafeMutablePointer<AVFormatContext>, target: Int64, requireAtOrBeforeTarget: Bool
    ) -> Bool {
        let oneSecond = Int64(Double(timebase.den) / Double(timebase.num))
        let maxAttempts = 5
        var seekTarget = target + Self.timelineOffset(timelineOrigin, in: timebase)
        for attempt in 0..<maxAttempts {
            var pkt = AVPacket()
            var landed = false
            var budget = 20_000
            var audioBeforeKeyframe: [DemuxedAudioPacket] = []
            while budget > 0, readPacket(ctx, &pkt, releasingQueueLock: true) >= 0 {
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
                videoQueue.append(videoPacket(from: pkt))
                landed = true
                break
            }
            if landed {
                for packet in audioBeforeKeyframe {
                    audioQueue.append(packet)
                }
                return attempt == 0
            }
            seekTarget -= oneSecond << attempt
            // Before the first timestamp the bisection fails: restart from the beginning instead.
            let video = Int32(videoStreamIndex)
            if withoutQueueLock({ av_seek_frame(ctx, video, seekTarget, AVSEEK_FLAG_BACKWARD) }) < 0 {
                withoutQueueLock { rewindUnindexedStream(ctx) }
            }
        }
        AppLog.warning(.demuxer, "No video keyframe found while syncing seek to \(target)")
        return false
    }

    /// Rewinds MPEG-TS / MPEG-PS to their first packet. A timestamp seek bisects and can land past it, dropping the
    /// keyframe that starts the file, so they rewind to their first byte. HLS can't seek by byte
    /// (`AVFMT_NO_BYTE_SEEK`, the rewind would do nothing); a target before its first segment starts from that
    /// segment's first keyframe.
    func rewindUnindexedStream(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        if let iformat = ctx.pointee.iformat, (iformat.pointee.flags & AVFMT_NO_BYTE_SEEK) != 0 {
            _ = av_seek_frame(ctx, -1, timelineOrigin - Int64(AV_TIME_BASE), AVSEEK_FLAG_BACKWARD)
        } else {
            _ = avformat_seek_file(ctx, -1, Int64.min, 0, 0, AVSEEK_FLAG_BYTE)
        }
    }

    /// Adjusts the target audio presentation timestamp (e.g. to align with the actual decoded keyframe PTS).
    public func setTargetAudioPts(seconds: Double) {
        queueLock.lock()
        defer { queueLock.unlock() }
        if audioTimebase.den > 0 && audioTimebase.num > 0 {
            self.targetAudioPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        } else {
            self.targetAudioPts = -1
        }
    }

    /// Discards any audio packets queued prior to the specified target time in seconds.
    /// This prevents stale audio packets accumulated during video preroll/seeking from corrupting the synchronizer.
    public func purgeAudio(beforeSeconds seconds: Double) {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard audioTimebase.den > 0 && audioTimebase.num > 0 else {
            audioQueue.removeAll()
            return
        }
        let thresholdPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        if readsAhead {
            while let pkt = audioQueue.peek(), pkt.effectivePTS < thresholdPts {
                _ = audioQueue.popFirst()
            }
        } else {
            audioQueue.removeAll { $0.pts < thresholdPts }
        }
    }
}
