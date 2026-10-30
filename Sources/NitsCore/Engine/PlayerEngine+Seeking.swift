@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import os

extension PlayerEngine {
    public func seek(to seconds: Double) {
        seek(to: seconds, exact: true)
    }

    public func seek(to seconds: Double, exact: Bool) {
        resetRelativeSeekBurst()
        seek(to: seconds, exact: exact, forward: false)
    }

    func resetRelativeSeekBurst() {
        relativeSeekBurstResetTask?.cancel()
        relativeSeekBurstResetTask = nil
        relativeSeekBurst = RelativeSeekBurst()
    }

    func armRelativeSeekBurstTimer() {
        relativeSeekBurstResetTask?.cancel()
        relativeSeekBurstResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.relativeSeekBurstTimeout)
            guard !Task.isCancelled, let self else { return }
            if (!self.isSeeking && self.chase == nil) || !self.relativeSeekBurst.isInFlight {
                self.resetRelativeSeekBurst()
            } else {
                // Safety watchdog: if in-flight seek hangs or takes unusually long, reset unconditionally
                try? await Task.sleep(for: Self.relativeSeekBurstWatchdogTimeout)
                guard !Task.isCancelled else { return }
                self.resetRelativeSeekBurst()
            }
        }
    }

    /// - Parameter minFramePTS: For a forward frame step, the earliest frame it may land on (see `ChaseTarget`).
    func seek(to seconds: Double, exact: Bool, forward: Bool, minFramePTS: Double? = nil) {
        let target = clampedSeekTarget(seconds)
        AppLog.info(.engine, "Seek requested to seconds: \(target), exact: \(exact), forward: \(forward)")
        guard demuxer != nil else { return }

        // Cancel any pending settle debounce from an earlier seek in the burst
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        cancelPreroll()
        clockSettlingGuardLock.withLock { $0 = nil }

        // 1. Maintain play intent across seek bursts (Apple QA1820 / mpv)
        if !isSeeking && chase == nil {
            resumePlaybackAfterChase = isPlaying
            if isPlaying {
                // Instantly pause playback clock and CADisplayLink during seek burst to prevent clock jitter / drift
                synchronizer.setRate(0.0, time: synchronizer.currentTime())
                displayLink?.isPaused = true
            }
        }

        // 2. Immediate responsive UI update (0ms latency for exact seek)
        chase = ChaseTarget(seconds: target, exact: exact, forward: forward, minFramePTS: minFramePTS)
        if exact {
            currentTime = target
            subtitles.timeDidChange(to: target, .tick)
        }

        // 3. Supersede the seek in flight, if any
        seekGeneration.advance()

        // 4. If a seek is already in flight on seekQueue, let it complete its current work;
        // it will check the generation and latest chase target upon finishing.
        if isSeeking { return }

        executeDemuxerSeek()
    }

    /// Where an exact seek to `targetSeconds` restricts displayable frames from, like mpv's hr-seek. Half a frame of
    /// tolerance keeps the frame whose display interval contains the target.
    func exactSeekDisplayFloor(at targetSeconds: Double) -> CMTime {
        let halfFrame = nominalFrameDurationLock.withLock { $0 } * 0.5
        return CMTime(seconds: targetSeconds - halfFrame, preferredTimescale: 90000)
    }

    /// Restricts displayable frames to those at/after an exact-seek target (`exactSeekDisplayFloor`). `nil` (keyframe
    /// seeks, start at 0) lifts the restriction.
    func setExactSeekDisplayFloor(_ targetSeconds: Double?) {
        frameQueue.setDisplayFloor(targetSeconds.map(exactSeekDisplayFloor(at:)) ?? .invalid)
    }

    func executeDemuxerSeek() {
        guard let target = chase else { return }
        guard let demuxer = self.demuxer else { return }

        isSeeking = true
        let targetSeconds = target.seconds
        let seekId = seekGeneration.current
        let loadID = currentLoadID

        let shouldResume = self.resumePlaybackAfterChase

        // Stop feeding packets from the old position.
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        frameQueue.clear(resetDroppedFrames: true)
        let exactFloor = exactSeekDisplayFloor(at: targetSeconds)
        frameQueue.setDisplayFloor(target.exact ? exactFloor : .invalid)
        // The pipeline is about to be flushed and repositioned; incremental forward stepping is invalid
        // until this seek settles and re-establishes contiguity. Release the old step window; it is
        // repopulated below for paused exact seeks (the frame-stepping scenario).
        frameStep.releaseWindow()

        let decoder = stallGuardedDecoder(for: "the seek queue")
        let audioDecoder = self.audioDecoder
        let audioSink = self.audioSink
        let audioDelay = self.audioDelay
        let hasVideo = self.media.hasVideo
        // The audio file played, when the track is one: it is positioned on its own input.
        let externalAudio = inputs?.selectedExternal
        let seekGeneration = self.seekGeneration
        let frameQueue = self.frameQueue
        // Seed the step window only for paused exact seeks — when the user is scrubbing/stepping, not
        // during seeks that will resume playback.
        let pausedStepCache: StepFrameCache? = shouldResume ? nil : self.frameStep.cache

        seekQueue.async { [weak self, demuxer, externalAudio, decoder, frameQueue, pausedStepCache] in
            guard let self else { return }

            let isSuperseded: @Sendable () -> Bool = { !seekGeneration.isCurrent(seekId) }
            // The seek as it lands: past the last keyframe, a forward keyframe seek goes to its target exactly
            // instead of back to that keyframe (see `MediaDemuxer.seek`), to the last frame for a target at the end.
            var landed = target

            if !isSuperseded() {
                if hasVideo {
                    decoder.flush()
                }
                let isExact = demuxer.seek(
                    to: targetSeconds, exact: target.exact, forward: target.forward, audioDelay: audioDelay)
                if isExact && !target.exact {
                    landed.exact = true
                    landed.forward = false
                    frameQueue.setDisplayFloor(exactFloor)
                }
            }

            var previewFrame: SeekPreview.Result? = nil
            if hasVideo {
                previewFrame = SeekPreview.decode(
                    demuxer: demuxer,
                    decoder: decoder,
                    frameQueue: frameQueue,
                    seconds: targetSeconds,
                    exact: landed.exact,
                    minPts: target.minFramePTS,
                    stepCache: landed.exact ? pausedStepCache : nil,
                    isCurrent: { !isSuperseded() }
                )
                let resolvedSeconds = previewFrame?.pts ?? targetSeconds
                // Playback reads on from where the seek landed, past the target after a forward keyframe seek: what it
                // jumped over wasn't read, even if a newer seek supersedes this one before it completes.
                if let preview = previewFrame { demuxer.noteSubtitleReadsStart(at: preview.pts) }
                // Audio heard with the picture at `t` is the media's audio at `t - audioDelay`.
                if let externalAudio {
                    // Its own input goes straight there, now the picture's landing is known: a keyframe seek lands
                    // seconds off the target, before which this input would have nothing left to read, or past it.
                    if !isSuperseded() {
                        let start = (landed.exact ? targetSeconds : resolvedSeconds) - audioDelay
                        externalAudio.seek(to: max(0, start))
                    }
                } else {
                    if !landed.exact, let preview = previewFrame {
                        demuxer.setTargetAudioPts(seconds: preview.pts - audioDelay)
                    } else if audioDelay != 0 {
                        demuxer.setTargetAudioPts(seconds: targetSeconds - audioDelay)
                    }
                    if !shouldResume {
                        demuxer.purgeAudio(beforeSeconds: resolvedSeconds - audioDelay)
                    }
                }
                // Render the freshly previewed frame directly (avoiding queue miss & stale fallback)
                if !isSuperseded(), let preview = previewFrame {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.seekGeneration.isCurrent(seekId) else { return }
                        self.renderDirect(
                            pixelBuffer: preview.pixelBuffer, pts: preview.pts, hdrMetadata: preview.hdrMetadata,
                            restartsSmoothing: true)
                    }
                }
            } else if let externalAudio, !isSuperseded() {
                externalAudio.seek(to: max(0, targetSeconds - audioDelay))
            }

            // Expensive audio reset only for the seek that is still current (final chase target).
            if !isSuperseded() {
                audioDecoder?.flush()
                audioSink.flush()
            }

            let settled = landed
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentLoadID == loadID else { return }
                let resolvedSeconds = previewFrame?.pts ?? targetSeconds
                self.completeChaseSeek(
                    target: settled,
                    completedSeconds: resolvedSeconds,
                    seekId: seekId,
                    didRenderPreview: previewFrame != nil
                )
            }
        }
    }

    /// A seek or frame-step pump superseded by a newer one finished on `seekQueue`: goes on to the latest target, if
    /// there still is one. Not for one a load superseded (its callbacks check `currentLoadID` first): the load ended it,
    /// and the seek or pump in flight now is the new media's. A stop keeps `currentLoadID`: one it superseded comes here,
    /// and with no chase left only clears `isSeeking`.
    private func continueChase() {
        if chase != nil {
            executeDemuxerSeek()
        } else {
            isSeeking = false
            relativeSeekBurst.seekLanded()
        }
    }

    func completeChaseSeek(
        target: ChaseTarget,
        completedSeconds: Double,
        seekId: Int,
        didRenderPreview: Bool
    ) {
        guard seekGeneration.isCurrent(seekId) else {
            continueChase()
            return
        }

        // Settled decoding for this position. Mark seek background work as done.
        isSeeking = false
        let targetTime = CMTime(seconds: completedSeconds, preferredTimescale: 1000)

        // If a preview frame was already rendered directly via renderDirect, do NOT overwrite it
        // by popping from frameQueue.getLatestFrame (which may drop preroll frames tagged doNotDisplay).
        if media.hasVideo && !didRenderPreview {
            renderCurrentFrame(at: targetTime)
        }

        // Immediately apply actual completed PTS so timer and subtitles match the displayed keyframe
        self.currentTime = completedSeconds
        subtitles.timeDidChange(to: completedSeconds, .seekLanded)
        onTimeUpdate?(completedSeconds, media.duration)

        if relativeSeekBurst.seekLanded() {
            armRelativeSeekBurstTimer()
        }

        if let offset = relativeSeekBurst.offset(landingAt: completedSeconds) {
            onRelativeSeekResolved?(offset, completedSeconds)
        }

        let shouldResume = resumePlaybackAfterChase
        if !shouldResume {
            // Paused mode: settle immediately
            chase = nil
            clockSettlingGuardLock.withLock { $0 = nil }
            synchronizer.setRate(0.0, time: targetTime)
            isPlaying = false
            // Media played to its end stays ended when a seek only lands at the end again.
            if !(playbackState == .completed && isAtEndOfMedia(completedSeconds)) {
                playbackState = .paused
            }
            performanceMonitor.handlePlaybackStateChange(isPlaying: false)
            // Exact seeks leave the decoder warm and positioned just past the displayed frame (preview
            // over-reads a few frames into the queue). This enables incremental forward frame-stepping.
            frameStep.isContiguous = media.hasVideo && target.exact
            AppLog.debug(.engine, "Chase seek settled at \(completedSeconds)s (paused)")
            return
        }

        chase = target.landed(at: completedSeconds)
        scheduleChaseSettle(seekId: seekId, at: completedSeconds)
    }

    /// Resumes playback at `completedSeconds`, where seek `seekId` landed, or ends the media there, unless a newer seek
    /// comes first. Playing mode: debounce resumption slightly (300ms) so that sustained key-hold repeat
    /// events (which fire every 40-70ms) don't repeatedly unpause and roll the clock forward.
    private func scheduleChaseSettle(seekId: Int, at completedSeconds: Double) {
        let targetTime = CMTime(seconds: completedSeconds, preferredTimescale: 1000)
        chaseSettleTask?.cancel()
        chaseSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.chaseSettleDebounceDuration)
            guard !Task.isCancelled, let self, self.seekGeneration.isCurrent(seekId) else { return }

            self.chase = nil
            // Landed at the end, the media ends, as playing on to it would (within the same margin): resuming there
            // would start the clock with nothing left to read. After the debounce, so key repeats still held land
            // here, not on the next item a completion loads.
            if self.isAtEndOfMedia(completedSeconds) {
                self.resumePlaybackAfterChase = false
                AppLog.debug(.engine, "Chase seek settled at the end (\(completedSeconds)s) while playing")
                self.handleEndOfMedia()
                return
            }
            self.startFeeding()
            self.startSynchronizerClockAfterPreroll(at: targetTime)
            self.displayLink?.isPaused = !self.media.hasVideo
            self.isPlaying = true
            self.playbackState = .playing
            self.performanceMonitor.handlePlaybackStateChange(isPlaying: true)
            AppLog.debug(.engine, "Chase seek settled and resumed at \(completedSeconds)s")
        }
    }

    @discardableResult
    public func seekRelative(by seconds: Double) -> Double {
        guard isLoaded, demuxer != nil else { return 0.0 }
        // Before the presses at the end below: held there, the burst (and the offset it reports) goes on.
        armRelativeSeekBurstTimer()

        // At the end already, a step forward would only land there again: an exact seek decoding the last GOP once more
        // (and on HLS reading it again) for each key repeat. Playing, the pending settle (which ends the media) waits
        // for the presses to stop, as their seeks would have it; paused or ended on the last frame, nothing is left.
        if seconds > 0, !isSeeking {
            if let settled = chase, chaseSettleTask != nil, isAtEndOfMedia(settled.seconds) {
                scheduleChaseSettle(seekId: seekGeneration.current, at: settled.seconds)
                return relativeSeekBurst.offset(landingAt: settled.seconds) ?? 0
            }
            if chase == nil, !isPlaying, isOnLastFrame {
                return relativeSeekBurst.offset(landingAt: currentTime) ?? 0
            }
        }

        // While a seek is in flight, baseTime steps from the pending target (mpv queue_seek model).
        // On slow frame-threaded streams (e.g. software AV1), rapid keypresses advance the goal,
        // while the demuxer chases the latest target to prevent stale frame freezes.
        let baseTime = chase?.seconds ?? currentTime
        let isFirstInBurst = relativeSeekBurst.press(at: baseTime)

        let isExact = !media.hasVideo || (exactSeekOnSinglePress && isFirstInBurst)
        let isForward = seconds > 0 && !isExact

        let target = ChaseTarget(seconds: clampedSeekTarget(baseTime + seconds), exact: isExact, forward: isForward)
        if isSeekInFlight(toPressed: target) {
            return relativeSeekBurst.offset(landingAt: target.seconds) ?? 0
        }

        // In burst mode (keyframe seek), always step from the latest targeted or settled frame
        // so every press advances past the current GOP to the next/prev keyframe without freezing.
        seek(to: baseTime + seconds, exact: isExact, forward: isForward)

        return relativeSeekBurst.offset(landingAt: chase?.seconds ?? currentTime) ?? 0
    }

    /// Where a seek to `seconds` goes: within the media.
    func clampedSeekTarget(_ seconds: Double) -> Double {
        max(0, media.duration > 0 ? min(seconds, media.duration) : seconds)
    }

    /// The picture shows the media's last frame, where a seek to the end lands: within a frame and a half of the end
    /// (`duration` is where the last frame's display ends). Not just within the margin of `isAtEndOfMedia`, from which
    /// frame steps and seeks still reach the frames after.
    private var isOnLastFrame: Bool {
        media.hasVideo && media.duration > 0 && currentFramePTS >= media.duration - nominalFrameDuration * 1.5
    }

    public func seekRelative(by seconds: Double, exact: Bool) {
        resetRelativeSeekBurst()
        let baseTime = chase?.seconds ?? currentTime
        // Forward keyframe steps must land on the next keyframe; a backward search on sparse-GOP
        // streams (AV1) would snap back to the current keyframe and the position would never advance.
        let forward = seconds > 0 && !exact
        let target = ChaseTarget(seconds: clampedSeekTarget(baseTime + seconds), exact: exact, forward: forward)
        if isSeekInFlight(toPressed: target) { return }
        seek(to: baseTime + seconds, exact: exact, forward: forward)
    }

    /// Whether a press (an arrow key's, a skip button's) seeking to `target` would go where the seek in flight goes
    /// already: repeats clamped to the end or the start. Superseding it would only start it over, its exact seek
    /// decoding the last GOP from its keyframe again before it ever lands. Only presses: other seeks to the same target
    /// (a track switch's re-read) must supersede it, to read the media again.
    private func isSeekInFlight(toPressed target: ChaseTarget) -> Bool {
        guard isSeeking, let chase, chase.minFramePTS == nil else { return false }
        if chase == target { return true }
        // At either end an exact and a keyframe seek land on the same frame, the first or the last: the first press
        // of a burst is exact, the repeats are keyframe seeks.
        let isAtBound = target.seconds == 0 || (media.duration > 0 && target.seconds == media.duration)
        return isAtBound && chase.seconds == target.seconds
    }

    /// Whether a frame step can be served from the warm pipeline + step cache instead of a full keyframe
    /// re-seek: video is loaded, paused, not mid-seek, and the pipeline is positioned contiguously.
    var canFastStepFrame: Bool {
        media.hasVideo && frameStep.isContiguous && !isSeeking && chase == nil && !isPlaying
            && currentFramePTS >= 0
    }

    /// A step pump or a step-induced seek is still resolving. Extra key-repeat presses are dropped here so
    /// we advance one frame at a time (each full seek seeds its window) instead of chaining redundant
    /// full-GOP seeks that outrun the decoder and never let the cache take over.
    ///
    /// Only `isSeeking`/`frameStep.isPumping` indicate work genuinely in flight: a lingering non-nil
    /// `chase` (e.g. a playing seek whose resume debounce was interrupted by pause) is NOT in
    /// flight and must still accept a step — handled by the cold path via `canFastStepFrame`.
    var isStepInFlight: Bool {
        frameStep.isPumping || isSeeking
    }

    public func stepFrameForward() {
        if isStepInFlight { return }
        guard canFastStepFrame else {
            stepFrame(forward: true)
            return
        }
        let baseTime = currentFramePTS
        // 1) Zero-decode: serve the next frame already decoded into the step window.
        if let entry = frameStep.cache.frameAfter(baseTime) {
            presentSteppedFrame(entry, forward: true)
            return
        }
        // 2) Window exhausted forward: decode ahead incrementally from the current contiguous position.
        fastStepFrameForwardByDecoding(from: baseTime)
    }

    public func stepFrameBackward() {
        if isStepInFlight { return }
        guard canFastStepFrame else {
            stepFrame(forward: false)
            return
        }
        // Backward stepping cannot cheaply decode in reverse; serve from the step window or fall back to a
        // full keyframe re-seek (which reseeds the window around the new position).
        if let entry = frameStep.cache.frameBefore(currentFramePTS) {
            presentSteppedFrame(entry, forward: false)
        } else {
            stepFrame(forward: false)
        }
    }

    /// Decodes forward from the current (contiguous) position until a frame past `baseTime` is produced,
    /// appending decoded frames to the step cache. Falls back to a full exact seek if progress stalls.
    private func fastStepFrameForwardByDecoding(from baseTime: Double) {
        guard let demuxer = self.demuxer else { return }
        let decoder = stallGuardedDecoder(for: "the seek queue")
        let frameQueue = self.frameQueue
        let stepCache = self.frameStep.cache

        isSeeking = true
        frameStep.isPumping = true
        resumePlaybackAfterChase = false
        let seekId = seekGeneration.advance()
        let seekGeneration = self.seekGeneration
        let loadID = currentLoadID

        seekQueue.async { [weak self] in
            guard let self else { return }
            let outcome = FrameStepPump.run(
                demuxer: demuxer, decoder: decoder, frameQueue: frameQueue, stepCache: stepCache, after: baseTime,
                isSuperseded: { !seekGeneration.isCurrent(seekId) })

            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentLoadID == loadID else { return }
                self.frameStep.isPumping = false
                // Superseded by a newer seek/step: hand off to the chase machine if one is queued.
                if !self.seekGeneration.isCurrent(seekId) {
                    self.continueChase()
                    return
                }
                self.isSeeking = false
                if let entry = outcome.entry {
                    self.presentSteppedFrame(entry, forward: true)
                } else if outcome.hitBoundary {
                    // Reached EOF / end of readable samples: keep the current frame, stay contiguous.
                    self.frameStep.isContiguous = true
                } else {
                    // Could not advance within the attempt budget: fall back to a correct full seek.
                    self.frameStep.isContiguous = false
                    self.stepFrame(forward: true)
                    return
                }
                // Honor a Play pressed while the pump was decoding (play() deferred it via this flag).
                if self.resumePlaybackAfterChase {
                    self.resumePlaybackAfterChase = false
                    self.play()
                }
            }
        }
    }

    /// Renders a stepped frame and synchronizes clock, timer, and subtitles to its PTS while paused. A step forward
    /// smooths the scene's luminance from the frame before, as playback does; a step back takes the frame's as is:
    /// the frame it smoothed from would come after it, often in the next scene (whose scene refresh it would carry
    /// back across the cut), and playback never steps back for it to match.
    func presentSteppedFrame(_ entry: StepFrameCache.Entry, forward: Bool) {
        let pts = entry.pts.seconds
        renderDirect(
            pixelBuffer: entry.pixelBuffer, pts: pts, hdrMetadata: entry.hdrMetadata, restartsSmoothing: !forward)
        synchronizer.setRate(0.0, time: entry.pts)
        currentTime = pts
        subtitles.timeDidChange(to: pts, .tick)
        onTimeUpdate?(pts, media.duration)
        // Pipeline remains positioned just past the furthest decoded frame — keep fast stepping enabled.
        // The step window lives until playback resumes or a seek repositions the pipeline.
        frameStep.isContiguous = true
        // Cursor has drifted from the last seek baseline; resuming playback must reseek for clean A/V.
        frameStep.didStepSincePause = true
    }

    func stepFrame(forward: Bool) {
        if isPlaying { pause() }
        // The engine's frame duration, not the demuxer's: field-rate deinterlacing steps a field at a time.
        let stepDuration = demuxer != nil ? nominalFrameDuration : (media.hasVideo ? (1.0 / 24.0) : 1.0)
        resumePlaybackAfterChase = false
        let baseTime = chase?.seconds ?? (currentFramePTS >= 0 ? currentFramePTS : currentTime)
        let targetTime = forward ? (baseTime + stepDuration) : (baseTime - stepDuration * 1.05)
        let clampedTarget = clampedSeekTarget(targetTime)
        resetRelativeSeekBurst()
        // A forward step must land on a frame past the one it steps from.
        seek(to: clampedTarget, exact: true, forward: false, minFramePTS: forward ? baseTime + 0.001 : nil)
    }
}

extension PlayerEngine {
    func reportSeekingChange() {
        let seeking = isSeeking || chase != nil
        guard seeking != reportedSeeking else { return }
        reportedSeeking = seeking
        onSeekingChanged?(seeking)
    }
}
