@preconcurrency import AVFoundation
import AppKit
@preconcurrency import CoreMedia
import Foundation
import os

extension PlayerEngine {
    public func seek(to seconds: Double) {
        minStepFramePTS = nil
        seek(to: seconds, exact: true)
    }

    public func seek(to seconds: Double, exact: Bool) {
        resetRelativeSeekBurst()
        minStepFramePTS = nil
        seek(to: seconds, exact: exact, forward: false)
    }

    func resetRelativeSeekBurst() {
        relativeSeekBurstResetTask?.cancel()
        relativeSeekBurstResetTask = nil
        isRelativeSeekBurstActive = false
        isRelativeSeekInFlight = false
        relativeSeekSessionStartTime = nil
    }

    func armRelativeSeekBurstTimer() {
        relativeSeekBurstResetTask?.cancel()
        relativeSeekBurstResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.relativeSeekBurstTimeout)
            guard !Task.isCancelled, let self else { return }
            if !self.isSeeking && self.chaseTargetTime == nil {
                self.resetRelativeSeekBurst()
            } else if !self.isRelativeSeekInFlight {
                self.resetRelativeSeekBurst()
            } else {
                // Safety watchdog: if in-flight seek hangs or takes unusually long, reset unconditionally
                try? await Task.sleep(for: Self.relativeSeekBurstWatchdogTimeout)
                guard !Task.isCancelled else { return }
                self.resetRelativeSeekBurst()
            }
        }
    }

    func seek(to seconds: Double, exact: Bool, forward: Bool) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        AppLog.info(.engine, "Seek requested to seconds: \(target), exact: \(exact), forward: \(forward)")
        guard demuxer != nil else { return }

        // Cancel any pending settle debounce from an earlier seek in the burst
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        cancelPreroll()
        clockSettlingGuardLock.withLock { $0 = nil }

        // 1. Maintain play intent across seek bursts (Apple QA1820 / mpv)
        if !isSeeking && chaseTargetTime == nil {
            resumePlaybackAfterChase = isPlaying
            if isPlaying {
                // Instantly pause playback clock and CADisplayLink during seek burst to prevent clock jitter / drift
                synchronizer.setRate(0.0, time: synchronizer.currentTime())
                displayLink?.isPaused = true
            }
        }

        // 2. Immediate responsive UI update (0ms latency for exact seek)
        chaseTargetTime = target
        chaseExactSeek = exact
        chaseForwardSeek = forward
        if exact {
            currentTime = target
            updateActiveSubtitles(at: target)
        }

        // 3. Increment generation token
        currentSeekId += 1
        let seekId = currentSeekId
        activeSeekId.withLock { $0 = seekId }

        // 4. If a seek is already in flight on seekQueue, let it complete its current work;
        // it will check activeSeekId and latest chaseTargetTime upon finishing.
        if isSeeking { return }

        executeDemuxerSeek()
    }

    /// Restricts displayable frames to those at/after an exact-seek target, like mpv's hr-seek. Half a frame of
    /// tolerance keeps the frame whose display interval contains the target. `nil` (keyframe seeks, start at 0)
    /// lifts the restriction.
    func setExactSeekDisplayFloor(_ targetSeconds: Double?) {
        guard let targetSeconds else {
            frameQueue.setDisplayFloor(.invalid)
            return
        }
        let halfFrame = nominalFrameDurationLock.withLock { $0 } * 0.5
        frameQueue.setDisplayFloor(CMTime(seconds: targetSeconds - halfFrame, preferredTimescale: 90000))
    }

    func executeDemuxerSeek() {
        guard let targetSeconds = chaseTargetTime else { return }
        guard let demuxer = self.demuxer else { return }

        isSeeking = true
        let isExact = self.chaseExactSeek
        let isForward = self.chaseForwardSeek
        let minTargetPts = self.minStepFramePTS
        let seekId = currentSeekId

        let shouldResume = self.resumePlaybackAfterChase

        // Stop feeding packets from the old position.
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        frameQueue.clear(resetDroppedFrames: true)
        setExactSeekDisplayFloor(isExact ? targetSeconds : nil)
        // The pipeline is about to be flushed and repositioned; incremental forward stepping is invalid
        // until this seek settles and re-establishes contiguity. Release the old step window; it is
        // repopulated below for paused exact seeks (the frame-stepping scenario).
        stepDecodeContiguous = false
        didStepSincePause = false
        stepFrameCache.clear()

        let decoder = self.decoder
        let audioDecoder = self.audioDecoder
        let audioSink = self.audioSink
        let hasVideo = self.hasVideo
        let seekIdLock = self.activeSeekId
        let frameQueue = self.frameQueue
        // Seed the step window only for paused exact seeks — when the user is scrubbing/stepping, not
        // during seeks that will resume playback.
        let stepCache: StepFrameCache? = (!shouldResume && isExact) ? self.stepFrameCache : nil

        seekQueue.async { [weak self, demuxer, decoder, frameQueue, stepCache] in
            guard let self else { return }

            let isSuperseded: @Sendable () -> Bool = {
                seekIdLock.withLock { $0 != seekId }
            }

            if !isSuperseded() {
                if hasVideo {
                    decoder.flush()
                }
                demuxer.seek(to: targetSeconds, exact: isExact, forward: isForward)
            }

            var previewFrame: SeekPreviewResult? = nil
            if hasVideo {
                previewFrame = Self.seekPreview(
                    demuxer: demuxer,
                    decoder: decoder,
                    frameQueue: frameQueue,
                    seconds: targetSeconds,
                    exact: isExact,
                    minPts: minTargetPts,
                    stepCache: stepCache,
                    isCurrent: { !isSuperseded() }
                )
                let resolvedSeconds = previewFrame?.pts ?? targetSeconds
                if !isExact, let preview = previewFrame {
                    demuxer.setTargetAudioPts(seconds: preview.pts)
                }
                if !shouldResume {
                    demuxer.purgeAudio(beforeSeconds: resolvedSeconds)
                }
                // Render the freshly previewed frame directly (avoiding queue miss & stale fallback)
                if !isSuperseded(), let preview = previewFrame {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.currentSeekId == seekId else { return }
                        self.renderDirect(pixelBuffer: preview.pixelBuffer, pts: preview.pts)
                    }
                }
            }

            // Expensive audio reset only for the seek that is still current (final chase target).
            if !isSuperseded() {
                audioDecoder?.flush()
                audioSink.flush()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // If superseded by a newer target, immediately continue to the latest chase position
                if self.currentSeekId != seekId {
                    if self.chaseTargetTime != nil {
                        self.executeDemuxerSeek()
                    } else {
                        self.isSeeking = false
                        self.isRelativeSeekInFlight = false
                        self.minStepFramePTS = nil
                    }
                    return
                }
                let resolvedSeconds = previewFrame?.pts ?? targetSeconds
                let resolvedTime = CMTime(seconds: resolvedSeconds, preferredTimescale: 1000)
                let didRenderPreview = previewFrame != nil
                self.completeChaseSeek(
                    targetSeconds: targetSeconds,
                    completedSeconds: resolvedSeconds,
                    targetTime: resolvedTime,
                    seekId: seekId,
                    didRenderPreview: didRenderPreview
                )
            }
        }
    }

    func completeChaseSeek(
        targetSeconds: Double,
        completedSeconds: Double,
        targetTime: CMTime,
        seekId: Int,
        didRenderPreview: Bool
    ) {
        guard currentSeekId == seekId else {
            if chaseTargetTime != nil {
                executeDemuxerSeek()
            } else {
                self.isSeeking = false
                self.isRelativeSeekInFlight = false
                self.minStepFramePTS = nil
            }
            return
        }

        // Check if user requested a newer position while this seek was executing (Apple QA1820 / mpv queue_seek)
        if let latestTarget = chaseTargetTime, abs(latestTarget - targetSeconds) > 0.001 {
            // Chase the newer target immediately without resuming yet.
            executeDemuxerSeek()
            return
        }

        // Settled decoding for this position. Mark seek background work as done.
        isSeeking = false
        minStepFramePTS = nil

        // If a preview frame was already rendered directly via renderDirect, do NOT overwrite it
        // by popping from frameQueue.getLatestFrame (which may drop preroll frames tagged doNotDisplay).
        if hasVideo && !didRenderPreview {
            renderCurrentFrame(at: targetTime)
        }

        // Immediately apply actual completed PTS so timer and subtitles match the displayed keyframe
        self.currentTime = completedSeconds
        updateActiveSubtitles(at: completedSeconds)
        onTimeUpdate?(completedSeconds, duration)

        if isRelativeSeekInFlight {
            isRelativeSeekInFlight = false
            armRelativeSeekBurstTimer()
        }

        if let sessionStart = relativeSeekSessionStartTime {
            let actualOffset = completedSeconds - sessionStart
            onRelativeSeekResolved?(actualOffset, completedSeconds)
        }

        let shouldResume = resumePlaybackAfterChase
        if !shouldResume {
            // Paused mode: settle immediately
            chaseTargetTime = nil
            clockSettlingGuardLock.withLock { $0 = nil }
            synchronizer.setRate(0.0, time: targetTime)
            isPlaying = false
            playbackState = .paused
            performanceMonitor.handlePlaybackStateChange(isPlaying: false)
            // Exact seeks leave the decoder warm and positioned just past the displayed frame (preview
            // over-reads a few frames into the queue). This enables incremental forward frame-stepping.
            stepDecodeContiguous = hasVideo && chaseExactSeek
            AppLog.debug(.engine, "Chase seek settled at \(completedSeconds)s (paused)")
            return
        }

        // Playing mode: debounce resumption slightly (300ms) so that sustained key-hold repeat
        // events (which fire every 40-70ms) don't repeatedly unpause and roll the clock forward.
        chaseTargetTime = completedSeconds
        chaseSettleTask?.cancel()
        chaseSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.chaseSettleDebounceDuration)
            guard !Task.isCancelled, let self, self.currentSeekId == seekId else { return }

            self.chaseTargetTime = nil
            self.startFeeding()
            self.startSynchronizerClockAfterPreroll(at: targetTime)
            self.displayLink?.isPaused = !self.hasVideo
            self.isPlaying = true
            self.playbackState = .playing
            self.performanceMonitor.handlePlaybackStateChange(isPlaying: true)
            AppLog.debug(.engine, "Chase seek settled and resumed at \(completedSeconds)s")
        }
    }

    struct SeekPreviewResult: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let pts: Double
    }

    final class SeekPreviewBox: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var pts: Double = -1.0
    }

    nonisolated static func seekPreview(
        demuxer: MediaDemuxer,
        decoder: any VideoDecoderProtocol,
        frameQueue: FrameQueue,
        seconds: Double,
        exact: Bool,
        minPts: Double? = nil,
        stepCache: StepFrameCache? = nil,
        isCurrent: @Sendable () -> Bool
    ) -> SeekPreviewResult? {
        let lock = OSAllocatedUnfairLock()
        let box = SeekPreviewBox()
        let isStepForward = (minPts != nil)
        // When seeding the step-frame cache (paused seek), decode all frames (discard disabled) for a wider
        // window before the target so backward stepping has ~1s of depth available; otherwise just 0.5s.
        let stepWindow: Double = stepCache != nil ? 1.1 : 0.5
        // Only cache a small margin past the target: the trailing over-read (`extraPipelineAttempts`) would
        // otherwise occupy the fixed-capacity cache with forward frames and starve backward-step depth.
        let stepForwardMargin: Double = 0.25
        // Discarding non-reference B-frames during step-frame forward drops intermediate frames!
        // Only discard non-reference frames when doing larger jumps.
        if exact && !isStepForward {
            decoder.setDiscardNonReferenceFrames(true)
        }
        decoder.setOutputHandler { frame in
            if !frame.doNotDisplay {
                frameQueue.push(frame)
            }
            // Seed the step cache with every decoded frame in the window — including exact-seek preroll
            // frames flagged `doNotDisplay` (which carry valid pixel buffers). They are precisely the
            // frames below the target that backward stepping needs; the flag only suppresses them from the
            // transient seek preview, not from deliberate frame-by-frame display.
            if let stepCache, frame.pts.isValid,
                frame.pts.seconds >= seconds - stepWindow,
                frame.pts.seconds <= seconds + stepForwardMargin
            {
                stepCache.append(
                    pixelBuffer: frame.pixelBuffer, pts: frame.pts, doviMetadata: frame.doviMetadata)
            }
            if (exact || !frame.doNotDisplay) && frame.pts.isValid {
                lock.lock()
                let framePts = frame.pts.seconds
                let shouldUpdate: Bool
                if let minPts {
                    // Forward step seek: candidate must satisfy minPts to guarantee forward progress
                    if framePts >= minPts {
                        if box.buffer == nil {
                            shouldUpdate = true
                        } else if box.pts < minPts {
                            shouldUpdate = true
                        } else {
                            shouldUpdate = abs(framePts - seconds) < abs(box.pts - seconds)
                        }
                    } else {
                        // Keep closest fallback if no frame >= minPts has been seen yet
                        if box.buffer == nil {
                            shouldUpdate = true
                        } else if box.pts < minPts {
                            shouldUpdate = abs(framePts - seconds) <= abs(box.pts - seconds)
                        } else {
                            shouldUpdate = false
                        }
                    }
                } else if box.buffer == nil {
                    shouldUpdate = true
                } else if exact {
                    // Exact seek: select the decoded frame closest to the requested target time,
                    // handling out-of-order B-frames and trailing pipeline flushes accurately.
                    shouldUpdate = abs(framePts - seconds) <= abs(box.pts - seconds)
                } else {
                    // Keyframe seek: keep the earliest displayable frame (frame-threaded decoders
                    // may emit several frames once their pipeline fills).
                    shouldUpdate = framePts < box.pts
                }

                if shouldUpdate {
                    box.buffer = frame.pixelBuffer
                    box.pts = framePts
                }
                lock.unlock()
            }
        }

        defer {
            decoder.setDiscardNonReferenceFrames(false)
            decoder.setOutputHandler { [weak frameQueue] frame in
                if !frame.doNotDisplay {
                    frameQueue?.push(frame)
                }
            }
        }

        let hasPreview: () -> Bool = {
            lock.lock()
            defer { lock.unlock() }
            return box.buffer != nil
        }

        let hasSatisfiedMinPts: () -> Bool = {
            guard let minPts else { return hasPreview() }
            lock.lock()
            defer { lock.unlock() }
            return box.buffer != nil && box.pts >= minPts
        }

        var attempts = 0
        var reachedTargetPacket = false
        var extraPipelineAttempts = 0
        var foundTarget = false
        var decodedAtLeastOne = false
        var hasCalculatedMaxAttempts = false
        // For non-exact (keyframe) seeks (IINA / mpv style), decode from the keyframe until the decoder
        // emits its first frame (1 packet for VideoToolbox; a few for frame-threaded libdav1d).
        // For exact seeks, decode from keyframe up to target seconds, dynamically sizing the attempt limit
        // based on the distance between the landing keyframe and the requested target position.
        var maxAttempts = exact ? 120 : 24
        while attempts < maxAttempts && !foundTarget && (isCurrent() || !decodedAtLeastOne) {
            if let sample = demuxer.nextVideoSample() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let ptsSeconds = CMTimeGetSeconds(pts)

                if exact && !hasCalculatedMaxAttempts && ptsSeconds.isFinite {
                    hasCalculatedMaxAttempts = true
                    // Dynamic ceiling: estimate needed packets from keyframe to target position.
                    // Generous 60fps * 1.5 multiplier + buffer accommodates 60fps streams, VFR, and B-frame reordering.
                    let distance = max(seconds - ptsSeconds, 1.0)
                    let estimatedPackets = Int(distance * 90.0) + 64
                    maxAttempts = min(max(estimatedPackets, 120), 1200)
                }

                if exact && !isStepForward && ptsSeconds.isFinite && ptsSeconds >= (seconds - stepWindow) {
                    // Near target window: restore all frames (including non-reference B-frames)
                    decoder.setDiscardNonReferenceFrames(false)
                }

                decoder.decode(sampleBuffer: sample)
                decodedAtLeastOne = true
                attempts += 1
                if exact {
                    if ptsSeconds >= seconds {
                        reachedTargetPacket = true
                    }
                    if reachedTargetPacket {
                        decoder.waitForPendingFrames()
                        // Ensure we feed at least 6 packets past reachedTargetPacket so that
                        // any trailing B-frames or reordered pictures in display order are decoded.
                        extraPipelineAttempts += 1
                        if hasSatisfiedMinPts() && extraPipelineAttempts >= 6 {
                            foundTarget = true
                        } else if extraPipelineAttempts >= 16 {
                            foundTarget = true
                        }
                    }
                } else {
                    decoder.waitForPendingFrames()
                    if hasPreview() { foundTarget = true }
                }
            } else {
                break
            }
        }
        // Non-destructive: decoding continues from the next packet in runVideoFeeding, so the
        // decoder's reference frames must be preserved (a destructive flush breaks AV1/dav1d).
        decoder.waitForPendingFrames()

        lock.lock()
        let finalBuf = box.buffer
        let finalPts = box.pts
        lock.unlock()

        if let finalBuf, finalPts >= 0 {
            AppLog.debug(
                .engine,
                "seekPreview settled: pts=\(finalPts)s for target=\(seconds)s (exact=\(exact), attempts=\(attempts))")
            return SeekPreviewResult(pixelBuffer: finalBuf, pts: finalPts)
        }
        AppLog.debug(
            .engine, "seekPreview found no frame for target=\(seconds)s (exact=\(exact), attempts=\(attempts))")
        return nil
    }

    @discardableResult
    public func seekRelative(by seconds: Double) -> Double {
        guard isLoaded, demuxer != nil else { return 0.0 }
        armRelativeSeekBurstTimer()
        minStepFramePTS = nil

        let isFirstInBurst = !isRelativeSeekBurstActive && !isRelativeSeekInFlight
        isRelativeSeekBurstActive = true
        isRelativeSeekInFlight = true

        // While a seek is in flight, baseTime steps from the pending target (mpv queue_seek model).
        // On slow frame-threaded streams (e.g. software AV1), rapid keypresses advance the goal,
        // while the demuxer chases the latest target to prevent stale frame freezes.
        let baseTime = chaseTargetTime ?? currentTime
        if isFirstInBurst || relativeSeekSessionStartTime == nil {
            relativeSeekSessionStartTime = baseTime
        }

        let isExact = !hasVideo || (exactSeekOnSinglePress && isFirstInBurst)
        let isForward = seconds > 0 && !isExact

        // In burst mode (keyframe seek), always step from the latest targeted or settled frame
        // so every press advances past the current GOP to the next/prev keyframe without freezing.
        seek(to: baseTime + seconds, exact: isExact, forward: isForward)

        let startPos = relativeSeekSessionStartTime ?? baseTime
        return (chaseTargetTime ?? currentTime) - startPos
    }

    public func seekRelative(by seconds: Double, exact: Bool) {
        resetRelativeSeekBurst()
        minStepFramePTS = nil
        let baseTime = chaseTargetTime ?? currentTime
        // Forward keyframe steps must land on the next keyframe; a backward search on sparse-GOP
        // streams (AV1) would snap back to the current keyframe and the position would never advance.
        seek(to: baseTime + seconds, exact: exact, forward: seconds > 0 && !exact)
    }

    /// Whether a frame step can be served from the warm pipeline + step cache instead of a full keyframe
    /// re-seek: video is loaded, paused, not mid-seek, and the pipeline is positioned contiguously.
    var canFastStepFrame: Bool {
        hasVideo && stepDecodeContiguous && !isSeeking && chaseTargetTime == nil && !isPlaying
            && currentFramePTS >= 0
    }

    /// A step pump or a step-induced seek is still resolving. Extra key-repeat presses are dropped here so
    /// we advance one frame at a time (each full seek seeds its window) instead of chaining redundant
    /// full-GOP seeks that outrun the decoder and never let the cache take over.
    ///
    /// Only `isSeeking`/`isStepPumping` indicate work genuinely in flight: a lingering non-nil
    /// `chaseTargetTime` (e.g. a playing seek whose resume debounce was interrupted by pause) is NOT in
    /// flight and must still accept a step — handled by the cold path via `canFastStepFrame`.
    var isStepInFlight: Bool {
        isStepPumping || isSeeking
    }

    public func stepFrameForward() {
        if isStepInFlight { return }
        guard canFastStepFrame else {
            stepFrame(forward: true)
            return
        }
        let baseTime = currentFramePTS
        // 1) Zero-decode: serve the next frame already decoded into the step window.
        if let entry = stepFrameCache.frameAfter(baseTime) {
            presentSteppedFrame(entry)
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
        if let entry = stepFrameCache.frameBefore(currentFramePTS) {
            presentSteppedFrame(entry)
        } else {
            stepFrame(forward: false)
        }
    }

    /// Decodes forward from the current (contiguous) position until a frame past `baseTime` is produced,
    /// appending decoded frames to the step cache. Falls back to a full exact seek if progress stalls.
    private func fastStepFrameForwardByDecoding(from baseTime: Double) {
        guard let demuxer = self.demuxer else { return }
        let decoder = self.decoder
        let frameQueue = self.frameQueue
        let stepCache = self.stepFrameCache

        isSeeking = true
        isStepPumping = true
        resumePlaybackAfterChase = false
        currentSeekId += 1
        let seekId = currentSeekId
        let seekIdLock = self.activeSeekId
        seekIdLock.withLock { $0 = seekId }

        seekQueue.async { [weak self] in
            guard let self else { return }
            let isSuperseded: @Sendable () -> Bool = { seekIdLock.withLock { $0 != seekId } }

            // Route decoded frames into the step cache during the pump, then restore the playback handler.
            decoder.setOutputHandler { frame in
                if !frame.doNotDisplay, frame.pts.isValid {
                    stepCache.append(
                        pixelBuffer: frame.pixelBuffer, pts: frame.pts, doviMetadata: frame.doviMetadata)
                }
            }
            defer {
                decoder.setOutputHandler { frame in
                    if !frame.doNotDisplay { frameQueue.push(frame) }
                }
            }

            var entry: StepFrameCache.Entry? = nil
            var hitBoundary = false
            var attempts = 0
            // Keep decoding a few frames past the one we need so subsequent (including key-repeat) forward
            // steps are served straight from the cache without re-entering a pump.
            let prefetchAhead = 6
            // A contiguous position never needs a whole GOP; this covers decoder reorder depth plus margin.
            let maxAttempts = 48
            while attempts < maxAttempts && !isSuperseded() {
                guard let sample = demuxer.nextVideoSample() else {
                    hitBoundary = true
                    break
                }
                decoder.decode(sampleBuffer: sample)
                decoder.waitForPendingFrames()
                attempts += 1
                if entry == nil {
                    entry = stepCache.frameAfter(baseTime)
                }
                // Once the target frame exists, stop after enough look-ahead frames are buffered.
                if entry != nil, stepCache.countAfter(baseTime) >= prefetchAhead + 1 {
                    break
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isStepPumping = false
                // Superseded by a newer seek/step: hand off to the chase machine if one is queued.
                if self.currentSeekId != seekId {
                    if self.chaseTargetTime != nil {
                        self.executeDemuxerSeek()
                    } else {
                        self.isSeeking = false
                    }
                    return
                }
                self.isSeeking = false
                if let entry {
                    self.presentSteppedFrame(entry)
                } else if hitBoundary {
                    // Reached EOF / end of readable samples: keep the current frame, stay contiguous.
                    self.stepDecodeContiguous = true
                } else {
                    // Could not advance within the attempt budget: fall back to a correct full seek.
                    self.stepDecodeContiguous = false
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

    /// Renders a stepped frame and synchronizes clock, timer, and subtitles to its PTS while paused.
    func presentSteppedFrame(_ entry: StepFrameCache.Entry) {
        let pts = entry.pts.seconds
        renderDirect(pixelBuffer: entry.pixelBuffer, pts: pts, doviMetadata: entry.doviMetadata)
        synchronizer.setRate(0.0, time: entry.pts)
        currentTime = pts
        updateActiveSubtitles(at: pts)
        onTimeUpdate?(pts, duration)
        // Pipeline remains positioned just past the furthest decoded frame — keep fast stepping enabled.
        // The step window lives until playback resumes or a seek repositions the pipeline.
        stepDecodeContiguous = true
        // Cursor has drifted from the last seek baseline; resuming playback must reseek for clean A/V.
        didStepSincePause = true
    }

    func stepFrame(forward: Bool) {
        if isPlaying { pause() }
        let stepDuration = demuxer?.nominalFrameDuration ?? (hasVideo ? (1.0 / 24.0) : 1.0)
        resumePlaybackAfterChase = false
        let baseTime = chaseTargetTime ?? (currentFramePTS >= 0 ? currentFramePTS : currentTime)
        let targetTime = forward ? (baseTime + stepDuration) : (baseTime - stepDuration * 1.05)
        let clampedTarget = max(0, duration > 0 ? min(targetTime, duration) : targetTime)
        if forward {
            // Require the next settled frame to be at least baseTime + 0.001s
            minStepFramePTS = baseTime + 0.001
        } else {
            minStepFramePTS = nil
        }
        seek(to: clampedTarget)
    }
}
