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
            let baseMode: PlayerPerformanceMonitor.ToneMapEngineMode = dynamicToneMapLock.withLock { state in
                if state.lastRenderModeName.contains("DoVi L2") {
                    return .doviL2Trim
                } else if state.lastRenderModeName.contains("DoVi L1") {
                    return .doviL1Auto
                } else if state.basePeakNits > 105.0 {
                    return .bt2390
                } else {
                    return .directSDR
                }
            }
            let (peak, target) = dynamicToneMapLock.withLock { ($0.basePeakNits, $0.baseTargetNits) }
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
        var formatDescription: CMVideoFormatDescription?
        let err = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard err == noErr, let formatDesc = formatDescription else { return }

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

        _ = sampleBufferRenderer.perform(Self.enqueueSampleBufferSelector, with: sample)
    }

    nonisolated func displayLinkTick() {
        let currentSyncTime = synchronizer.currentTime()
        guard currentSyncTime.isValid else { return }

        let start = CACurrentMediaTime()
        if let popped = frameQueue.popFrame(forSyncTime: currentSyncTime) {
            let durationMs = (CACurrentMediaTime() - start) * 1000.0
            let qCount = frameQueue.count
            let isPaused = isVideoDrainPaused.withLock { $0 }
            let driftMs = popped.pts.isValid ? (popped.pts.seconds - currentSyncTime.seconds) * 1000.0 : 0.0
            let dropped = frameQueue.droppedFramesCount

            let mode = activeRenderMode
            if mode == .metalToneMap {
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

                let resolved = dynamicToneMapLock.withLock { state -> ResolvedToneMapParams in
                    let scale = self.targetNitsScaleLock.withLock { $0 }
                    let effectiveBaseTarget = max(min(state.baseTargetNits * scale, 500.0), 80.0)

                    if let dovi = popped.doviMetadata {
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

                metalRenderer?.render(pixelBuffer: popped.pixelBuffer)
                performanceMonitor.recordRenderedFrame(
                    durationMs: durationMs,
                    queueCount: qCount,
                    renderModeName: currentModeName,
                    isDrainPaused: isPaused,
                    avSyncDriftMs: driftMs,
                    droppedFrames: dropped
                )

                if !isMetalLayerVisibleLock.withLock({ $0 }) {
                    isMetalLayerVisibleLock.withLock { $0 = true }
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
                    droppedFrames: dropped
                )

                if isMetalLayerVisibleLock.withLock({ $0 }) {
                    isMetalLayerVisibleLock.withLock { $0 = false }
                    DispatchQueue.main.async { [weak self] in
                        self?.isMetalLayerVisible = false
                    }
                }
            }
        }

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

    /// Directly renders a decoded pixel buffer onto the active video canvas and updates last rendered state.
    public func renderDirect(pixelBuffer: CVPixelBuffer, pts: Double) {
        frameQueue.setLastRendered(buffer: pixelBuffer, pts: pts)
        if activeRenderMode == .metalToneMap {
            metalRenderer?.render(pixelBuffer: pixelBuffer)
        } else {
            presentToDisplayLayer(pixelBuffer: pixelBuffer)
        }
    }

    /// Completely flushes and clears the video display layer and Metal canvas, removing any lingering video frame.
    public func clearVideoSurface() {
        frameQueue.clear(resetDroppedFrames: true)
        Self.flushRemovingDisplayedImage(sampleBufferRenderer)
        metalRenderer?.clear()
    }
}
