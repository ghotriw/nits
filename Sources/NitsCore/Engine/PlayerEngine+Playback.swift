@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

extension PlayerEngine {
    public func play() {
        resetRelativeSeekBurst()
        guard isLoaded else { return }

        // If video reached the end or is in completed state, restart from the beginning
        if playbackState == .completed || isAtEndOfMedia(currentTime) {
            seek(to: 0.0)
        }

        // After frame-stepping the demuxer/decoder sit ahead of the cursor and audio before the seek
        // baseline was purged, so resuming feeding as-is would freeze video and drop/desync audio. Reseek
        // to currentTime first; the chase-settle machinery then resumes playback cleanly at the cursor.
        if media.hasVideo, !isSeeking, chase == nil, frameStep.didStepSincePause {
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

        // The load's start still runs on `seekQueue` (`isLoadStartPending`): the feeders would read from before its
        // start position. Playing from now on, as after a start right away; the start, once in, starts the pipeline.
        if isLoadStartPending {
            isPlaying = true
            playbackState = .playing
            return
        }

        let feedingActive = isFeeding.withLock { $0 }
        if !feedingActive {
            startFeeding()
        }
        let targetTime = resolvePlaybackStartTime(syncTime: playbackClock.currentTime())
        // Resuming from pause: the audio renderer still holds the paused media.
        startSynchronizerClockAfterPreroll(at: targetTime, alignWithBufferedAudio: true)
        displayLink?.isPaused = !media.hasVideo
        isPlaying = true
        playbackState = .playing
        performanceMonitor.handlePlaybackStateChange(isPlaying: true)
    }

    public func pause() {
        resetRelativeSeekBurst()
        if isSeeking || chase != nil {
            resumePlaybackAfterChase = false
        }
        stopPlaybackPipeline()
        playbackState = .paused
        saveCurrentPlaybackProgress()
    }

    /// Halts clock synchronization and feeders without altering user-facing isPlaying or playbackState.
    func haltPlaybackPipeline() {
        cancelPreroll()
        playbackClock.setRate(0.0, time: playbackClock.currentTime())
        displayLink?.isPaused = true
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        // A seek that has decoded its target and only waits to resume settles here, at its target; left pending,
        // it would keep reporting a seek and make `play()` wait for it forever.
        if chaseSettleTask != nil, !isSeeking, let settledSeconds = chase?.seconds {
            chase = nil
            playbackClock.setRate(0.0, time: CMTime(seconds: settledSeconds, preferredTimescale: 1000))
        }
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        chaseSettling.abandonSettle()
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
        at targetTime: CMTime, rate: Double, startDelay: TimeInterval = 0, keepsRunning: Bool = false
    ) {
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        // A positive-rate setRate(_:time:) leaves currentTime() at its old value until the audio device has started
        // (tens of ms, hundreds under load), so after a backward seek the display link would drop every frame from
        // the new position as late. Moving the paused clock first makes the new position visible at once; a
        // running clock (rate change) is left alone so audio does not restart.
        if rate > 0, playbackClock.rate == 0, targetTime.isNumeric,
            abs(playbackClock.currentTime().seconds - targetTime.seconds) > 0.001
        {
            playbackClock.setRate(0, time: targetTime)
        }
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
    func startSynchronizerClockAfterPreroll(at targetTime: CMTime, alignWithBufferedAudio: Bool = false) {
        cancelPreroll()
        let isAudioReady = isAudioReadyToStart(at: targetTime)
        // Nothing presents video without a display link, so there is no anchor frame to protect.
        let isReady =
            !media.hasVideo || displayLink == nil || (inputs?.isVideoEOF ?? true)
            || (frameQueue.getLastRenderedPTS() >= 0 && frameQueue.count >= Self.prerollMinimumQueuedFrames)
        let startDelay =
            alignWithBufferedAudio
            ? min(PlatformAudioOutputRoute.currentOutputLatency() ?? 0, Self.maxOutputLatencyAlignment) : 0
        if isReady && isAudioReady {
            if startDelay > 0 {
                AppLog.debug(
                    .engine,
                    "Aligning clock start with buffered audio: +\(String(format: "%.1f", startDelay * 1000.0))ms output latency"
                )
            }
            startSynchronizerClock(at: targetTime, rate: playbackRate, startDelay: startDelay)
            return
        }

        playbackClock.setRate(0.0, time: targetTime)
        var request = PendingClockStart(
            targetTime: targetTime, rate: playbackRate, requestHostTime: CACurrentMediaTime())
        request.awaitsAudio = !isAudioReady
        request.startDelay = startDelay
        let pending = request
        pendingClockStartLock.withLock { $0 = pending }
        updateAwaitingClockStart()
        if !isAudioReady { awaitAudioBeforeClockStart() }
        prerollTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.prerollTimeout)
            guard !Task.isCancelled, let self else { return }
            self.prerollTimeoutTask = nil
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
            self.startSynchronizerClock(at: pending.targetTime, rate: pending.rate, startDelay: pending.startDelay)
        }
    }

