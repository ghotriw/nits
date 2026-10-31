@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import QuartzCore
import os

extension PlayerEngine {
    func setupDisplayLink() {
        let target = DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target

        // If a screen is available on initialization, the link follows the main screen until a host is attached.
        if let link = PlatformScreen.makeMainDisplayLink(
            target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        {
            link.add(to: DisplayLinkThread.shared.runLoop, forMode: .default)
            link.isPaused = true
            self.displayLink = link
            updateDisplayLinkFrameRate()
        }
    }

    /// Attaches the engine's CADisplayLink to the view showing the video, and matches the render mode to its screen.
    /// This ensures accurate VBLANK sync across ProMotion (120Hz) displays and seamless multi-monitor transitions.
    public func attachDisplayLink(to host: any VideoHost) {
        self.videoHost = host
        updateHDRDisplay()
        recreateDisplayLink()
    }

    /// The host's screen changed, or that screen's parameters did (display mode, refresh rate, HDR, scale):
    /// re-matches the display-link rate and the render mode to it. `VideoHost`s call it; the engine observes no
    /// screens itself.
    ///
    /// A view's link follows its window to another screen, but not off a screen that is gone (a monitor unplugged):
    /// it stays on that display and stops ticking until it comes back. So a link made for another screen is replaced;
    /// not one for the same screen, whose parameters change many times a second while its EDR headroom ramps.
    public func videoHostScreenDidChange() {
        if videoHost?.screenIdentity != displayLinkScreen {
            recreateDisplayLink()
        } else {
            updateDisplayLinkFrameRate()
        }
        updateHDRDisplay()
    }

    /// EDR headroom above which a screen shows HDR itself; on one at or below it, HDR video is tone-mapped to SDR.
    nonisolated static let minimumHDRDisplayHeadroom: CGFloat = 1.01

    private func updateHDRDisplay() {
        guard let videoHost else { return }
        let isHDR = videoHost.screenEDRHeadroom > Self.minimumHDRDisplayHeadroom
        guard isHDR != isHDRDisplay else { return }
        isHDRDisplay = isHDR
        videoHost.setNeedsVideoLayout(immediately: false)
    }

    /// Replaces the display link with one for the host view, or for its screen while PiP is active: a view-based link
    /// stops when its window is hidden, which PiP usually does.
    func recreateDisplayLink() {
        let target = displayLinkTarget ?? DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target
        let selector = #selector(DisplayLinkTarget.onTick(_:))
        let newLink: CADisplayLink?
        if isPictureInPictureActive {
            newLink =
                videoHost?.makeScreenDisplayLink(target: target, selector: selector)
                ?? PlatformScreen.makeMainDisplayLink(target: target, selector: selector)
        } else {
            newLink = videoHost?.makeDisplayLink(target: target, selector: selector)
        }
        guard let link = newLink else {
            updateDisplayLinkFrameRate()
            return
        }
        displayLink?.invalidate()
        link.add(to: DisplayLinkThread.shared.runLoop, forMode: .default)
        link.isPaused = !isPlaying
        self.displayLink = link
        displayLinkScreen = videoHost?.screenIdentity
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
        let screenMaxRate = videoHost?.maximumFramesPerSecond ?? PlatformScreen.mainMaximumFramesPerSecond ?? 60
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
        guard media.video.isInterlaced, let demuxer else { return }
        decoder.setDeinterlaceMode(deinterlaceMode)
        let contentFrameDuration = demuxer.readingDescription(\.nominalFrameDuration)
        let frameDuration =
            decoder.outputsFieldRate
            ? FieldTiming.fieldDuration(ofFrameDuration: contentFrameDuration) : contentFrameDuration
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
            if media.video.isHDR && !isHDRDisplay && isToneMappingPermitted && !isPictureInPictureActive {
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

        toneMapping.renderModeDidChange(to: newMode)
        if newMode == .system {
            isMetalLayerVisible = false
            if !isPlaying {
                renderCurrentFrame()
            }
        } else {
            if !isPlaying {
                renderCurrentFrame()
                isMetalLayerVisible = true
            }
        }

        if isCollectingMetrics {
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

    /// - Parameters:
    ///   - targetTimestamp: Host time of the vsync at which the frame picked in this tick reaches the screen.
    ///   - tickInterval: The link's vsync spacing, for the cadence statistics.
    nonisolated func displayLinkTick(targetTimestamp: CFTimeInterval, tickInterval: CFTimeInterval) {
        let tickStart = CACurrentMediaTime()
        defer {
            let duration = CACurrentMediaTime() - tickStart
            tickDiagnosticsLock.withLock { $0.sincePop.maxTickDuration = max($0.sincePop.maxTickDuration, duration) }
        }
        pendingClockStartLock.withLock { $0?.displayLinkTicks += 1 }
        alignPendingClockStartWithFirstFrame()
        let clockReadStart = CACurrentMediaTime()
        let clockNow = synchronizer.currentTime()
        guard clockNow.isNumeric else { return }
        let now = CACurrentMediaTime()
        let clockAdvanced = tickDiagnosticsLock.withLock { state -> Bool in
            defer { state.lastClockSeconds = clockNow.seconds }
            return clockNow.seconds != state.lastClockSeconds
        }
        recordTickTiming(tickStart: tickStart, clockRead: now - clockReadStart, clockAdvanced: clockAdvanced)

        // Pick frames for the clock at the target vsync, not at callback time. The callback runs on the main run
        // loop and its latency varies by milliseconds (UI work, cursor moves, ProMotion rate changes); sampling the
        // clock there turns that jitter into skipped frames whenever content fps is close to the link rate
        // (50 fps on 60 Hz tolerates only ~3 ms). Target timestamps are vsync-spaced, so the jitter cancels out.
        // The projection still wobbles by about a millisecond from tick to tick, enough to flip a frame whose boundary
        // sits on a vsync between two ticks; `DisplayClockSmoother` filters that out and keeps boundaries off vsyncs.
        let lookahead = min(max(targetTimestamp - now, 0), Self.maxVsyncLookaheadSeconds)
        // While the synchronizer waits for audio after a start, its clock stands still at a running rate: treat it as
        // stopped, so it is neither projected forward nor smoothed into motion, and the filter starts on the first
        // tick it moves.
        let clockRate = clockAdvanced ? CMTimebaseGetRate(synchronizer.timebase) : 0
        let projectedSyncTime = clockNow + CMTime(seconds: lookahead * clockRate, preferredTimescale: 1_000_000)
        let (pickSeconds, discontinuity) = displayClockSmootherLock.withLock {
            $0.pickTime(rawTime: projectedSyncTime.seconds, hostTime: targetTimestamp, rate: clockRate)
        }
        if let discontinuity {
            AppLog.debug(
                .video,
                "Display clock restarted from the raw clock at \(String(format: "%.3f", projectedSyncTime.seconds))s: \(discontinuity)"
            )
        }
        let currentSyncTime = CMTime(seconds: pickSeconds, preferredTimescale: 1_000_000)

        frameCadenceLock.withLock { $0.recordTick(targetTimestamp: targetTimestamp, tickInterval: tickInterval) }
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
            tickDiagnosticsLock.withLock { $0.sincePop.settlingHoldTicks += 1 }
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
            let renderStart = CACurrentMediaTime()
            if mode == .metalToneMap {
                let toneMapMode = toneMapping.applyFrame(
                    hdrMetadata: popped.hdrMetadata, pixelBuffer: popped.pixelBuffer)
                let cadence = frameCadenceLock
                metalRenderer?.render(pixelBuffer: popped.pixelBuffer, pts: popped.pts.seconds) { gpuEndTime in
                    cadence.withLock {
                        $0.recordGPUCompletion(targetTimestamp: targetTimestamp, gpuEndTime: gpuEndTime)
                    }
                }
                performanceMonitor.recordRenderedFrame(
                    durationMs: durationMs,
                    queueCount: qCount,
                    renderModeName: toneMapMode.name,
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
                toneMapping.trackReshaping(doviMetadata: popped.hdrMetadata?.dolbyVision)
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
            recordFrameCadence(
                popped, syncTime: currentSyncTime, targetTimestamp: targetTimestamp, tickInterval: tickInterval,
                frameDuration: frameDuration, playbackRate: currentRate, clockRunning: clockRate != 0,
                renderCall: CACurrentMediaTime() - renderStart)
            recordPopTiming(
                pts: popped.pts, targetTimestamp: targetTimestamp, tickInterval: tickInterval,
                frameDuration: frameDuration, playbackRate: currentRate, clockSeconds: currentSyncTime.seconds)
        } else if frameQueue.count == 0 {
            tickDiagnosticsLock.withLock { $0.sincePop.emptyQueueTicks += 1 }
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

    /// Notes when this tick's callback ran and how long reading the synchronizer clock took.
    private nonisolated func recordTickTiming(tickStart: CFTimeInterval, clockRead: CFTimeInterval, clockAdvanced: Bool)
    {
        tickDiagnosticsLock.withLock { state in
            let gap = state.lastCallbackHost > 0 ? tickStart - state.lastCallbackHost : 0
            state.lastCallbackHost = tickStart
            // A link paused for longer than any stall (playback paused, window hidden) starts over.
            if gap > 1 {
                state.lastPopTarget = 0
                state.sincePop = TicksSincePop()
            }
            state.sincePop.ticks += 1
            state.sincePop.maxCallbackGap = max(state.sincePop.maxCallbackGap, gap)
            state.sincePop.maxClockRead = max(state.sincePop.maxClockRead, clockRead)
            if !clockAdvanced { state.sincePop.stoppedClockTicks += 1 }
        }
    }

    /// Logs what the link did since the previous frame when this one came two ticks or more past its cadence.
    private nonisolated func recordPopTiming(
        pts: CMTime, targetTimestamp: CFTimeInterval, tickInterval: CFTimeInterval, frameDuration: Double,
        playbackRate: Double, clockSeconds: Double
    ) {
        let (hold, sample) = tickDiagnosticsLock.withLock { state -> (CFTimeInterval, TicksSincePop) in
            defer {
                state.lastPopTarget = targetTimestamp
                state.sincePop = TicksSincePop()
            }
            return (state.lastPopTarget > 0 ? targetTimestamp - state.lastPopTarget : 0, state.sincePop)
        }
        guard tickInterval > 0, playbackRate > 0 else { return }
        let cadenceTicks = (frameDuration / (tickInterval * playbackRate)).rounded(.up)
        // A clock that stood still (start waiting for audio, pause) holds the frame by design, not by a stall.
        guard hold >= (cadenceTicks + 2) * tickInterval, sample.stoppedClockTicks == 0 else { return }
        func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
        AppLog.debug(
            .video,
            "Frame held \(ms(hold)) ms (\(Int((hold / tickInterval).rounded())) ticks, cadence \(Int(cadenceTicks))) before PTS \(String(format: "%.3f", pts.seconds))s at clock \(String(format: "%.3f", clockSeconds))s: \(sample.ticks) callbacks, max gap \(ms(sample.maxCallbackGap)) ms; clock stopped in \(sample.stoppedClockTicks), queue empty in \(sample.emptyQueueTicks), settling hold in \(sample.settlingHoldTicks); max tick \(ms(sample.maxTickDuration)) ms, max clock read \(ms(sample.maxClockRead)) ms; queue now \(frameQueue.count)"
        )
    }

    private nonisolated func recordFrameCadence(
        _ frame: FrameQueue.PoppedFrame, syncTime: CMTime, targetTimestamp: CFTimeInterval,
        tickInterval: CFTimeInterval, frameDuration: Double, playbackRate: Double, clockRunning: Bool,
        renderCall: CFTimeInterval
    ) {
        guard frame.pts.isNumeric, syncTime.isNumeric else { return }
        let slack =
            syncTime.seconds + FrameQueue.leadWindowSeconds(nominalFrameDuration: frameDuration) - frame.pts.seconds
        // The anchor frame of a start goes up before the clock runs: its slack says nothing about the cadence phase.
        if clockRunning {
            displayClockSmootherLock.withLock {
                $0.recordPick(
                    slack: slack, tickInterval: tickInterval, frameDuration: frameDuration, playbackRate: playbackRate)
            }
        }
        let report = frameCadenceLock.withLock {
            $0.recordFrame(
                targetTimestamp: targetTimestamp, tickInterval: tickInterval, pts: frame.pts.seconds, slack: slack,
                frameDuration: frameDuration, playbackRate: playbackRate, renderCall: renderCall)
        }
        if let report {
            AppLog.debug(.video, report)
        }
    }

    public func renderCurrentFrame() {
        renderCurrentFrame(at: nil)
    }

    public func renderCurrentFrame(at explicitTime: CMTime?) {
        let currentSyncTime = explicitTime ?? synchronizer.currentTime()
        if currentSyncTime.isValid {
            // Makes the frame at the clock the last rendered one, with its RPU.
            _ = frameQueue.getLatestFrame(forSyncTime: currentSyncTime)
        }
        guard let frame = frameQueue.getLastRenderedFrame() else { return }
        if activeRenderMode == .metalToneMap {
            // The frame's own curve, from its L1 as is: tone mapping may have last resolved another frame's (under
            // `.system` none), so there is no playback to smooth from.
            _ = toneMapping.applyFrame(
                hdrMetadata: frame.hdrMetadata, pixelBuffer: frame.pixelBuffer, restartsSmoothing: true)
            metalRenderer?.render(pixelBuffer: frame.pixelBuffer, pts: frame.pts)
        } else {
            toneMapping.trackReshaping(doviMetadata: frame.hdrMetadata?.dolbyVision)
            presentToDisplayLayer(pixelBuffer: frame.pixelBuffer)
        }
    }

    /// Gives the display layer the current frame before Picture in Picture starts. Under Metal tone mapping the
    /// (hidden) display layer gets no frames, and AVKit lays out its panel from the layer's video size right at
    /// `willStart`, before the switch to `.system` delivers one: with no frame ever enqueued that size is zero and
    /// AVKit crashes on a NaN view frame. The layer stays hidden until the render mode switches.
    public func primeDisplayLayerForPictureInPicture() {
        guard activeRenderMode == .metalToneMap, let buffer = frameQueue.getLastRenderedBuffer() else { return }
        presentToDisplayLayer(pixelBuffer: buffer)
    }

    /// Directly renders a decoded pixel buffer onto the active video canvas and updates last rendered state.
    /// `hdrMetadata`, when present, drives dynamic tone mapping so direct renders (seek preview, frame
    /// stepping) match the live playback path for Dolby Vision content. `restartsSmoothing` takes the frame's L1 as
    /// is: for a frame with no playback before it to smooth from (a seek's), which would otherwise be drawn with
    /// mostly the curve of where the seek came from.
    public func renderDirect(
        pixelBuffer: CVPixelBuffer, pts: Double, hdrMetadata: FrameHDRMetadata? = nil,
        restartsSmoothing: Bool = false
    ) {
        frameQueue.setLastRendered(buffer: pixelBuffer, pts: pts, hdrMetadata: hdrMetadata)
        if activeRenderMode == .metalToneMap {
            _ = toneMapping.applyFrame(
                hdrMetadata: hdrMetadata, pixelBuffer: pixelBuffer, restartsSmoothing: restartsSmoothing)
            metalRenderer?.render(pixelBuffer: pixelBuffer, pts: pts)
        } else {
            toneMapping.trackReshaping(doviMetadata: hdrMetadata?.dolbyVision)
            presentToDisplayLayer(pixelBuffer: pixelBuffer)
        }
    }

    /// The frame on screen as a still, as the active render mode shows it, with the on-screen crop, aspect ratio
    /// and zoom at the source's resolution (see `FrameCapture`). Nil without a frame.
    public func captureFrame() async -> CapturedFrame? {
        guard let frame = frameQueue.getLastRenderedFrame() else { return nil }
        let mode = activeRenderMode
        let renderer = metalRenderer
        // Under Metal, the frame as the layer was given it, in one step: the display link may draw the next frame, or
        // its curve, while this reads.
        let drawn = mode == .metalToneMap ? renderer?.lastDrawnFrame : nil
        nonisolated(unsafe) let pixelBuffer = drawn?.pixelBuffer ?? frame.pixelBuffer
        let pts = drawn?.pts ?? frame.pts
        let sourceRect = drawn?.sourceRect ?? renderer?.sourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let displaySize = drawn?.drawableSize ?? renderer?.metalLayer.drawableSize ?? .zero
        let uniforms = drawn?.uniforms
        // A drawn frame carries its reshaping in its uniforms.
        let reshaping = drawn == nil ? toneMapping.stillReshaping(doviMetadata: frame.hdrMetadata?.dolbyVision) : nil
        return await Task.detached(priority: .userInitiated) {
            FrameCapture.capture(
                pixelBuffer, pts: pts, mode: mode, renderer: renderer, sourceRect: sourceRect,
                displaySize: displaySize, uniforms: uniforms, dolbyVisionReshaping: reshaping)
        }.value
    }

    /// Completely flushes and clears the video display layer and Metal canvas, removing any lingering video frame.
    public func clearVideoSurface() {
        cachedVideoFormatDescription.withLock { $0 = nil }
        frameQueue.clear(resetDroppedFrames: true)
        flushDisplayLayer(removingDisplayedImage: true)
        metalRenderer?.clear()
    }
}

extension PlayerEngine: ToneMapHost {}
