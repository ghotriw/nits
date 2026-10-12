@preconcurrency import AVFoundation
import AppKit
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

        // 1. Maintain play intent across seek bursts (Apple QA1820 / mpv)
        if !isSeeking && chaseTargetTime == nil {
            resumePlaybackAfterChase = isPlaying
            if isPlaying {
                // Instantly pause playback clock during active seek burst to prevent clock jitter
                synchronizer.setRate(0.0, time: synchronizer.currentTime())
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

    func executeDemuxerSeek() {
        guard let targetSeconds = chaseTargetTime else { return }
        guard let demuxer = self.demuxer else { return }

        isSeeking = true
        let isExact = self.chaseExactSeek
        let isForward = self.chaseForwardSeek
        let seekId = currentSeekId

        let shouldResume = self.resumePlaybackAfterChase

        // Stop feeding packets from the old position.
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        frameQueue.clear(resetDroppedFrames: true)

        let decoder = self.decoder
        let audioDecoder = self.audioDecoder
        let audioReceiver = self.audioReceiver
        let hasVideo = self.hasVideo
        let seekIdLock = self.activeSeekId
        let frameQueue = self.frameQueue

        seekQueue.async { [weak self, demuxer, decoder, frameQueue] in
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
                audioReceiver.flush()
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
            synchronizer.setRate(0.0, time: targetTime)
            isPlaying = false
            playbackState = .paused
            performanceMonitor.handlePlaybackStateChange(isPlaying: false)
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
            self.synchronizer.setRate(Float(self.playbackRate), time: targetTime)
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
        isCurrent: @Sendable () -> Bool
    ) -> SeekPreviewResult? {
        let lock = OSAllocatedUnfairLock()
        let box = SeekPreviewBox()
        if exact {
            decoder.setDiscardNonReferenceFrames(true)
        }
        decoder.setOutputHandler { frame in
            if !frame.doNotDisplay {
                frameQueue.push(frame)
            }
            if (exact || !frame.doNotDisplay) && frame.pts.isValid {
                lock.lock()
                let framePts = frame.pts.seconds
                let shouldUpdate: Bool
                if box.buffer == nil {
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

                if exact && ptsSeconds.isFinite && ptsSeconds >= (seconds - 0.5) {
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
                        if hasPreview() && extraPipelineAttempts >= 6 {
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
        let baseTime = chaseTargetTime ?? currentTime
        // Forward keyframe steps must land on the next keyframe; a backward search on sparse-GOP
        // streams (AV1) would snap back to the current keyframe and the position would never advance.
        seek(to: baseTime + seconds, exact: exact, forward: seconds > 0 && !exact)
    }

    public func stepFrameForward() {
        stepFrame(forward: true)
    }

    public func stepFrameBackward() {
        stepFrame(forward: false)
    }

    func stepFrame(forward: Bool) {
        if isPlaying { pause() }
        let stepDuration = demuxer?.nominalFrameDuration ?? (hasVideo ? (1.0 / 24.0) : 1.0)
        resumePlaybackAfterChase = false
        let baseTime = chaseTargetTime ?? (currentFramePTS >= 0 ? currentFramePTS : currentTime)
        let targetTime = forward ? (baseTime + stepDuration) : (baseTime - stepDuration * 1.05)
        let clampedTarget = max(0, duration > 0 ? min(targetTime, duration) : targetTime)
        seek(to: clampedTarget)
    }
}