    /// Called from the display-link tick after presentation: starts a pending clock exactly once when the
    /// anchor frame is on screen and the next frames are decoded.
    nonisolated func startPendingClockIfPrerolled() {
        guard pendingClockStartLock.withLock({ $0 != nil && $0?.awaitsAudio == false }),
            frameQueue.getLastRenderedPTS() >= 0,
            frameQueue.count >= Self.prerollMinimumQueuedFrames,
            let pending = pendingClockStartLock.withLock({ state -> PendingClockStart? in
                guard let claimed = state, !claimed.awaitsAudio else { return nil }
                state = nil
                return claimed
            })
        else { return }

        startSynchronizerClock(at: pending.targetTime, rate: pending.rate, startDelay: pending.startDelay)
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
            case none, move
            case start(PendingClockStart)
        }
        let action = pendingClockStartLock.withLock { pending -> Action in
            guard let current = pending, current.targetTime.isNumeric, head > current.targetTime else { return .none }
            if head - current.targetTime <= maxGap {
                pending?.targetTime = head
                return .move
            }
            guard headIsFirstPicture, !current.awaitsAudio else { return .none }
            pending = nil
            return .start(current)
        }
        switch action {
        case .none:
            break
        case .move:
            playbackClock.setRate(0, time: head)
        case .start(let pending):
            startSynchronizerClock(at: pending.targetTime, rate: pending.rate, startDelay: pending.startDelay)
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
        pendingClockStartLock.withLock { $0 = nil }
        prerollTimeoutTask?.cancel()
        prerollTimeoutTask = nil
        prerollAudioTask?.cancel()
        prerollAudioTask = nil
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
        if clamped != playbackRate {
            playbackRate = clamped
            AppLog.info(.engine, "Playback rate changed to \(playbackRate)x")
        }
        saveCurrentPlaybackProgress()
    }

    public func stepPlaybackRate(by delta: Double) {
        let target = ((playbackRate + delta) * 10).rounded() / 10.0
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

    /// Played past this many seconds, Previous restarts the media instead of moving to the previous item.
    static let previousRestartThreshold = 3.0

    /// Whether Next moves anywhere: in the host's queue when the host keeps one (`onTrackNavigation`), else in
    /// `playlist`.
    public var canPlayNext: Bool {
        onTrackNavigation != nil ? trackNavigation.hasNext : playlist.hasNext
    }

    /// Whether Previous does anything. It restarts the media when there's no previous item, so with the host's
    /// queue it's available whenever media is loaded.
    public var canPlayPrevious: Bool {
        onTrackNavigation != nil ? isLoaded : playlist.currentItem != nil
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

    /// Restarts the media if played past `previousRestartThreshold` or there's no previous item, otherwise moves to
    /// the previous item (the host's or the playlist's). Returns the title of the media played next for the OSD.
    @discardableResult
    public func playPrevious() -> String? {
        if let onTrackNavigation {
            guard isLoaded else { return nil }
            guard currentTime <= Self.previousRestartThreshold, trackNavigation.hasPrevious else {
                seek(to: 0)
                play()
                return mediaTitle
            }
            let title = trackNavigation.previousTitle
            // Like `playNext`: one press, one item.
            trackNavigation.hasPrevious = false
            AppLog.info(.engine, "Asking the host for the previous item")
            onTrackNavigation(.previous)
            return title
        }
        let (item, shouldRestart) = playlist.playPrevious(
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
