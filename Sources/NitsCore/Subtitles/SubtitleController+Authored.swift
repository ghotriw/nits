import Foundation

// MARK: - Authored (libass) subtitles

extension SubtitleController {
    /// Keeps libass in step with the selected track, the setting and the size to draw at: starts its renderer for an
    /// ASS track, hands it the events a live source has read since, and drops it when it no longer applies. Nothing
    /// here waits for libass: creating the renderer (fonts) and feeding it happen off the main thread.
    func syncAuthored(renderIfReady: Bool = true) {
        let selected = selectedTrackId.flatMap { id in tracks.first { $0.id == id } }
        guard usesAuthoredStyles, renderSize.width >= 1, renderSize.height >= 1,
            selected?.format == .ass, let script = activeDocument?.assScript, let trackId = selected?.id
        else {
            dropAuthoredRenderer()
            return
        }

        authoredScript = script
        if authoredRendererTrackId != trackId {
            startAuthoredRenderer(for: script, trackId: trackId)
        } else if renderIfReady {
            renderAuthored(at: (host?.currentTime ?? 0) - delay)
        }
    }

    private func dropAuthoredRenderer() {
        guard authoredRendererTrackId != nil || isDrawingAuthored else { return }
        authoredGeneration += 1
        authoredRenderer = nil
        authoredRendererTrackId = nil
        authoredScript = nil
        pendingAuthoredRenderTime = nil
        isDrawingAuthored = false
        if !images.isEmpty { images = [] }
    }

    /// Creates the renderer in the background. The text cues stay hidden meanwhile, so a track doesn't flash as plain
    /// text before it appears styled; if libass can't read the script, or is stuck (`watchLibass`), the text is shown
    /// after all.
    private func startAuthoredRenderer(for script: AssScript, trackId: Int) {
        authoredGeneration += 1
        let generation = authoredGeneration
        authoredRenderer = nil
        authoredRendererTrackId = trackId
        pendingAuthoredRenderTime = nil
        // It would wait behind the stuck call.
        guard !isLibassStalled else {
            isDrawingAuthored = false
            return
        }
        isDrawingAuthored = true
        AppLog.info(.subtitles, "Drawing subtitle track \(trackId) with libass")
        libassCallsInFlight += 1
        watchLibass()
        Task { [weak self] in
            let renderer = await AssSubtitleRenderer.perform { AssSubtitleRenderer(script: script) }
            guard let self else { return }
            self.libassCallsInFlight -= 1
            // Made after libass was found stuck: the text stays for this media.
            guard self.authoredGeneration == generation, !self.isLibassStalled else { return }
            guard let renderer else {
                AppLog.warning(.subtitles, "libass can't read the script of subtitle track \(trackId)")
                self.isDrawingAuthored = false
                return
            }
            self.authoredRenderer = renderer
            self.renderAuthored(at: (self.host?.currentTime ?? 0) - self.delay)
        }
    }

    /// Renders on libass' queue (`AssSubtitleRenderer.perform`), at most one at a time; a time asked for meanwhile is
    /// rendered next. The events read since the last render go to libass in the same call, as it may be busy with a
    /// frame. None once libass was found stuck.
    func renderAuthored(at seconds: Double) {
        guard let renderer = authoredRenderer, !isLibassStalled else { return }
        guard !isAuthoredRenderRunning else {
            pendingAuthoredRenderTime = seconds
            return
        }
        isAuthoredRenderRunning = true
        let size = renderSize
        let video = host?.subtitleVideo ?? SubtitleVideo()
        // The pixel aspect of the video's own pixels as shown: ASS coordinates are in them, the frame is in square
        // ones. A forced aspect ratio stretches them; a crop doesn't.
        let frameAspect = VideoGeometry.frameAspectRatio(
            videoWidth: video.width, videoHeight: video.height, sampleAspectRatio: video.sampleAspectRatio,
            settings: video.geometry)
        let pixelAspect =
            video.width > 0 && video.height > 0 && frameAspect.isNormal
            ? frameAspect * Double(video.height) / Double(video.width) : video.sampleAspectRatio.multiplier
        let events = authoredScript?.events ?? []
        let styleOverride = AssSubtitleRenderer.StyleOverride(
            mode: assStyleOverride, subtitleFontName: style.fontName, fontSize: style.fontSize,
            textColorHex: style.textColorHex, backgroundColorHex: style.backgroundColorHex,
            backgroundOpacity: style.backgroundOpacity)
        let placement = (scale: effectiveScale, raise: raise)
        libassCallsInFlight += 1
        watchLibass()
        Task { [weak self] in
            let output = await AssSubtitleRenderer.perform {
                renderer.addEvents(events)
                renderer.configure(
                    frameWidth: Int(size.width.rounded()), frameHeight: Int(size.height.rounded()),
                    videoWidth: video.width, videoHeight: video.height, pixelAspect: pixelAspect)
                renderer.setStyleOverride(styleOverride)
                renderer.setPlacement(scale: placement.scale, raise: placement.raise)
                return renderer.render(at: seconds)
            }
            guard let self else { return }
            self.isAuthoredRenderRunning = false
            self.libassCallsInFlight -= 1
            // A frame of a stuck call that returned after all: the text stays for this media.
            guard !self.isLibassStalled else { return }
            // A frame of a renderer since replaced is dropped, but a time asked for meanwhile is still rendered (by
            // the current renderer): paused, nothing else would draw it.
            if renderer === self.authoredRenderer, case .frame(let cue) = output {
                self.images = cue.map { [$0] } ?? []
                self.scheduleAuthoredAnimationFrame()
            }
            if let next = self.pendingAuthoredRenderTime {
                self.pendingAuthoredRenderTime = nil
                self.renderAuthored(at: next)
            }
        }
    }

