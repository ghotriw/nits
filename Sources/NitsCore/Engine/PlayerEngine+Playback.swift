@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

extension PlayerEngine {
    public func play() {
        audioInterruption.userChangedPlayback()
        resetRelativeSeekBurst()
        guard isLoaded else { return }

        // Any start in the background is audio only (Play from the lock screen, the end of an interruption): the picture
        // is not played there, and media without sound has nothing to play.
        if isHostInBackground {
            guard hasAudioStream else { return }
            dropPictureForBackground()
        }

        // If video reached the end or is in completed state, restart from the beginning
        if playbackState == .completed || isAtEndOfMedia(currentTime) {
            seek(to: 0.0)
        }

        // After frame-stepping the demuxer/decoder sit ahead of the cursor and audio before the seek
        // baseline was purged, so resuming feeding as-is would freeze video and drop/desync audio. Reseek
        // to currentTime first; the chase-settle machinery then resumes playback cleanly at the cursor.
        if hasPicture, !isSeeking, chase == nil, frameStep.didStepSincePause {
            frameStep.didStepSincePause = false
            seek(to: currentTime)
        }

        // If a chase seek is currently in flight or queued, record intent to play once seeking finishes
        if isSeeking || chase != nil {
            resumePlaybackAfterChase = true
            return
        }

        // Already playing, or prerolling towards it: restarting would re-anchor the clock to the last periodic time
        // update (up to 50 ms back) and, aligned with buffered audio, hold it for an output latency — a stutter.
        if isPlaying { return }

        // Paused at a live edge and resumed behind it: the speed from before the edge, as after a seek back.
        live.resumed(at: currentTime)

        // The load's start still runs on `seekQueue` (`isLoadStartPending`): the feeders would read from before its
        // start position. Playing from now on, as after a start right away; the start, once in, starts the pipeline.
        if isLoadStartPending {
            beginAudioOutputActivation()
            isPlaying = true
            playbackState = .playing
            return
        }

        // A seek moved the position and no join has brought the audio since (a seek on pause, or one the user paused
        // during): playing on is a join of the audio to the picture's clock, as after a seek that resumes.
        // Before any decision about the clock: its start waits for the output, which this asks for.
        beginAudioOutputActivation()
        let joinsAudio = audioJoin.isRendererStale && hasAudioStream
        let feedingActive = isFeeding.withLock { $0 }
        if !feedingActive {
            startFeeding(audio: !joinsAudio)
        }
        let targetTime = resolvePlaybackStartTime(syncTime: playbackClock.currentTime())
        if joinsAudio {
            if hasPicture {
                startSynchronizerClockAfterPreroll(at: targetTime, isProvisional: true)
            } else {
                cancelPreroll()
                playbackClock.setRate(0.0, time: targetTime)
            }
            audioJoin.begin(on: self, from: targetTime, hasPicture: hasPicture)
        } else {
            // Resuming from pause: the audio renderer still holds the paused media.
            startSynchronizerClockAfterPreroll(at: targetTime, alignWithBufferedAudio: true)
        }
        displayLink?.isPaused = !hasPicture
        isPlaying = true
        playbackState = .playing
        performanceMonitor.handlePlaybackStateChange(isPlaying: true)
    }

    public func pause() {
        audioInterruption.userChangedPlayback()
        resetRelativeSeekBurst()
        if isSeeking || chase != nil {
            resumePlaybackAfterChase = false
        }
        stopPlaybackPipeline()
        playbackState = .paused
        saveCurrentPlaybackProgress()
    }

