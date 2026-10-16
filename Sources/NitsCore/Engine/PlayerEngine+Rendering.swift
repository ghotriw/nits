@preconcurrency import AVFoundation
import AppKit
@preconcurrency import CoreMedia
import Foundation
import QuartzCore
import os

extension PlayerEngine {
    func setupDisplayLink() {
        let target = DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target

        // If a screen is available on initialization, attach CADisplayLink to NSScreen.main
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
            link.add(to: DisplayLinkThread.shared.runLoop, forMode: .default)
            link.isPaused = true
            self.displayLink = link
            updateDisplayLinkFrameRate()
        }
    }

    /// Attaches the engine's CADisplayLink to the video rendering host view.
    /// This ensures accurate VBLANK sync across ProMotion (120Hz) displays and seamless multi-monitor transitions.
    public func attachDisplayLink(to view: NSView) {
        displayLink?.invalidate()
        let target = displayLinkTarget ?? DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target

        let link = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        link.add(to: DisplayLinkThread.shared.runLoop, forMode: .default)
        link.isPaused = !isPlaying
        self.displayLink = link
        self.displayLinkHostView = view
        guard !isPictureInPictureActive else {
            retargetDisplayLinkForPictureInPicture()
            return
        }
        updateDisplayLinkFrameRate()
    }

    /// A view-based link stops when its window is hidden, which PiP usually does. While PiP is active the link
    /// follows the screen; on exit it returns to the host view.
    func retargetDisplayLinkForPictureInPicture() {
        let target = displayLinkTarget ?? DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target
        let link: CADisplayLink
        if isPictureInPictureActive {
            guard let screen = displayLinkHostView?.window?.screen ?? NSScreen.main else { return }
            link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        } else if let view = displayLinkHostView {
            link = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        } else {
            return
        }
        displayLink?.invalidate()
        link.add(to: DisplayLinkThread.shared.runLoop, forMode: .default)
        link.isPaused = !isPlaying
        self.displayLink = link
        AppLog.debug(.video, "Display link follows \(isPictureInPictureActive ? "screen (PiP)" : "host view")")
        updateDisplayLinkFrameRate()
    }

    // MARK: - Display Link Frame Rate

    /// Lowest tick rate worth requesting: below it a single late tick costs a whole content frame.
    nonisolated static let minimumSmoothDisplayLinkRate = 48

    /// Requests a display-link rate matched to the content's frame rate on the current screen.
    ///
    /// Each tick presents a frame, so the tick rate is the presentation cadence. A rate that is not a multiple of
    /// the content rate shows frames for uneven durations (24 fps on 60 Hz → 3:2 pulldown judder), while
    /// unconditionally running at the panel maximum costs ProMotion power for content that does not need it.
    /// Call when the content frame rate or the screen changes.
    public func updateDisplayLinkFrameRate() {
        guard let displayLink else { return }
        let screen = displayLinkHostView?.window?.screen ?? NSScreen.main
        let screenMaxRate = screen?.maximumFramesPerSecond ?? 60
        let rate = Self.preferredDisplayLinkRate(
            contentFrameDuration: nominalFrameDuration, screenMaximumRate: screenMaxRate)
        // Pinned rather than a range: allowed to go lower, Core Animation may pick a rate that is not a multiple of the
        // content (60 Hz for 24p → 3:2 judder, 30 Hz for 60 fps → every other frame). System caps such as Low Power
        // Mode still override it.
        let range = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        guard displayLink.preferredFrameRateRange != range else { return }
        displayLink.preferredFrameRateRange = range
        AppLog.debug(
            .video,
            "Display link rate: \(rate) Hz for \(String(format: "%.3f", 1.0 / nominalFrameDuration)) fps content on a \(screenMaxRate) Hz screen"
        )
    }

    /// Hands `deinterlaceMode` to the decoder of interlaced content and paces at the rate it then delivers: a
    /// frame per field moves the display link, the frame-queue lead window, the exact-seek floor and frame steps
    /// to the field rate. With `refresh`, frames already decoded in the old mode are replaced by re-seeking to
    /// the current frame.
    func applyDeinterlaceMode(refresh: Bool) {
        guard isInterlacedContent, let demuxer else { return }
        decoder.setDeinterlaceMode(deinterlaceMode)
        let frameDuration =
            decoder.outputsFieldRate
            ? FieldTiming.fieldDuration(ofFrameDuration: demuxer.nominalFrameDuration) : demuxer.nominalFrameDuration
        nominalFrameDuration = frameDuration
        nominalFrameDurationLock.withLock { $0 = frameDuration }
        updateDisplayLinkFrameRate()
        guard refresh, isLoaded else { return }
        seek(to: currentFramePTS >= 0 ? currentFramePTS : currentTime, exact: true)
    }

    /// The display link only delivers rates that divide the screen's maximum refresh rate (120 Hz ProMotion:
    /// 120/60/40/30/24). Picks the lowest such rate, not below `minimumSmoothDisplayLinkRate`, that is a whole
    /// multiple of the content rate (23.976 → 120, 29.97 → 60, 24 on 144 Hz → 48); otherwise the screen maximum,
    /// whose finer tick spacing keeps the unavoidable cadence error smallest (25 / 50 fps on 120 Hz).
    nonisolated static func preferredDisplayLinkRate(contentFrameDuration: Double, screenMaximumRate: Int) -> Int {
        let maxRate = max(screenMaximumRate, 1)
        guard contentFrameDuration.isFinite, contentFrameDuration > 0 else { return maxRate }
        let contentRate = 1.0 / contentFrameDuration

        for divisor in stride(from: maxRate, through: 1, by: -1) where maxRate % divisor == 0 {
            let rate = maxRate / divisor
            guard rate >= minimumSmoothDisplayLinkRate else { continue }
            let ticksPerFrame = Double(rate) / contentRate
            let wholeTicks = ticksPerFrame.rounded()
            // 1% covers NTSC rates (23.976, 29.97, 59.94) against their integer counterparts.
            if wholeTicks >= 1 && abs(ticksPerFrame - wholeTicks) / wholeTicks < 0.01 {
                return rate
            }
        }
        return maxRate
    }
    func updateEffectiveRenderMode() {
        let newMode: RenderMode
        switch renderMode {
        case .auto:
            // Metal tone mapping is ONLY needed when video content is HDR and display is SDR
            if isHDRContent && !isHDRDisplay && isToneMappingPermitted && !isPictureInPictureActive {
                newMode = .metalToneMap
            } else {
                newMode = .system
            }
        case .system:
            newMode = .system
        case .metalToneMap:
            newMode = isToneMappingPermitted && !isPictureInPictureActive ? .metalToneMap : .system
        }
        let previousMode = activeRenderModeLock.withLock { mode -> RenderMode in
            let prev = mode
            mode = newMode
            return prev
        }

        guard previousMode != newMode else { return }

        if newMode == .system {
            isMetalLayerVisible = false
            performanceMonitor.updateToneMapParams(
                PlayerPerformanceMonitor.ToneMapParams(mode: .appleXDR)
            )
            if !isPlaying {
                renderCurrentFrame()
            }
        } else {
            let (baseMode, peak, target) = dynamicToneMapLock.withLock {
                state -> (PlayerPerformanceMonitor.ToneMapEngineMode, Float, Float) in
                let mode: PlayerPerformanceMonitor.ToneMapEngineMode
                if state.lastRenderModeName.contains("DoVi L2") {
                    mode = .doviL2Trim
                } else if state.lastRenderModeName.contains("DoVi L1") {
                    mode = .doviL1Auto
                } else if state.basePeakNits > 105.0 {
                    mode = .bt2390
                } else {
                    mode = .directSDR
                }
                return (mode, state.basePeakNits, state.baseTargetNits)
            }
            performanceMonitor.updateToneMapParams(
                PlayerPerformanceMonitor.ToneMapParams(mode: baseMode, peakNits: peak, targetNits: target)
            )
            if !isPlaying {
                renderCurrentFrame()
                isMetalLayerVisible = true
            }
        }

        if showDebugHUD {
            currentMetrics = performanceMonitor.currentMetrics
        }
    }

    nonisolated func presentToDisplayLayer(pixelBuffer: CVPixelBuffer) {
        nonisolated(unsafe) let pb = pixelBuffer
        // Unchecked: the sample never leaves this thread.
        let sampleBuffer = cachedVideoFormatDescription.withLockUnchecked { cached in
            Self.makeDisplaySampleBuffer(for: pb, formatDescription: &cached).sample
        }
        guard let sample = sampleBuffer else { return }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary],
            let dic = attachmentsArray.first
        {
            dic[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        enqueueToDisplayLayer(sample)
    }

    /// Wraps `pixelBuffer` in a sample buffer, reusing `formatDescription` while it still fits and replacing it
    /// when it does not; `rebuilt` tells which.
    ///
    /// Creating the sample checks the description against the buffer's attachments itself (dimensions, pixel
    /// format and the extensions in `CMVideoFormatDescriptionGetExtensionKeysCommonWithImageBuffers`) and fails
    /// with `kCMSampleBufferError_InvalidMediaFormat` on a mismatch. Reading an IOSurface-backed buffer's
    /// attachments is a kernel round trip, so a separate `CMVideoFormatDescriptionMatchesImageBuffer` per frame
    /// would make two.
    nonisolated static func makeDisplaySampleBuffer(
        for pixelBuffer: CVPixelBuffer, formatDescription: inout CMVideoFormatDescription?
    ) -> (sample: CMSampleBuffer?, rebuilt: Bool) {
        func makeSample(_ description: CMVideoFormatDescription) -> CMSampleBuffer? {
            let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: description,
                sampleTiming: [timing],
                sampleBufferOut: &sampleBuffer
            )
            return status == noErr ? sampleBuffer : nil
        }

        if let formatDescription, let sample = makeSample(formatDescription) {
            return (sample, false)
        }
        var newDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &newDescription
        )
        guard status == noErr, let newDescription else { return (nil, true) }
        formatDescription = newDescription
        return (makeSample(newDescription), true)
    }

    /// - Parameter targetTimestamp: Host time of the vsync at which the frame picked in this tick reaches the screen.
    nonisolated func displayLinkTick(targetTimestamp: CFTimeInterval) {
        pendingClockStartLock.withLock { $0?.displayLinkTicks += 1 }
        alignPendingClockStartWithFirstFrame()
        let clockNow = synchronizer.currentTime()
        guard clockNow.isNumeric else { return }
        let now = CACurrentMediaTime()

        // Pick frames for the clock at the target vsync, not at callback time. The callback runs on the main run
        // loop and its latency varies by milliseconds (UI work, cursor moves, ProMotion rate changes); sampling the
        // clock there turns that jitter into skipped frames whenever content fps is close to the link rate
        // (50 fps on 60 Hz tolerates only ~3 ms). Target timestamps are vsync-spaced, so the jitter cancels out.
        let lookahead = min(max(targetTimestamp - now, 0), Self.maxVsyncLookaheadSeconds)
        let clockRate = CMTimebaseGetRate(synchronizer.timebase)
        let currentSyncTime = clockNow + CMTime(seconds: lookahead * clockRate, preferredTimescale: 1_000_000)

        let droppedBefore = frameQueue.pipelineDroppedFramesCount
        let vsyncIntervalMs = tickDiagnosticsLock.withLock { state -> Double in
            defer { state.lastTargetTimestamp = targetTimestamp }
            return state.lastTargetTimestamp > 0 ? (targetTimestamp - state.lastTargetTimestamp) * 1000.0 : 0
        }

        // Stale clock leap protection: if playback or seek just started, verify the hardware clock
        // has settled into the active playback window before popping video frames.
        let shouldHoldFrame = clockSettlingGuardLock.withLock { guardState -> Bool in
            guard let state = guardState else { return false }
            let elapsedHost = now - state.setHostTime
            // Safety timeout: after 0.35s unconditionally clear guard so video never hangs.
            if elapsedHost >= Self.clockSettlingTimeoutSeconds {
                guardState = nil
                return false
            }
            let clockSeconds = clockNow.seconds
            let baseTolerance = Self.clockSettlingBaseToleranceSeconds
            let minAllowedClock = state.targetSeconds - baseTolerance
            let maxAllowedClock = state.targetSeconds + (state.rate * elapsedHost) + baseTolerance
            if clockSeconds < minAllowedClock || clockSeconds > maxAllowedClock {
                // Clock has not yet transitioned/settled to target window. Hold frame.
                return true
            }
            // Clock is aligned with target start time. Clear transient guard atomically.
            guardState = nil
            return false
        }
        if shouldHoldFrame {
            return
        }

        let start = CACurrentMediaTime()
        let frameDuration = nominalFrameDurationLock.withLock { $0 }
        let currentRate = playbackRateLock.withLock { $0 }
        if let popped = frameQueue.popFrame(
            forSyncTime: currentSyncTime,
            nominalFrameDuration: frameDuration,
            playbackRate: currentRate
        ) {
            let durationMs = (CACurrentMediaTime() - start) * 1000.0
            let qCount = frameQueue.count
            let isPaused = isVideoDrainPaused.withLock { $0 }
            let driftMs = popped.pts.isValid ? (popped.pts.seconds - currentSyncTime.seconds) * 1000.0 : 0.0
            if abs(driftMs) > Self.syncDriftSpikeThresholdMs {
                let shouldLog = lastSyncDriftSpikeInstant.withLock { lastInstant -> Bool in
                    let nowInstant = ContinuousClock.now
                    if (nowInstant - lastInstant) >= .seconds(1) {
                        lastInstant = nowInstant
                        return true
                    }
                    return false
                }
                if shouldLog {
                    AppLog.warning(
                        .video,
                        "A/V sync drift spike: \(String(format: "%.1f", driftMs))ms! frame PTS: \(String(format: "%.3f", popped.pts.seconds))s, clock: \(String(format: "%.3f", currentSyncTime.seconds))s, queueCount: \(qCount)"
                    )
                }
            }
            let dropped = frameQueue.droppedFramesCount
            let pipelineDropped = frameQueue.pipelineDroppedFramesCount
            let speedSkipped = frameQueue.speedSkippedFramesCount

            let mode = activeRenderMode
            if mode == .metalToneMap {
                let currentModeName = applyDynamicToneMap(doviMetadata: popped.doviMetadata)
                metalRenderer?.render(pixelBuffer: popped.pixelBuffer)
                performanceMonitor.recordRenderedFrame(
                    durationMs: durationMs,
                    queueCount: qCount,
                    renderModeName: currentModeName,
                    isDrainPaused: isPaused,
                    avSyncDriftMs: driftMs,
                    droppedFrames: dropped,
                    pipelineDroppedFrames: pipelineDropped,
                    speedSkippedFrames: speedSkipped,
                    playbackRate: currentRate
                )

                let becameVisible = isMetalLayerVisibleLock.withLock { visible -> Bool in
                    guard !visible else { return false }
                    visible = true
                    return true
                }
                if becameVisible {
                    DispatchQueue.main.async { [weak self] in
                        self?.isMetalLayerVisible = true
                    }
                }
            } else {
                presentToDisplayLayer(pixelBuffer: popped.pixelBuffer)
                performanceMonitor.updateToneMapParams(
                    PlayerPerformanceMonitor.ToneMapParams(mode: .appleXDR)
                )
                performanceMonitor.recordRenderedFrame(
                    durationMs: durationMs,
                    queueCount: qCount,
                    renderModeName: "Apple HDR (AVSBDL)",
                    isDrainPaused: isPaused,
                    avSyncDriftMs: driftMs,
                    droppedFrames: dropped,
                    pipelineDroppedFrames: pipelineDropped,
                    speedSkippedFrames: speedSkipped,
                    playbackRate: currentRate
                )

                let becameHidden = isMetalLayerVisibleLock.withLock { visible -> Bool in
                    guard visible else { return false }
                    visible = false
                    return true
                }
                if becameHidden {
                    DispatchQueue.main.async { [weak self] in
                        self?.isMetalLayerVisible = false
                    }
                }
            }
        }

        // Single drops stay below FrameQueue's per-tick warning threshold; log them with the link timing that
        // explains them (a vsync interval above the frame duration means the link itself skipped or slowed).
        let newDrops = frameQueue.pipelineDroppedFramesCount - droppedBefore
        if newDrops > 0 {
            let dropsToLog = tickDiagnosticsLock.withLock { state -> Int? in
                state.unloggedDrops += newDrops
                let nowInstant = ContinuousClock.now
                guard nowInstant - state.lastLogInstant >= .seconds(1) else { return nil }
                state.lastLogInstant = nowInstant
                defer { state.unloggedDrops = 0 }
                return state.unloggedDrops
            }
            if let dropsToLog {
                let frameMs = nominalFrameDurationLock.withLock { $0 } * 1000.0
                AppLog.debug(
                    .video,
                    "Pipeline dropped \(dropsToLog) frame(s); last at clock \(String(format: "%.3f", currentSyncTime.seconds))s, vsync interval \(String(format: "%.1f", vsyncIntervalMs))ms, frame \(String(format: "%.1f", frameMs))ms, callback lead \(String(format: "%.1f", (targetTimestamp - now) * 1000.0))ms"
                )
            }
        }

        // Playback-start preroll: the anchor frame is now on screen, so a held clock may start.
        startPendingClockIfPrerolled()

        // Backpressure check: if feeding was paused due to full frame buffer, resume when queue drops to <= 25 frames
        if frameQueue.count <= 25 && isVideoDrainPaused.withLock({ $0 }) {
            checkBackpressureAndResumeIfNeeded()
        }
    }

    public func renderCurrentFrame() {
        renderCurrentFrame(at: nil)
    }

    public func renderCurrentFrame(at explicitTime: CMTime?) {
        let currentSyncTime = explicitTime ?? synchronizer.currentTime()
        let buffer: CVPixelBuffer?
        if currentSyncTime.isValid, let b = frameQueue.getLatestFrame(forSyncTime: currentSyncTime) {
            buffer = b
        } else {
            buffer = frameQueue.getLastRenderedBuffer()
        }

        guard let buffer else { return }
        if activeRenderMode == .metalToneMap {
            metalRenderer?.render(pixelBuffer: buffer)
        } else {
            presentToDisplayLayer(pixelBuffer: buffer)
        }
    }

    /// Resolves and applies dynamic tone-mapping (Dolby Vision L1/L2 trims or static base values) for a
    /// single frame's metadata, updating the Metal uniforms and performance monitor. Returns the resolved
    /// render-mode name. Shared by the playback display-link path and direct (seek/step) renders so
    /// paused frame-stepping over Dolby Vision content keeps reference-accurate tone mapping.
    nonisolated func applyDynamicToneMap(doviMetadata: DolbyVisionFrameMetadata?) -> String {
        struct ResolvedToneMapParams {
            let hasDoViL2Trim: UInt32
            let slope: Float
            let offset: Float
            let power: Float
            let saturation: Float
            let peakNits: Float
            let targetNits: Float
            let modeName: String
        }

        let scale = self.targetNitsScaleLock.withLock { $0 }
        let resolved = dynamicToneMapLock.withLock { state -> ResolvedToneMapParams in
            let effectiveBaseTarget = max(min(state.baseTargetNits * scale, 500.0), 80.0)

            if let dovi = doviMetadata {
                let isSceneRefresh = dovi.sceneRefresh
                let alpha: Float = isSceneRefresh ? 1.0 : 0.15

                if let trim = dovi.sdrTrim {
                    state.lastRenderModeName = "Metal SDR (DoVi L2 Trim)"
                    return ResolvedToneMapParams(
                        hasDoViL2Trim: 1,
                        slope: trim.slope,
                        offset: trim.offset,
                        power: trim.power,
                        saturation: trim.saturationGain,
                        peakNits: state.basePeakNits,
                        targetNits: effectiveBaseTarget,
                        modeName: state.lastRenderModeName
                    )
                } else if let l1 = dovi.l1 {
                    let dynamicPeak = l1.maxNits > 0 ? l1.maxNits : state.basePeakNits
                    let rawTarget = Self.computeAdaptiveTargetNits(
                        baseTargetNits: 203.0,
                        maxPeakNits: dynamicPeak,
                        maxFallNits: l1.avgNits
                    )
                    let scaledTarget = max(min(rawTarget * scale, 500.0), 80.0)

                    state.smoothedPeakNits = (alpha * dynamicPeak) + ((1.0 - alpha) * state.smoothedPeakNits)
                    state.smoothedTargetNits =
                        (alpha * scaledTarget) + ((1.0 - alpha) * state.smoothedTargetNits)
                    state.lastRenderModeName = "Metal SDR (DoVi L1)"

                    return ResolvedToneMapParams(
                        hasDoViL2Trim: 0,
                        slope: 1.0,
                        offset: 0.0,
                        power: 1.0,
                        saturation: 0.0,
                        peakNits: state.smoothedPeakNits,
                        targetNits: state.smoothedTargetNits,
                        modeName: state.lastRenderModeName
                    )
                } else {
                    state.lastRenderModeName = "Metal SDR"
                    return ResolvedToneMapParams(
                        hasDoViL2Trim: 0,
                        slope: 1.0,
                        offset: 0.0,
                        power: 1.0,
                        saturation: 0.0,
                        peakNits: state.basePeakNits,
                        targetNits: effectiveBaseTarget,
                        modeName: state.lastRenderModeName
                    )
                }
            } else {
                // Frame without RPU metadata: cleanly revert to container static base values
                return ResolvedToneMapParams(
                    hasDoViL2Trim: 0,
                    slope: 1.0,
                    offset: 0.0,
                    power: 1.0,
                    saturation: 0.0,
                    peakNits: state.basePeakNits,
                    targetNits: effectiveBaseTarget,
                    modeName: state.lastRenderModeName
                )
            }
        }

        metalRenderer?.updateUniforms { uniforms in
            uniforms.hasDoViL2Trim = resolved.hasDoViL2Trim
            if resolved.hasDoViL2Trim == 1 {
                uniforms.doViTrimSlope = resolved.slope
                uniforms.doViTrimOffset = resolved.offset
                uniforms.doViTrimPower = resolved.power
                uniforms.doViTrimSaturation = resolved.saturation
            }
            uniforms.sourcePeakNits = resolved.peakNits
            uniforms.targetNits = resolved.targetNits
        }
        let currentModeName = resolved.modeName
        let toneMode: PlayerPerformanceMonitor.ToneMapEngineMode
        if resolved.hasDoViL2Trim == 1 {
            toneMode = .doviL2Trim
        } else if currentModeName.contains("DoVi L1") {
            toneMode = .doviL1Auto
        } else if resolved.peakNits > 105.0 {
            toneMode = .bt2390
        } else {
            toneMode = .directSDR
        }

        performanceMonitor.updateToneMapParams(
            PlayerPerformanceMonitor.ToneMapParams(
                mode: toneMode,
                slope: resolved.slope,
                offset: resolved.offset,
                power: resolved.power,
                saturation: resolved.saturation,
                peakNits: resolved.peakNits,
                targetNits: resolved.targetNits
            )
        )
        return currentModeName
    }

    /// Directly renders a decoded pixel buffer onto the active video canvas and updates last rendered state.
    /// `doviMetadata`, when present, drives dynamic tone mapping so direct renders (seek preview, frame
    /// stepping) match the live playback path for Dolby Vision content.
    public func renderDirect(pixelBuffer: CVPixelBuffer, pts: Double, doviMetadata: DolbyVisionFrameMetadata? = nil) {
        frameQueue.setLastRendered(buffer: pixelBuffer, pts: pts)
        if activeRenderMode == .metalToneMap {
            _ = applyDynamicToneMap(doviMetadata: doviMetadata)
            metalRenderer?.render(pixelBuffer: pixelBuffer)
        } else {
            presentToDisplayLayer(pixelBuffer: pixelBuffer)
        }
    }

    /// Completely flushes and clears the video display layer and Metal canvas, removing any lingering video frame.
    public func clearVideoSurface() {
        cachedVideoFormatDescription.withLock { $0 = nil }
        frameQueue.clear(resetDroppedFrames: true)
        flushDisplayLayer(removingDisplayedImage: true)
        metalRenderer?.clear()
    }
}
