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

    /// Takes the window the demuxer tells now (a tick of playback), brings the picture back into it if its place has
    /// expired from the playlist (the segments before the window are gone from the server, and a demuxer that reaches
    /// for one fails), and reads again if the demuxer has stopped. Runs at the tick of playback: a picture paused for
    /// longer than the window is brought back once it resumes, not while it stands.
    func trackLiveWindow(at seconds: Double) {
        guard live.isLive else { return }
        if let report = demuxer?.liveReport { live.update(window: report.window, at: report.loadedAt) }
        guard !live.isEnded, !isSeeking, chase == nil else { return }
        if live.shouldRecoverWindow(at: seconds), let window = live.window() {
            AppLog.info(.engine, "Live window moved past the picture (\(seconds)s < \(window.start)s): seeking into it")
            seek(to: window.start + LiveStream.startMargin * 2, exact: false)
        } else if live.shouldRecoverReading(isStopped: demuxer?.isEOF == true) {
            // The playlist failed to load for good (a server error, `max_reload` spent) and what was read is played:
            // the picture would stand with the clock going on. A seek puts the demuxer right and reads again.
            AppLog.warning(.engine, "The live stream stopped reading at \(seconds)s: seeking to read again")
            seek(to: seconds, exact: false)
        }
    }

    /// Seeks a live stream to its edge ("go live"); does nothing for other media.
    public func seekToLiveEdge() {
        guard let edge = live.edgeTarget() else { return }
        seek(to: edge, exact: false)
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
            // A held key's presses are one burst however long its repeats take to start: `endScrubbing` arms the
            // timer again.
            if self.isScrubbing { return }
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

        // The end-of-media wait of an earlier seek in the burst, and the audio join of one that resumed
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        cancelPreroll()

        // 1. Maintain play intent across seek bursts (Apple QA1820 / mpv)
        if !isSeeking && chase == nil {
            resumePlaybackAfterChase = isPlaying
            if isPlaying {
                // Instantly pause playback clock and CADisplayLink during seek burst to prevent clock jitter / drift
                playbackClock.setRate(0.0, time: playbackClock.currentTime())
                displayLink?.isPaused = true
            }
        }

        // 2. Immediate responsive UI update (0ms latency for exact seek)
        chase = ChaseTarget(
            seconds: target, exact: exact, forward: forward, minFramePTS: minFramePTS, bound: live.bound(of: seconds))
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
        audioJoin.isRendererStale = true
        let targetSeconds = target.seconds
        let seekId = seekGeneration.current
        let loadID = currentLoadID

        let shouldResume = self.resumePlaybackAfterChase

        // Stop feeding packets from the old position. The video feeder is only cancelled: it may be inside a decode of a
        // packet from there, whose frame would come out into the seek's preview, so the seek waits for it below.
        isFeeding.withLock { $0 = false }
        let unwindingVideoFeeder = videoFeedingTask
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

        seekQueue.async {
            [weak self, demuxer, externalAudio, decoder, frameQueue, pausedStepCache, unwindingVideoFeeder] in
            guard let self else { return }
            // Before the decoder is flushed and the demuxer moved: the old run's last frame (`SeekPreview` takes the
            // earliest one the decoder emits, so a stale one from the old position wins over the landing's) and its
            // last packet read would otherwise come in after.
            if let unwindingVideoFeeder {
                Self.waitForUnwind(of: unwindingVideoFeeder)
                frameQueue.clear()
            }
            let signposter = PlayerPerformanceMonitor.shared.signposter
            let signpostID = signposter.makeSignpostID()
            let seekInterval = signposter.beginInterval("Seek", id: signpostID)
            defer { signposter.endInterval("Seek", seekInterval) }

            let isSuperseded: @Sendable () -> Bool = { !seekGeneration.isCurrent(seekId) }
            // The seek as it lands: past the last keyframe, a forward keyframe seek goes to its target exactly
            // instead of back to that keyframe (see `MediaDemuxer.seek`), to the last frame for a target at the end.
            var landed = target
            var didFastSeek = false

            if !isSuperseded() {
                if hasVideo {
                    decoder.flush()
                }
                let outcome = demuxer.seekReportingCache(
                    to: targetSeconds, exact: target.exact, forward: target.forward, audioDelay: audioDelay)
                let isExact = outcome.isExact
                didFastSeek = outcome.fromCache
                if isExact && !target.exact {
                    landed.exact = true
                    landed.forward = false
                    frameQueue.setDisplayFloor(exactFloor)
                }
            }

            signposter.emitEvent("Demuxed", id: signpostID)
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
                // In-cache seeks already have their subtitle packets collected, so do not advance span start.
                if !didFastSeek, let preview = previewFrame { demuxer.noteSubtitleReadsStart(at: preview.pts) }
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

            signposter.emitEvent("Previewed", id: signpostID)
            // Expensive audio reset only for the seek that is still current (final chase target).
            if !isSuperseded() {
                audioDecoder?.flush()
                // Resuming: `AudioJoin` flushes, when it must, however many seeks the burst took. Paused: by the same
                // rule, from where the picture landed (audio that ends before it is dropped as late once playing).
                if !shouldResume {
                    let landing = CMTime(seconds: previewFrame?.pts ?? targetSeconds, preferredTimescale: 1_000_000)
                    if AudioJoin.needsFlush(
                        bufferedEnd: audioSink.bufferedEnd, startsAt: landing, isFlushOwed: audioSink.isFlushOwed,
                        isEnqueuePending: audioSink.pendingStart != nil)
                    {
                        audioSink.flush()
                    }
                }
            }

            signposter.emitEvent("Audio reset", id: signpostID)
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

            playbackClock.setRate(0.0, time: targetTime)
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
        // Scrubbing: the frame is up and the clock stays held there; `endScrubbing` resumes from the last landing. The
        // picture would otherwise play a few frames between a held key's repeats, and the feeders and the audio join
        // would start and be cancelled for each.
        if isScrubbing {
            playbackClock.setRate(0.0, time: targetTime)
            AppLog.debug(.engine, "Chase seek landed at \(completedSeconds)s while scrubbing; held")
            return
        }
        resumeAfterChase(seekId: seekId, at: completedSeconds)
    }

    /// Seeks from here on are made while a key (or a scrubber) is held: each shows its frame, and playback, if it was on,
    /// resumes only at `endScrubbing()`, the release. A seek made without either resumes as it lands.
    public func beginScrubbing() {
        isScrubbing = true
    }

    /// The series of seeks is over: playback resumes from where the last one landed, at once (or when the one in flight
    /// lands). Without a call, the series lasts until the next load; hosts end it when the key is released or the
    /// window loses focus.
    public func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        // The burst (the offset the OSD reports) goes on for a tap that follows soon, as between taps.
        armRelativeSeekBurstTimer()
        // A seek in flight resumes itself as it lands; one that landed while scrubbing waits here.
        guard !isSeeking, let landed = chase else { return }
        if resumePlaybackAfterChase {
            resumeAfterChase(seekId: seekGeneration.current, at: landed.seconds)
        } else {
            // Paused meanwhile (`pause()` cleared the intent): the landing settles as a paused seek's does, or `play()`
            // would take the chase left behind for one still on its way.
            chase = nil
        }
    }

    /// Resumes playback at `completedSeconds`, where seek `seekId` landed, at once: the picture runs on a clock of its own
    /// (host time) and the audio, flushed and refilled behind it, joins that clock later (`AudioJoin`). A seek that comes
    /// before the next frame takes over from here; seeks in a series cost no more than the picture.
    ///
    /// Landed at the end, the media ends instead, after a short wait (`endOfMediaWait`): the key repeats of a held key
    /// still come, and would land in the next item a completion loads.
    private func resumeAfterChase(seekId: Int, at completedSeconds: Double) {
        let targetTime = CMTime(seconds: completedSeconds, preferredTimescale: 1000)
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        // Landed at the end, the media ends, as playing on to it would (within the same margin): resuming there would
        // start the clock with nothing left to read.
        if isAtEndOfMedia(completedSeconds) {
            scheduleEndOfMediaAfterChase(seekId: seekId, at: completedSeconds)
            return
        }
        chase = nil
        startFeeding(audio: false)
        let joinsAudio = hasAudioStream
        if media.hasVideo {
            startSynchronizerClockAfterPreroll(at: targetTime, isProvisional: joinsAudio)
        } else {
            cancelPreroll()
            playbackClock.setRate(0.0, time: targetTime)
        }
        if joinsAudio {
            audioJoin.begin(on: self, from: targetTime, hasPicture: media.hasVideo)
        } else if !media.hasVideo {
            startSynchronizerClock(at: targetTime, rate: playbackRate)
        }
        displayLink?.isPaused = !media.hasVideo
        isPlaying = true
        playbackState = .playing
        performanceMonitor.handlePlaybackStateChange(isPlaying: true)
        AppLog.debug(.engine, "Chase seek resumed at \(completedSeconds)s")
    }

    /// How long a seek that landed at the end waits for more presses before the media ends.
    static let endOfMediaWait: Duration = .milliseconds(300)

    private func scheduleEndOfMediaAfterChase(seekId: Int, at completedSeconds: Double) {
        chaseSettleTask?.cancel()
        chaseSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.endOfMediaWait)
            guard !Task.isCancelled, let self, self.seekGeneration.isCurrent(seekId) else { return }
            self.chaseSettleTask = nil
            self.chase = nil
            self.resumePlaybackAfterChase = false
            AppLog.debug(.engine, "Chase seek settled at the end (\(completedSeconds)s) while playing")
            self.handleEndOfMedia()
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
            // A chase with no seek in flight has landed: it waits to end the media (`chaseSettleTask`) or is held by
            // scrubbing, whose end resumes, and so ends, it there.
            if let settled = chase, isAtEndOfMedia(settled.seconds) {
                if chaseSettleTask != nil {
                    scheduleEndOfMediaAfterChase(seekId: seekGeneration.current, at: settled.seconds)
                }
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

        let target = ChaseTarget(
            seconds: clampedSeekTarget(baseTime + seconds), exact: isExact, forward: isForward, minFramePTS: nil,
            bound: live.bound(of: baseTime + seconds))
        if isSeekInFlight(toPressed: target) {
            return relativeSeekBurst.offset(landingAt: target.seconds) ?? 0
        }

        // In burst mode (keyframe seek), always step from the latest targeted or settled frame
        // so every press advances past the current GOP to the next/prev keyframe without freezing.
        seek(to: baseTime + seconds, exact: isExact, forward: isForward)

        return relativeSeekBurst.offset(landingAt: chase?.seconds ?? currentTime) ?? 0
    }

    /// Where a seek to `seconds` goes: within the media; of a live stream, within the window its playlist lists.
    func clampedSeekTarget(_ seconds: Double) -> Double {
        if live.isLive { return live.clamp(seconds) }
        return max(0, media.duration > 0 ? min(seconds, media.duration) : seconds)
    }

    /// The picture shows the media's last frame, where a seek to the end lands: within a frame and a half of the end
    /// (`duration` is where the last frame's display ends). Not just within the margin of `isAtEndOfMedia`, from which
    /// frame steps and seeks still reach the frames after.
    private var isOnLastFrame: Bool {
        // A live stream that ended ends where its last window does.
        let end = live.isEnded ? (live.window()?.end ?? 0) : media.duration
        return media.hasVideo && end > 0 && currentFramePTS >= end - nominalFrameDuration * 1.5
    }

    public func seekRelative(by seconds: Double, exact: Bool) {
        resetRelativeSeekBurst()
        let baseTime = chase?.seconds ?? currentTime
        // Forward keyframe steps must land on the next keyframe; a backward search on sparse-GOP
        // streams (AV1) would snap back to the current keyframe and the position would never advance.
        let forward = seconds > 0 && !exact
        let target = ChaseTarget(
            seconds: clampedSeekTarget(baseTime + seconds), exact: exact, forward: forward, minFramePTS: nil,
            bound: live.bound(of: baseTime + seconds))
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
        // A live stream's ends are the window's, which move with the clock: targets at the same end, not equal ones.
        if live.isLive { return target.bound != nil && target.bound == chase.bound }
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
        playbackClock.setRate(0.0, time: entry.pts)
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