    /// The host went to the background (iOS: the scene did). Drops the display links, which only tick for a screen on
    /// show, and the decoder's VideoToolbox session, which the system invalidates behind the app's back (the session of a
    /// hardware decoder then fails every frame, and the picture would stand while the sound plays on).
    ///
    /// What plays with sound plays on as audio only (`dropPictureForBackground`): no video is fed, decoded or queued
    /// until the host is back. Media without sound, and a seek in flight, are paused, which they stay after coming
    /// back. The position is kept for `hostWillEnterForeground`. Calling it again changes nothing.
    ///
    /// A load under way goes on, and its end decides (`PlayerEngine+Loading`): with sound it plays on as audio only,
    /// without it ends paused on its first frame.
    public func hostDidEnterBackground() {
        guard !isHostInBackground else { return }
        isHostInBackground = true
        displayLink?.invalidate()
        displayLink = nil
        displayLinkScreen = nil
        if isLoading || !isLoaded {
            AppLog.info(.engine, "Host in the background while loading; the load will decide how it ends")
            return
        }
        let position = rereadPosition
        backgroundSnapshot = BackgroundSnapshot(
            position: position, atLiveEdge: live.isLive && live.isAtEdge(position))
        guard hasAudioStream, !isSeeking, chase == nil else {
            pause()
            resetDecoderSession(because: "entering the background")
            AppLog.info(.engine, "Host in the background at \(String(format: "%.3f", position))s; paused")
            return
        }
        dropPictureForBackground()
        AppLog.info(
            .engine,
            "Host in the background at \(String(format: "%.3f", position))s; "
                + (isPlaying ? "the audio plays on" : "paused"))
    }

    /// The picture is not played in the background: the video feeder stops, the frame queue is emptied, the decoder's
    /// session dropped and the demuxer told to keep video packets out of its queue (`setPictureDropped`), so that the
    /// audio goes on alone (see `MediaDemuxer.setVideoDropped`). The decode the feeder may be in finishes first, as a
    /// seek waits for it: its frame would otherwise land in a queue already emptied. Does nothing for media without
    /// a picture, or when it is dropped already.
    func dropPictureForBackground() {
        guard media.hasVideo, !backgroundPlayback.isVideoDropped else { return }
        let unwinding = videoFeedingTask
        stopFeedingVideo()
        setPictureDropped(true)
        frameQueue.clear(resetDroppedFrames: true)
        let guarded = stallGuardedDecoder(for: "the session reset on entering the background")
        let frames = frameQueue
        seekQueue.async {
            if let unwinding { Self.waitForUnwind(of: unwinding) }
            frames.clear(resetDroppedFrames: true)
            guarded.resetSession()
        }
    }

    /// The host is back in the foreground: the display link is made again, the VideoToolbox session is dropped again
    /// (the engine may have decoded in the background, before the app was suspended, and the system killed that session
    /// too), and the picture comes back with an exact seek to where it stood, which also reads the network again (its
    /// connections died while suspended). Stays paused. A live stream at its edge returns to its edge, one behind it
    /// to where it was, as far as its window still goes (the seek's own clamp).
    public func hostWillEnterForeground() {
        guard isHostInBackground else { return }
        isHostInBackground = false
        // The picture first: the demuxer queues video again (its cache is outdated until the seek below reads the input),
        // and the seek is a picture's.
        let wasAudioOnly = backgroundPlayback.isVideoDropped
        if wasAudioOnly { setPictureDropped(false) }
        if let videoHost {
            attachDisplayLink(to: videoHost)
        } else {
            setupDisplayLink()
        }
        videoHostScreenDidChange()
        // Before the seek, on the same serial queue: its flush finds the session gone, not a dead one.
        resetDecoderSession(because: "coming back")
        recoverDisplayLayerOnReturn()
        guard isLoaded, !isLoading else { return }
        // Nothing was dropped and it plays on (audio-only media): the clock and the audio never left each other, and a
        // seek would only flush the renderer.
        if isPlaying, !wasAudioOnly {
            backgroundSnapshot = nil
            AppLog.info(.engine, "Host back in the foreground; playing on, nothing to bring back")
            return
        }
        // From what stands now, not from what stood on the way out: the sound played on (the clock's position), or was
        // moved (a seek, the end of the media, an item loaded in the background: `currentTime`). A picture that was not
        // dropped (media without sound, paused on the way out) is where it was.
        let snapshot = backgroundSnapshot ?? BackgroundSnapshot(position: rereadPosition, atLiveEdge: false)
        backgroundSnapshot = nil
        let (position, toLiveEdge) = Self.returnTarget(
            isPlaying: isPlaying, clock: playbackClock.currentTime().seconds, wasAudioOnly: wasAudioOnly,
            seekTarget: chase?.seconds, currentTime: currentTime, snapshot: snapshot, isLive: live.isLive)
        if toLiveEdge {
            seekToLiveEdge()
        } else {
            // Playing, the seek resumes it (stage 1: the audio renderer is flushed, a click is accepted).
            seek(to: position, exact: true)
        }
        AppLog.info(
            .engine,
            "Host back in the foreground; seeking to \(String(format: "%.3f", position))s"
                + (isPlaying ? " and playing on" : ""))
    }