    /// Checks, while this controller's libass calls are under way, that the one running comes back within
    /// `libassStallTimeout`. One that doesn't is stuck (a font request to `fontd` that never returns, see
    /// `AssSubtitleRenderer.queue`): the media's ASS tracks show their text cues from then on, as everything later put
    /// on the queue would wait behind it (`reset` tries libass again with the next media). One check at a time.
    private func watchLibass() {
        guard libassWatch == nil, !isLibassStalled else { return }
        let timeout = libassStallTimeout
        // How often to look while a call of ours waits for the queue rather than runs on it.
        let poll = min(timeout, .milliseconds(500))
        libassWatch = Task { [weak self] in
            var wait = timeout
            while true {
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                // None of ours left: another's long call (another window, a renderer released) is nothing to wait
                // for.
                guard self.libassCallsInFlight > 0 else {
                    self.libassWatch = nil
                    return
                }
                guard let running = AssSubtitleRenderer.currentCallDuration else {
                    wait = poll
                    continue
                }
                guard running >= timeout else {
                    wait = timeout - running
                    continue
                }
                self.libassWatch = nil
                AppLog.error(
                    .subtitles,
                    "libass has been stuck in a call for \(running) (a font request to fontd?); showing the text "
                        + "of ASS tracks for this media")
                self.isLibassStalled = true
                self.pendingAuthoredRenderTime = nil
                self.isDrawingAuthored = false
                if !self.images.isEmpty { self.images = [] }
                return
            }
        }
    }

    /// Redraws what libass shows now, for a change of how it draws (style, placement, pixel aspect) rather than of
    /// time; nothing when libass isn't drawing.
    func redrawAuthored() {
        guard isDrawingAuthored else { return }
        renderAuthored(at: (host?.currentTime ?? 0) - delay)
    }

    /// Redraws ASS dialogue in a changed style, which it only takes with `assStyleOverride`.
    func restyleAuthored() {
        if assStyleOverride != .none { redrawAuthored() }
    }

    /// While the picture libass draws keeps changing (a fade, a move, karaoke), draws it again a video frame later
    /// rather than at the next time tick (20 Hz), which made animations step. The first render that changes nothing
    /// ends it, so a still line costs one extra render.
    func scheduleAuthoredAnimationFrame() {
        guard !isAuthoredAnimationFrameScheduled, let host, host.isPlaying else { return }
        isAuthoredAnimationFrameScheduled = true
        let interval = min(max(host.subtitleVideo.frameDuration, 1.0 / 120.0), 1.0 / 20.0)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard let self else { return }
            self.isAuthoredAnimationFrameScheduled = false
            // As the time tick: no render while a seek is landing or before playback runs.
            guard self.isDrawingAuthored, let host = self.host, host.isPresentingContinuously else { return }
            let seconds = host.clockSeconds
            guard seconds.isFinite, seconds >= 0 else { return }
            self.renderAuthored(at: seconds - self.delay)
        }
    }
}
