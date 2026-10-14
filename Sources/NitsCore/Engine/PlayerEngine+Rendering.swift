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
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            self.displayLink = link
        }
    }

    /// Attaches the engine's CADisplayLink to the video rendering host view.
    /// This ensures accurate VBLANK sync across ProMotion (120Hz) displays and seamless multi-monitor transitions.
    public func attachDisplayLink(to view: NSView) {
        displayLink?.invalidate()
        let target = displayLinkTarget ?? DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target

        let link = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = !isPlaying
        self.displayLink = link
    }

    func updateEffectiveRenderMode() {
        let newMode: RenderMode
        switch renderMode {
        case .auto:
            // Metal tone mapping is ONLY needed when video content is HDR and display is SDR
            if isHDRContent && !isHDRDisplay && isToneMappingPermitted {
                newMode = .metalToneMap
            } else {
                newMode = .system
            }
        case .system:
            newMode = .system
        case .metalToneMap:
            newMode = isToneMappingPermitted ? .metalToneMap : .system
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
        let formatDesc: CMVideoFormatDescription? = cachedVideoFormatDescription.withLock { cached in
            if let cached, CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pb) {
                return cached
            }
            var newDesc: CMVideoFormatDescription?
            let err = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                formatDescriptionOut: &newDesc
            )
            if err == noErr, let newDesc {
                cached = newDesc
                return newDesc
            }
            return nil
        }
        guard let formatDesc else { return }

        let timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: [timing],
            sampleBufferOut: &sampleBuffer
        )
        guard let sample = sampleBuffer else { return }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary],
            let dic = attachmentsArray.first
        {
            dic[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        enqueueToDisplayLayer(sample)
    }

    /// - Parameter targetTimestamp: Host time of the vsync at which the frame picked in this tick reaches the screen.
    nonisolated func displayLinkTick(targetTimestamp: CFTimeInterval) {
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
        Self.flushRemovingDisplayedImage(sampleBufferRenderer)
        metalRenderer?.clear()
    }
}