    /// Where the picture comes back to, from what stands now (not from what stood on the way out): playing, where the
    /// sound is (`clock`); paused after the sound's position moved in the background (a seek, the end of the media, an
    /// item loaded there: `seekTarget` / `currentTime`), there; and a picture that was never dropped (media without
    /// sound), where it stood. A live stream that was at its edge and has not moved returns to the edge, as it is then.
    nonisolated static func returnTarget(
        isPlaying: Bool, clock: Double, wasAudioOnly: Bool, seekTarget: Double?, currentTime: Double,
        snapshot: BackgroundSnapshot, isLive: Bool
    ) -> (position: Double, toLiveEdge: Bool) {
        if isPlaying { return (clock, false) }
        let position = wasAudioOnly ? (seekTarget ?? currentTime) : snapshot.position
        let isUnmoved = abs(position - snapshot.position) < 1
        return (position, isLive && snapshot.atLiveEdge && isUnmoved)
    }

    /// Whether the display layer has to be flushed before it takes frames again: it was told to stop using decoder resources
    /// (`requiresFlushToResumeDecoding`, with the status `.failed`), as the system does to an app that has been in the
    /// background for a while (not after 5 s, after 20 s).
    nonisolated static func displayLayerNeedsFlush(
        status: AVQueuedSampleBufferRenderingStatus, requiresFlush: Bool
    ) -> Bool {
        requiresFlush || status == .failed
    }

    /// On coming back: the layer's state is logged, and a layer that stopped taking frames is flushed, keeping its image, so
    /// that the seek that follows shows the picture again (enqueued to a layer that requires a flush, frames are dropped
    /// silently and the picture stays blank until a flush).
    private func recoverDisplayLayerOnReturn() {
        let renderer = sampleBufferRenderer
        let status = renderer.status
        let requiresFlush = renderer.requiresFlushToResumeDecoding
        let error = renderer.error.map { "\($0)" } ?? "none"
        let needsFlush = Self.displayLayerNeedsFlush(status: status, requiresFlush: requiresFlush)
        AppLog.info(
            .video,
            "Display layer on coming back: status \(status.rawValue), error \(error), requires flush \(requiresFlush)"
                + (needsFlush ? "; flushing it" : ""))
        if needsFlush { flushDisplayLayer(removingDisplayedImage: false) }
    }

    /// Drops the decoder's session on `seekQueue`, behind a seek or load start in flight and ahead of what follows,
    /// through the guard: a VideoToolbox call can block forever. The session waits for its frames and invalidates; the
    /// next decode makes a fresh one.
    private func resetDecoderSession(because reason: String) {
        let guarded = stallGuardedDecoder(for: "the session reset on \(reason)")
        seekQueue.async { guarded.resetSession() }
    }

    /// Halts clock synchronization and feeders without altering user-facing isPlaying or playbackState.
    func haltPlaybackPipeline() {
        cancelPreroll()
        playbackClock.setRate(0.0, time: playbackClock.currentTime())
        displayLink?.isPaused = true
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        // A seek that has decoded its target and only waits to resume (its end-of-media wait, or scrubbing) settles here,
        // at its target; left pending, it would keep reporting a seek and make `play()` wait for it.
        if !isSeeking, let settledSeconds = chase?.seconds {
            chase = nil
            playbackClock.setRate(0.0, time: CMTime(seconds: settledSeconds, preferredTimescale: 1000))
        }
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
    }

    /// Stops audio/video feeding and halts the clock, marking playback as paused.
    func stopPlaybackPipeline() {
        haltPlaybackPipeline()
        isPlaying = false
        performanceMonitor.handlePlaybackStateChange(isPlaying: false)
    }

    /// Resolves the master clock timeline starting position when entering play mode.
    ///
    /// If CoreAudio synchronizer reports a valid non-zero time that matches the engine's `currentTime`
    /// within 500ms (e.g. unpausing), we retain the hardware clock.
    /// Otherwise (e.g. initial track start or post-reload before hardware clock resets),
    /// we re-anchor to `currentTime` to prevent running on a stale clock from previous media.
    private func resolvePlaybackStartTime(syncTime: CMTime) -> CMTime {
        if syncTime.isNumeric && syncTime.seconds > 0 && abs(syncTime.seconds - currentTime) < 0.5 {
            return syncTime
        }
        return CMTime(seconds: currentTime, preferredTimescale: 60000)
    }

    /// Safely starts or re-anchors the synchronizer master clock.
    ///
    /// - Parameters:
    ///   - targetTime: Target timeline position for CoreAudio synchronizer.
    ///   - rate: Target playback rate.
    ///   - startDelay: If positive, `targetTime` is pinned to `now + startDelay` host time instead of letting the
    ///     synchronizer pick the start (see `play()`).
    ///   - keepsRunning: The call gives the running clock a new rate where it stands (see `PlaybackClock.setRate`).
    nonisolated func startSynchronizerClock(
        at targetTime: CMTime, rate: Double, startDelay: TimeInterval = 0, keepsRunning: Bool = false,
        isProvisional: Bool = false
    ) {
        // The clock runs on host time alone until the audio joins it (`AudioJoin`); the audio device is not running yet.
        if isProvisional && rate > 0 {
            playbackClock.startProvisional(at: targetTime, rate: Float(rate))
            return
        }
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        if rate > 0 {
            audioOutputInterruptionLock.withLock { $0.clockStarted(at: .now) }
        }
        if startDelay > 0 && rate > 0 {
            let hostTime = hostNow + CMTime(seconds: startDelay, preferredTimescale: 1_000_000_000)
            playbackClock.setRate(Float(rate), time: targetTime, atHostTime: hostTime, keepsRunning: keepsRunning)
        } else {
            playbackClock.setRate(Float(rate), time: targetTime, keepsRunning: keepsRunning)
        }
    }

    // MARK: - Playback Start Preroll

    /// Decoded frames that must be queued behind the presented anchor frame before the clock starts,
    /// as in KSPlayer (`frameCount >= 2`) and mpv (`handle_playback_restart` waits for video READY).
    nonisolated static let prerollMinimumQueuedFrames = 1
    /// Safety net only: the clock normally starts from the display-link tick. This bounds the wait when the
    /// decoder stalls or the display link does not tick (occluded window).
    static let prerollTimeout: Duration = .seconds(1)
    /// Cap for the resume start delay, so a bogus device latency (or a Bluetooth route reporting a huge one)
    /// cannot noticeably postpone playback.
    static let maxOutputLatencyAlignment: TimeInterval = 0.25

    var isPrerolling: Bool {
        pendingClockStartLock.withLock { $0 != nil }
    }

    func updateAwaitingClockStart() {
        let awaiting = chase != nil || isPrerolling
        if isAwaitingClockStart != awaiting {
            isAwaitingClockStart = awaiting
        }
    }

    /// Starts the master clock at `targetTime` once video has prerolled.
    ///
    /// Starting the clock right after `startFeeding()` lets it run while the first (slow, e.g. 4K Dolby Vision)
    /// frame is still decoding, so the display link later finds the leading frames already late and drops them
    /// in a burst. Instead the clock is anchored at `targetTime` with rate 0 — the display link still pops and
    /// shows the first frame — and the display-link tick itself starts it (`startPendingClockIfPrerolled`) once
    /// that frame is on screen and `prerollMinimumQueuedFrames` more are decoded. Waiting for the presentation,
    /// not just for decoded frames, keeps a late first tick from skipping the anchor frame. Audio needs no
    /// explicit wait: with media enqueued, the synchronizer holds the clock until the audio device is running.
    ///
    /// The pending start is cancelled by `haltPlaybackPipeline()`, seeks and media reloads.
    ///
    /// - Parameter alignWithBufferedAudio: The audio renderer still holds media from before a pause. Started
    ///   "as soon as possible", the synchronizer then discards what was in the device's output buffer and leaps the
    ///   clock ahead by the output latency (~15–20 ms on built-in speakers), skipping that much audio and a video
    ///   frame. Scheduling the start one output latency ahead lets the first sample at `targetTime` become audible
    ///   exactly when the clock reaches it.
    ///
    /// - Parameter isProvisional: The clock runs on host time alone (`PlaybackClock.startProvisional`) once the anchor
    ///   frame is up; the caller joins the audio to it (`AudioJoin`), which the synchronizer then takes over.
    func startSynchronizerClockAfterPreroll(
        at targetTime: CMTime, alignWithBufferedAudio: Bool = false, isProvisional: Bool = false
    ) {
        cancelPreroll()
        // Nothing presents video without a display link, so there is no anchor frame to protect. And the clock does not
        // start before the audio output is ready (the session is active): audio queued for a clock that runs ahead of
        // the output is dropped as late.
        let isOutputReady = isAudioOutputReady.withLock { $0 }
        let isReady = isOutputReady && isPrerollSatisfied
        // Refused only for the output: its completion starts the clock (`audioOutputBecameReady`).
        if !isOutputReady && isPrerollSatisfied { isClockWaitingForOutput.withLock { $0 = true } }
        let startDelay =
            alignWithBufferedAudio
            ? min(PlatformAudioOutputRoute.currentOutputLatency() ?? 0, Self.maxOutputLatencyAlignment) : 0
        if isReady {
            if startDelay > 0 {
                AppLog.debug(
                    .engine,
                    "Aligning clock start with buffered audio: +\(String(format: "%.1f", startDelay * 1000.0))ms output latency"
                )
            }
            startSynchronizerClock(
                at: targetTime, rate: playbackRate, startDelay: startDelay, isProvisional: isProvisional)
            return
        }

        playbackClock.setRate(0.0, time: targetTime)
        var request = PendingClockStart(
            targetTime: targetTime, rate: playbackRate, requestHostTime: CACurrentMediaTime())
        request.startDelay = startDelay
        request.isProvisional = isProvisional
        let pending = request
        pendingClockStartLock.withLock { $0 = pending }
        updateAwaitingClockStart()
        prerollTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.prerollTimeout)
            guard !Task.isCancelled, let self else { return }
            self.prerollTimeoutTask = nil
            // The output is not ready either (the session is being activated): its completion starts the clock.
            guard self.isAudioOutputReady.withLock({ $0 }) else {
                self.isClockWaitingForOutput.withLock { $0 = true }
                return
            }
            guard
                let pending = self.pendingClockStartLock.withLock({ state in
                    defer { state = nil }
                    return state
                })
            else { return }
            self.updateAwaitingClockStart()
            AppLog.warning(
                .engine,
                "Preroll timed out after \(Self.prerollTimeout); starting clock anyway. \(self.prerollDiagnostics(pending))"
            )
            self.startSynchronizerClock(
                at: pending.targetTime, rate: pending.rate, startDelay: pending.startDelay,
                isProvisional: pending.isProvisional)
        }
    }

    /// The preroll has what it waits for: no picture to anchor (audio only, no display link, the picture's input at its
    /// end), or the anchor frame shown with frames queued behind it.
    var isPrerollSatisfied: Bool {
        !hasPicture || displayLink == nil || (inputs?.isVideoEOF ?? true)
            || (frameQueue.getLastRenderedPTS() >= 0 && frameQueue.count >= Self.prerollMinimumQueuedFrames)
    }

    /// Asks the route for the output as playback starts; the clock waits for it (`isAudioOutputReady`). The route does not
    /// block this thread and calls back once the session is active, where a clock start that only waited for that goes on.
    /// Starts the output's activation as playback starts, before anything decides about the clock: `isAudioOutputReady` is
    /// then false until the route answers, whatever it was at the end of the last run. Not while already playing (the
    /// output was asked for as that began); every path that sets `isPlaying` to true calls it first.
    func beginAudioOutputActivation() {
        guard !isPlaying else { return }
        activateAudioOutput()
    }

    func activateAudioOutput() {
        isAudioOutputReady.withLock { $0 = false }
        audioOutputRoute.activate { [weak self] in self?.audioOutputBecameReady() }
    }

    func audioOutputBecameReady() {
        isAudioOutputReady.withLock { $0 = true }
        // Only a clock start that was refused for the output goes on from here; where the output is ready at once (macOS)
        // nothing was refused, and the start stays with the preroll and the display-link tick, as before.
        let wasWaiting = isClockWaitingForOutput.withLock { waiting -> Bool in
            defer { waiting = false }
            return waiting
        }
        if wasWaiting { claimAndStartPendingClock() }
    }

    /// Called from the display-link tick after presentation: starts a pending clock exactly once when the
    /// anchor frame is on screen and the next frames are decoded.
    nonisolated func startPendingClockIfPrerolled() {
        guard pendingClockStartLock.withLock({ $0 != nil }),
            frameQueue.getLastRenderedPTS() >= 0,
            frameQueue.count >= Self.prerollMinimumQueuedFrames
        else { return }
        // Prerolled, but the output is not ready (the session is being activated): its completion starts the clock.
        guard isAudioOutputReady.withLock({ $0 }) else {
            isClockWaitingForOutput.withLock { $0 = true }
            return
        }
        claimAndStartPendingClock()
    }

    /// Starts the pending clock, if one is still pending, exactly once.
    nonisolated func claimAndStartPendingClock() {
        guard
            let pending = pendingClockStartLock.withLock({ state -> PendingClockStart? in
                guard let claimed = state else { return nil }
                state = nil
                return claimed
            })
        else { return }

        startSynchronizerClock(
            at: pending.targetTime, rate: pending.rate, startDelay: pending.startDelay,
            isProvisional: pending.isProvisional)
        DispatchQueue.main.async { [weak self] in self?.updateAwaitingClockStart() }
        let elapsedMs = (CACurrentMediaTime() - pending.requestHostTime) * 1000.0
        AppLog.debug(
            .engine,
            "Preroll complete in \(String(format: "%.1f", elapsedMs))ms (queued frames: \(frameQueue.count)); starting clock at \(String(format: "%.3f", pending.targetTime.seconds))s"
        )
    }

    /// Moves a held preroll clock forward to the first queued frame when that frame lies just past the anchor.
    ///
    /// A start position between two frames (resume positions are arbitrary) has the demuxer flag the frame before
    /// it as not displayable, so the first queued frame can be up to a frame past the anchor: beyond the half-frame
    /// lead window in which `popFrame` takes it for a clock that is not moving. The anchor frame would never be
    /// presented and the preroll would wait for its timeout. Starting a fraction of a frame later costs nothing
    /// audible; a larger gap is left alone rather than skipping media.
    ///
    /// An anchor before the video's first picture (a file cut between keyframes, its audio starting up to a GOP
    /// earlier) has no frame to show: once that picture heads the queue, the clock starts at the anchor and the
    /// audio before the picture plays.
    nonisolated func alignPendingClockStartWithFirstFrame() {
        guard frameQueue.getLastRenderedPTS() < 0, let head = frameQueue.headFramePTS, head.isNumeric else { return }
        let frameDuration = nominalFrameDurationLock.withLock { $0 }
        let maxGap = CMTime(seconds: frameDuration * 2, preferredTimescale: 1_000_000)
        let videoStart = videoStartTimeLock.withLock { $0 }
        let headIsFirstPicture = abs(head.seconds - videoStart) < frameDuration / 2
        enum Action {
            case none, move, waitForOutput
            case start(PendingClockStart)
        }
        let isOutputReady = isAudioOutputReady.withLock { $0 }
        let action = pendingClockStartLock.withLock { pending -> Action in
            guard let current = pending, current.targetTime.isNumeric, head > current.targetTime else { return .none }
            if head - current.targetTime <= maxGap {
                pending?.targetTime = head
                return .move
            }
            guard headIsFirstPicture else { return .none }
            // The output is not ready: the start stays pending, and the completion of its activation starts it.
            guard isOutputReady else { return .waitForOutput }
            pending = nil
            return .start(current)
        }
        switch action {
        case .none:
            break
        case .waitForOutput:
            isClockWaitingForOutput.withLock { $0 = true }
        case .move:
            playbackClock.setRate(0, time: head)
        case .start(let pending):
            startSynchronizerClock(
                at: pending.targetTime, rate: pending.rate, startDelay: pending.startDelay,
                isProvisional: pending.isProvisional)
            DispatchQueue.main.async { [weak self] in self?.updateAwaitingClockStart() }
            AppLog.debug(
                .engine,
                "Preroll: video starts at \(String(format: "%.3f", head.seconds))s; starting clock at \(String(format: "%.3f", pending.targetTime.seconds))s"
            )
        }
    }

    /// What the preroll was waiting for: the anchor frame is presented only by a display-link tick, so a timeout
    /// means the link did not tick (hidden or occluded host window, paused link), the decoder delivered nothing,
    /// or the first queued frame lies beyond the anchor time.
    private func prerollDiagnostics(_ pending: PendingClockStart) -> String {
        let windowState = videoHost?.visibilityDescription ?? "none"
        let linkState = displayLink.map { $0.isPaused ? "paused" : "running" } ?? "none"
        let head = frameQueue.headFramePTS.map { String(format: "%.3fs", $0.seconds) } ?? "none"
        let presentedPTS = frameQueue.getLastRenderedPTS()
        let presented = presentedPTS >= 0 ? String(format: "%.3fs", presentedPTS) : "none"
        let anchor = String(format: "%.3fs", pending.targetTime.seconds)
        return "Display link: \(linkState), \(pending.displayLinkTicks) ticks; host window: \(windowState); "
            + "queued frames: \(frameQueue.count), first at \(head); presented: \(presented); anchor: \(anchor)"
    }

    /// The clock is about to stop or be re-anchored: every path that does it (pause, seek, reload, a clock start)
    /// passes here first, directly or through `haltPlaybackPipeline()` / `startSynchronizerClockAfterPreroll`. Despite
    /// its name, it ends both holds on the clock, a pending preroll and buffering, whose tasks would otherwise restart
    /// it at a stale position, and tells the audio detectors (`clockDidStop()`).
    ///
    /// Buffering ends itself through here (its resume restarts the clock), so its start, which holds the clock,
    /// calls `clockDidStop()` alone.
    func cancelPreroll() {
        isClockWaitingForOutput.withLock { $0 = false }
        pendingClockStartLock.withLock { $0 = nil }
        prerollTimeoutTask?.cancel()
        prerollTimeoutTask = nil
        audioJoin.cancel()
        updateAwaitingClockStart()
        cancelBuffering()
        clockDidStop()
    }

    /// Tells the audio detectors the clock stopped or is re-anchored: a lag or an output IO stop seen before no longer
    /// counts, and an IO stop from here until the clock starts again is the engine's own.
    func clockDidStop() {
        audioLagDetector.clockRestarted()
        audioOutputInterruptionLock.withLock { $0.clockStopped() }
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func stepVolume(by delta: Float) {
        volume = max(0.0, min(1.0, volume + delta))
    }

    public func toggleMute() {
        isMuted.toggle()
    }

    public func setPlaybackRate(_ rate: Double) {
        let rounded = (rate * 100).rounded() / 100.0
        let clamped = max(0.5, min(rounded, 4.0))
        // Choosing the speed already in effect (kept from the previous media) still makes it this media's.
        playbackRateMemory.choose()
        // Faster than real time at a live edge waits for behind it: the edge would slow it again at once.
        let rate = live.chosenRate(clamped, at: currentTime)
        if rate != clamped {
            AppLog.info(.engine, "Playback rate \(clamped)x held for behind the live edge")
        }
        if rate != playbackRate {
            playbackRate = rate
            AppLog.info(.engine, "Playback rate changed to \(playbackRate)x")
        }
        saveCurrentPlaybackProgress()
    }

    public func stepPlaybackRate(by delta: Double) {
        // From the speed held for behind a live edge, not the real time played there.
        let target = (((live.rateBeforeEdge ?? playbackRate) + delta) * 10).rounded() / 10.0
        setPlaybackRate(target)
    }

    public func resetPlaybackRate() {
        setPlaybackRate(1.0)
    }

    /// Loads and begins playback of a playlist item.
    public func load(item: PlaylistItem) {
        load(item: item, reportingPlaylistRequest: nil)
    }

    func load(item: PlaylistItem, reportingPlaylistRequest: MediaLoadRequest?) {
        let pathString = item.url.isFileURL ? item.url.standardizedFileURL.path : item.url.absoluteString
        let request = MediaLoadRequest(
            path: pathString,
            title: item.title,
            headers: item.customHeaders,
            startTime: item.startTime
        )
        // Every item played is reported as loaded (`onMediaLoaded`), the playlist file it came from with it.
        self.load(
            request,
            reporting: reportingPlaylistRequest.map { .playlist($0, item: request) } ?? .media(request)
        )
    }

    /// With `PlayerConfiguration.previousRestartsMedia`, played past this many seconds, Previous restarts the media
    /// instead of moving to the previous item.
    static let previousRestartThreshold = 3.0

    /// Whether Next moves anywhere: in the host's queue when the host keeps one (`onTrackNavigation`), else in
    /// `playlist`, whose last item wraps to its first whatever the repeat mode.
    public var canPlayNext: Bool {
        onTrackNavigation != nil ? trackNavigation.hasNext : playlist.hasNextWrappingAround
    }

    /// Whether Previous does anything. With `previousRestartsMedia` it restarts the media when there's no previous
    /// item, so it's available whenever media is loaded; without, only when there's an item to move to (the
    /// playlist's first wraps to its last).
    public var canPlayPrevious: Bool {
        let restartsMedia = configuration.previousRestartsMedia
        if onTrackNavigation != nil {
            return isLoaded && (restartsMedia || trackNavigation.hasPrevious)
        }
        return playlist.currentItem != nil && (restartsMedia || playlist.hasPreviousWrappingAround)
    }

    /// Moves to the next item: asks the host's queue for it, or loads the playlist's. Returns the item's title for
    /// the OSD, `nil` when there's nothing to move to.
    @discardableResult
    public func playNext() -> String? {
        if let onTrackNavigation {
            guard trackNavigation.hasNext else { return nil }
            let title = trackNavigation.nextTitle
            // Until the host loads the next item: each repeated press while it does would skip another one.
            trackNavigation.hasNext = false
            AppLog.info(.engine, "Asking the host for the next item")
            onTrackNavigation(.next)
            return title
        }
        guard let item = playlist.playNext(isUserAction: true) else { return nil }
        load(item: item)
        return item.title
    }

    /// Moves to the previous item (the host's or the playlist's; the playlist's first wraps to its last). With
    /// `previousRestartsMedia` it restarts the media instead if played past `previousRestartThreshold` or there's no
    /// previous item. Returns the title of the media played next for the OSD.
    @discardableResult
    public func playPrevious() -> String? {
        let restartsMedia = configuration.previousRestartsMedia
        if let onTrackNavigation {
            guard isLoaded else { return nil }
            if restartsMedia, currentTime > Self.previousRestartThreshold || !trackNavigation.hasPrevious {
                seek(to: 0)
                play()
                return mediaTitle
            }
            guard trackNavigation.hasPrevious else { return nil }
            let title = trackNavigation.previousTitle
            // Like `playNext`: one press, one item.
            trackNavigation.hasPrevious = false
            AppLog.info(.engine, "Asking the host for the previous item")
            onTrackNavigation(.previous)
            return title
        }
        let (item, shouldRestart) = playlist.playPrevious(
            restartsMedia: restartsMedia,
            restartThresholdSeconds: Self.previousRestartThreshold,
            currentPlaybackTime: currentTime
        )
        if shouldRestart {
            seek(to: 0)
            play()
        } else if let item {
            load(item: item)
        }
        return item?.title
    }

    /// Selects and plays a specific item from the playlist by UUID.
    public func playPlaylistItem(id: UUID) {
        // If clicking on the currently active item, just ensure it plays without restarting
        if let currentItem = playlist.currentItem, currentItem.id == id, isLoaded {
            if !isPlaying {
                play()
            }
            return
        }

        if let item = playlist.selectItem(id: id) {
            load(item: item)
        }
    }

    /// Removes an item from the playlist. If the removed item was currently playing,
    /// stops playback or advances to the next remaining item.
    public func removePlaylistItem(id: UUID) {
        let isRemovingCurrent = (playlist.currentItem?.id == id)
        playlist.remove(id: id)

        if isRemovingCurrent {
            if let nextItem = playlist.currentItem {
                load(item: nextItem)
            } else {
                stop()
            }
        }
    }
}
