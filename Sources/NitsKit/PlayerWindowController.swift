import AppKit
import NitsCore
import NitsUI
import ScreenCaptureKit
import SwiftUI

@MainActor
public final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    public let engine: PlayerEngine
    public let uiState = PlayerUIState()
    public let nowPlayingController: any NowPlayingController
    /// Callback triggered before player window closes: (finalTime, duration)
    public var onClose: ((_ finalTime: Double, _ duration: Double) -> Void)?
    public var onKeyStatusChanged: ((Bool) -> Void)?

    /// Periodic time observer callback: (currentTime, duration)
    public var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)?
    /// Playback state change callback
    public var onPlaybackStateChanged: ((PlaybackState) -> Void)?
    /// Dedicated callback when video finishes playing to the end
    public var onPlaybackEnded: (() -> Void)?

    private var lastLoggedTimeSeconds: Double = -1.0
    private lazy var pictureInPicture: PictureInPictureController = makePictureInPictureController()
    private var pictureInPictureWindowBehavior: PictureInPictureWindowBehavior = .hide
    private var pausesOnPictureInPicture = false
    private var entersPictureInPictureOnMinimize = false
    private var rememberRecentMedia = true
    private let recentMediaStore: RecentMediaStore?
    /// The window was ordered out by PiP and must come back when PiP ends.
    private var isWindowHiddenForPictureInPicture = false
    /// PiP was started by minimizing the window, so restoring the window from the Dock ends it.
    private var isPictureInPictureFromMinimize = false
    /// PiP's restore, held back while the window comes out of the Dock.
    private var pendingPictureInPictureRestore: (@MainActor () -> Void)?
    /// Set in `windowWillClose`; PiP callbacks and opens still resolving that follow must not show the window again.
    private(set) var isWindowClosing = false

    /// Called with the button's `id` when an action button is pressed, by the user or by auto-press.
    public var onActionButton: ((_ id: String) -> Void)? {
        get { engine.onActionButton }
        set { engine.onActionButton = newValue }
    }

    /// Replaces the action buttons of the media playing now, preserving any resolved buttons (e.g. SponsorBlock);
    /// the next load replaces them again (see `openStream(actionButtons:)`).
    public func setActionButtons(_ buttons: [PlaybackActionButton]) {
        engine.setActionButtons(buttons)
    }

    /// Set by a host that keeps its own queue (a media server client's series): Next and Previous from the control
    /// bar, menu, keyboard and media keys call it instead of moving through the playlist, and the end of the media no
    /// longer plays the playlist's next item. The host answers by opening the item it moves to.
    public var onTrackNavigation: ((_ direction: TrackNavigationDirection) -> Void)? {
        get { engine.onTrackNavigation }
        set { engine.onTrackNavigation = newValue }
    }

    /// Replaces what the host's queue has around the media playing now, e.g. once the host learns the next episode;
    /// the next load replaces it again (see `openStream(trackNavigation:)`).
    public func setTrackNavigation(_ navigation: TrackNavigation) {
        engine.trackNavigation = navigation
    }

    public func applyConfiguration(_ config: PlayerConfiguration) {
        rememberRecentMedia = config.rememberRecentMedia
        engine.applyConfiguration(config)
        applyOSDConfiguration(config)
        applyPictureInPictureConfiguration(config)
        applyActionButtonConfiguration(config)
        applyMediaResolverConfiguration(config)
    }

    private func applyActionButtonConfiguration(_ config: PlayerConfiguration) {
        uiState.actionButton.displayDuration = config.actionButtonDisplayDuration
        uiState.actionButton.autoPress = config.actionButtonAutoPress
    }

    /// Resolves the pages of video sites with yt-dlp (`PlayerConfiguration.resolvesWithYTDLP`), unless the host gave
    /// the engine a resolver of its own.
    private func applyMediaResolverConfiguration(_ config: PlayerConfiguration) {
        guard engine.mediaResolver == nil || engine.mediaResolver is YTDLPResolver else { return }
        engine.mediaResolver =
            config.resolvesWithYTDLP
            ? YTDLPResolver(customPath: config.ytdlpPath, sponsorBlock: config.sponsorBlock) : nil
    }

    private func applyPictureInPictureConfiguration(_ config: PlayerConfiguration) {
        pictureInPictureWindowBehavior = config.pictureInPictureWindowBehavior
        pausesOnPictureInPicture = config.pausesOnPictureInPicture
        entersPictureInPictureOnMinimize = config.entersPictureInPictureOnMinimize
    }

    private func applyOSDConfiguration(_ config: PlayerConfiguration) {
        uiState.osd.eventDuration = config.osdDuration
        uiState.osd.configureDebug(
            enabled: config.enableDebugOSD,
            minimumLevel: config.debugOSDMinimumLevel,
            duration: config.debugOSDDuration
        )
    }

    private var standardButtons: [NSButton] {
        ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType]).compactMap {
            window?.standardWindowButton($0)
        }
    }

    /// - Parameters:
    ///   - engine: An engine built with the same `configuration` and the host's own stores (tests pass
    ///     in-memory ones); `nil` creates one that uses the app's.
    ///   - recentMediaStore: Where loaded media is recorded for Recent Media; `nil` for hosts and tests.
    public init(
        configuration: PlayerConfiguration = PlayerConfiguration(),
        engine: PlayerEngine? = nil,
        recentMediaStore: RecentMediaStore? = nil
    ) {
        let engine = engine ?? PlayerEngine(configuration: configuration)
        self.engine = engine
        self.recentMediaStore = recentMediaStore
        self.nowPlayingController = NowPlayingControllerFactory.makeController(engine: engine)
        let window = PlayerWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)
        nowPlayingController.actions = self
        window.actionHandler = self
        uiState.togglePictureInPicture = { [weak self] in
            self?.togglePictureInPicture()
        }
        uiState.titleBarDoubleClicked = { [weak window] in
            window?.performTitleBarDoubleClickAction()
        }
        // Created now, not on first toggle: it follows the engine from here on and prepares AVKit for the first video.
        _ = pictureInPicture
        rememberRecentMedia = configuration.rememberRecentMedia
        applyOSDConfiguration(configuration)
        applyPictureInPictureConfiguration(configuration)
        applyActionButtonConfiguration(configuration)
        applyMediaResolverConfiguration(configuration)

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        observeMediaTitle()

        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        updateToolbar(isFullscreen: false)

        let contentView = ContentView(
            engine: engine,
            uiState: uiState,
            onOpenURLs: { [weak self] urls in
                self?.openMedia(urls: urls)
            },
            onControlsVisibilityChanged: { [weak self] isVisible in
                self?.updateTrafficLightsVisibility(isVisible: isVisible)
                if !isVisible, self?.window?.isKeyWindow == true {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            },
            onToggleFullscreen: { [weak self] in
                self?.toggleFullscreen()
            }
        )
        .focusedSceneValue(\.playerActions, self)

        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        window.initialFirstResponder = hostingView
        engine.onMediaLoaded = { [weak self] request, historyKey, title, duration in
            guard let self, self.rememberRecentMedia, let recentMediaStore = self.recentMediaStore else {
                return
            }
            let isNetwork = MediaURL.isNetworkURL(request.path)
            guard let url = isNetwork ? URL(string: request.path) : URL(fileURLWithPath: request.path) else { return }
            recentMediaStore.record(
                url: url,
                title: title,
                historyKey: historyKey,
                sourcePath: self.engine.currentSourcePath,
                duration: duration,
                headers: request.headers
            )
        }
        engine.onTimeUpdate = { [weak self] current, dur in
            guard let self else { return }

            if abs(current - self.lastLoggedTimeSeconds) >= 5.0 {
                self.lastLoggedTimeSeconds = current
                AppLog.debug(
                    .engine,
                    "Playback progress: \(String(format: "%.1f", current))s / \(String(format: "%.1f", dur))s"
                )
            }

            self.onTimeUpdate?(current, dur)
            self.nowPlayingController.update(
                title: self.engine.mediaTitle,
                currentTime: current,
                duration: dur,
                isPlaying: self.engine.isPlaying,
                artworkData: self.engine.artworkData,
                artworkURL: self.engine.artworkURL
            )
        }
        engine.onPlaybackStateChanged = { [weak self] state in
            guard let self else { return }

            switch state {
            case .idle:
                AppLog.info(.engine, "Playback state: idle")
            case .loading:
                AppLog.info(.engine, "Playback state: loading '\(self.engine.mediaTitle)'")
            case .playing:
                AppLog.info(
                    .engine,
                    "Playback state: playing at \(String(format: "%.2f", self.engine.currentTime))s"
                )
            case .paused:
                AppLog.info(
                    .engine,
                    "Playback state: paused at \(String(format: "%.2f", self.engine.currentTime))s"
                )
            case .completed:
                AppLog.info(.engine, "Playback state: completed (EOF reached)")
            case .failed(let error):
                AppLog.error(.engine, "Playback state: failed with error: '\(error)'")
            }

            self.onPlaybackStateChanged?(state)
            switch state {
            case .playing:
                self.nowPlayingController.update(
                    title: self.engine.mediaTitle,
                    currentTime: self.engine.currentTime,
                    duration: self.engine.media.duration,
                    isPlaying: true,
                    artworkData: self.engine.artworkData,
                    artworkURL: self.engine.artworkURL
                )
            case .paused:
                self.nowPlayingController.update(
                    title: self.engine.mediaTitle,
                    currentTime: self.engine.currentTime,
                    duration: self.engine.media.duration,
                    isPlaying: false,
                    artworkData: self.engine.artworkData,
                    artworkURL: self.engine.artworkURL
                )
            case .idle, .failed, .completed:
                self.nowPlayingController.clear()
                if state == .completed {
                    AppLog.info(.engine, "Playback ended naturally")
                    self.onPlaybackEnded?()
                }
            case .loading:
                break
            }
        }
        engine.onTrackNavigationChanged = { [weak self] in
            self?.nowPlayingController.updateTrackCommands()
        }
        engine.onRelativeSeekResolved = { [weak self] actualOffset, completedTime in
            guard let self, self.engine.enableOSD, self.uiState.osd.isVisible else { return }
            self.uiState.osd.show(
                .seek(offsetSeconds: actualOffset, currentTime: completedTime, duration: self.engine.media.duration)
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func openFile(
        url: URL,
        title: String? = nil,
        artworkData: Data? = nil,
        artworkURL: URL? = nil,
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil,
        actionButtons: [PlaybackActionButton] = [],
        trackNavigation: TrackNavigation = TrackNavigation()
    ) {
        openStream(
            url: url,
            title: title,
            artworkData: artworkData,
            artworkURL: artworkURL,
            headers: [:],
            startTime: startTime,
            audioTrack: audioTrack,
            subtitleTrack: subtitleTrack,
            actionButtons: actionButtons,
            trackNavigation: trackNavigation
        )
    }

    /// Loads `url` and, with `presentsWindow`, brings the window and the app to the front.
    public func openStream(
        url: URL,
        title: String? = nil,
        artworkData: Data? = nil,
        artworkURL: URL? = nil,
        headers: [String: String] = [:],
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil,
        actionButtons: [PlaybackActionButton] = [],
        trackNavigation: TrackNavigation = TrackNavigation(),
        presentsWindow: Bool = true
    ) {
        engine.load(
            MediaLoadRequest(
                path: MediaOpenRequest.loadPath(for: url),
                title: title,
                artworkData: artworkData,
                artworkURL: artworkURL,
                headers: headers,
                startTime: startTime,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack,
                actionButtons: actionButtons,
                trackNavigation: trackNavigation
            ))
        updateTrafficLightsVisibility(isVisible: true)
        guard presentsWindow else { return }

        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        onKeyStatusChanged?(true)
    }

    /// The window's title follows the media's, which a load sets late for a playlist file and refines from the
    /// container's metadata or a resolver. Re-registered after every change, as `withObservationTracking` reports one.
    private func observeMediaTitle() {
        window?.title = engine.mediaTitle.isEmpty ? "Nits" : engine.mediaTitle
        withObservationTracking {
            _ = engine.mediaTitle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeMediaTitle() }
        }
    }

    public func exitFullscreen() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    public override func cancelOperation(_ sender: Any?) {
        if window?.styleMask.contains(.fullScreen) == true {
            exitFullscreen()
        } else {
            super.cancelOperation(sender)
        }
    }

    private func updateTrafficLightsVisibility(isVisible: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for button in standardButtons {
                button.animator().alphaValue = isVisible ? 1.0 : 0.0
            }
        }
    }

    private func updateToolbar(isFullscreen: Bool) {
        guard let window else { return }
        if isFullscreen {
            window.toolbar = nil
        } else {
            let toolbar = NSToolbar()
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        onKeyStatusChanged?(true)
        nowPlayingController.isKeyWindow = true
    }

    public func windowDidResignKey(_ notification: Notification) {
        onKeyStatusChanged?(false)
        nowPlayingController.isKeyWindow = false
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        updateToolbar(isFullscreen: true)
        window?.titleVisibility = .visible
        window?.titlebarAppearsTransparent = false
        uiState.isFullscreen = true
        for button in standardButtons {
            button.alphaValue = 1.0
        }
    }

    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        updateToolbar(isFullscreen: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        uiState.isFullscreen = false
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        window?.titleVisibility = .hidden
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        updateToolbar(isFullscreen: false)
        window?.titlebarAppearsTransparent = true
        uiState.isFullscreen = false
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        guard entersPictureInPictureOnMinimize, engine.media.hasVideo, engine.isPlaying, !pictureInPicture.isActive
        else { return }
        isPictureInPictureFromMinimize = true
        pictureInPicture.toggle()
    }

    /// Restoring from the Dock reports the window visible before the restore animation ends; stopping PiP here keeps
    /// it from mirroring the layer while the animation distorts it. `windowDidDeminiaturize` stays as a fallback.
    public func windowDidChangeOcclusionState(_ notification: Notification) {
        guard isPictureInPictureFromMinimize, window?.occlusionState.contains(.visible) == true else { return }
        AppLog.debug(.ui, "Player window visible again; leaving minimize-started Picture in Picture")
        windowDidDeminiaturize(notification)
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        finishPictureInPictureRestore()
        guard isPictureInPictureFromMinimize else { return }
        isPictureInPictureFromMinimize = false
        if pictureInPicture.isActive {
            pictureInPicture.toggle()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        let finalTime = engine.currentTime
        let finalDuration = engine.media.duration
        AppLog.info(
            .ui,
            "Player window closing for: '\(engine.mediaTitle)' at \(String(format: "%.2f", finalTime))s / \(String(format: "%.2f", finalDuration))s"
        )
        onClose?(finalTime, finalDuration)
        // Stopping PiP below must not bring the closing window back.
        isWindowClosing = true
        isWindowHiddenForPictureInPicture = false
        finishPictureInPictureRestore()
        if pictureInPicture.isActive {
            pictureInPicture.toggle()
        }
        nowPlayingController.clear()
        engine.stop()
    }
}

extension PlayerWindowController: PlayerActions {
    public var renderMode: RenderMode {
        get { engine.renderMode }
        set {
            engine.renderMode = newValue
            // uiState.showControlsTemporarily()
            if engine.enableOSD {
                uiState.osd.show(.renderMode(modeName: newValue.rawValue))
            }
        }
    }

    public var metalSharpness: Float {
        get { engine.toneMapping.sharpness }
        set {
            engine.toneMapping.sharpness = newValue
            if engine.enableOSD {
                uiState.osd.show(.sharpness(value: newValue))
            }
        }
    }

    public var isMuted: Bool {
        engine.isMuted
    }

    public var showDebugHUD: Bool {
        engine.showDebugHUD
    }

    public var seekStepSeconds: Double {
        engine.seekStepSeconds
    }

    public func togglePlayPause() {
        engine.togglePlayPause()
        // uiState.showControlsTemporarily()
        if engine.enableOSD {
            uiState.osd.show(engine.isPlaying ? .play : .pause)
        }
    }

    public func play() {
        engine.play()
        if engine.enableOSD {
            uiState.osd.show(.play)
        }
    }

    public func pause() {
        engine.pause()
        if engine.enableOSD {
            uiState.osd.show(.pause)
        }
    }

    public func seek(to seconds: Double) {
        let offset = seconds - engine.currentTime
        engine.seek(to: seconds)
        if engine.enableOSD {
            uiState.osd.show(.seek(offsetSeconds: offset, currentTime: seconds, duration: engine.media.duration))
        }
    }

    public func stepFrameForward() {
        engine.stepFrameForward()
        if engine.enableOSD {
            uiState.osd.show(.frameStep(forward: true))
        }
    }

    public func stepFrameBackward() {
        engine.stepFrameBackward()
        if engine.enableOSD {
            uiState.osd.show(.frameStep(forward: false))
        }
    }

    public func seekRelative(by seconds: Double) {
        let honestOffset = engine.seekRelative(by: seconds)
        if engine.enableOSD {
            let targetPos = engine.pendingSeekTime ?? engine.currentTime
            uiState.osd.show(
                .seek(offsetSeconds: honestOffset, currentTime: targetPos, duration: engine.media.duration)
            )
        }
    }

    public func stepVolume(by delta: Float) {
        engine.stepVolume(by: delta)
        if engine.enableOSD {
            uiState.osd.show(.volume(level: engine.volume, isMuted: engine.isMuted))
        }
    }

    public func toggleMute() {
        engine.toggleMute()
        if engine.enableOSD {
            uiState.osd.show(.volume(level: engine.volume, isMuted: engine.isMuted))
        }
    }

    public var playbackRate: Double {
        get { engine.playbackRate }
        set { setPlaybackRate(newValue) }
    }

    public func setPlaybackRate(_ rate: Double) {
        engine.setPlaybackRate(rate)
        if engine.enableOSD {
            uiState.osd.show(.playbackRate(rate: engine.playbackRate))
        }
    }

    public func stepPlaybackRate(by delta: Double) {
        engine.stepPlaybackRate(by: delta)
        if engine.enableOSD {
            uiState.osd.show(.playbackRate(rate: engine.playbackRate))
        }
    }

    public func resetPlaybackRate() {
        engine.resetPlaybackRate()
        if engine.enableOSD {
            uiState.osd.show(.playbackRate(rate: engine.playbackRate))
        }
    }

    public func stepSubtitleDelay(by delta: Double) {
        guard engine.isLoaded else { return }
        engine.subtitles.stepDelay(by: delta)
        if engine.enableOSD {
            uiState.osd.show(.subtitleDelay(seconds: engine.subtitles.delay))
        }
    }

    public func stepAudioDelay(by delta: Double) {
        guard engine.isLoaded, !engine.audioTracks.isEmpty else { return }
        engine.stepAudioDelay(by: delta)
        if engine.enableOSD {
            uiState.osd.show(.audioDelay(seconds: engine.audioDelay))
        }
    }

    public var hasVideo: Bool {
        engine.media.hasVideo
    }

    public var videoGeometry: VideoGeometrySettings {
        engine.videoGeometry
    }

    public func setVideoAspectRatio(_ ratio: RationalAspectRatio?) {
        guard engine.media.hasVideo else { return }
        engine.setVideoAspectRatio(ratio)
        showGeometryOSD(
            symbol: "aspectratio", "Aspect Ratio: \(engine.videoGeometry.aspectRatio?.displayName ?? "Default")")
    }

    public func setVideoCrop(_ ratio: RationalAspectRatio?) {
        guard engine.media.hasVideo else { return }
        engine.setVideoCrop(ratio)
        showGeometryOSD(symbol: "crop", "Crop: \(engine.videoGeometry.crop?.displayName ?? "None")")
    }

    public func setVideoScaling(_ scaling: VideoScaling) {
        guard engine.media.hasVideo else { return }
        engine.setVideoScaling(scaling)
        showGeometryOSD(symbol: "arrow.up.left.and.arrow.down.right", "Scaling: \(engine.videoGeometry.scaling.title)")
    }

    public func cycleVideoAspectRatio() {
        setVideoAspectRatio(RationalAspectRatio.nextDisplayPreset(after: engine.videoGeometry.aspectRatio))
    }

    public func cycleVideoScaling() {
        setVideoScaling(engine.videoGeometry.scaling.next)
    }

    public func stepVideoZoom(by steps: Int) {
        guard engine.media.hasVideo else { return }
        engine.stepVideoZoom(by: steps)
        showZoomOSD()
    }

    public func resetVideoZoom() {
        guard engine.media.hasVideo else { return }
        engine.resetVideoZoom()
        showZoomOSD()
    }

    private func showZoomOSD() {
        let zoom = engine.videoGeometry.zoom
        showGeometryOSD(
            symbol: zoom == 1 ? "magnifyingglass" : zoom < 1 ? "minus.magnifyingglass" : "plus.magnifyingglass",
            "Zoom: \(Int((zoom * 100).rounded()))%")
    }

    public func captureFrame() {
        guard engine.media.hasVideo else { return }
        let title = engine.mediaTitle
        Task { @MainActor [weak self] in
            guard let self else { return }
            // HDR the display layer maps to the screen itself: what it shows, from the screen.
            if engine.activeRenderMode == .system, engine.media.video.isHDR, let window,
                let host = Self.videoHostView(in: window.contentView), !host.presentedVideoRect.isEmpty
            {
                await captureScreenStill(
                    window: window, videoRect: host.convert(host.presentedVideoRect, to: nil), title: title)
                return
            }
            guard let frame = await engine.captureFrame() else {
                showGeometryOSD(symbol: "exclamationmark.triangle", "Can't capture the frame")
                return
            }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try FrameStillWriter.write(frame, title: title)
                }.value
                if engine.enableOSD {
                    uiState.osd.show(
                        .custom(
                            symbol: "camera", text: frame.isHDR ? "HDR Screenshot Saved" : "Screenshot Saved",
                            subtext: url.lastPathComponent))
                }
            } catch {
                AppLog.error(.ui, "Saving the screenshot failed: \(error)")
                showGeometryOSD(symbol: "exclamationmark.triangle", "Can't save the screenshot")
            }
        }
    }

    /// Saves `videoRect` of `window` as the screen shows it (`PresentedFrameCapture`), with the overlays hidden while it
    /// is read.
    private func captureScreenStill(window: NSWindow, videoRect: CGRect, title: String) async {
        let pts = engine.currentFramePTS
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { uiState.isCapturingScreen = true }
        // The window redraws without the overlays in a frame or two.
        try? await Task.sleep(for: .milliseconds(80))
        let still: CapturedFrame
        do {
            let heic = try await PresentedFrameCapture.capture(window: window, videoRect: videoRect)
            still = CapturedFrame(data: heic, contentType: .heic, pts: pts, isHDR: true)
            withTransaction(instant) { uiState.isCapturingScreen = false }
        } catch {
            withTransaction(instant) { uiState.isCapturingScreen = false }
            AppLog.error(.ui, "Capturing the screen failed: \(error)")
            let declined = (error as? SCStreamError)?.code == .userDeclined
            showGeometryOSD(
                symbol: "exclamationmark.triangle",
                declined ? "Allow Screen Recording for Nits to capture HDR" : "Can't capture the screen")
            return
        }
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try FrameStillWriter.write(still, title: title)
            }.value
            if engine.enableOSD {
                uiState.osd.show(
                    .custom(symbol: "camera", text: "Screen Capture Saved", subtext: url.lastPathComponent))
            }
        } catch {
            AppLog.error(.ui, "Saving the screen capture failed: \(error)")
            showGeometryOSD(symbol: "exclamationmark.triangle", "Can't save the screenshot")
        }
    }

    /// The view the picture is drawn in, found in the SwiftUI hierarchy under `view`.
    private static func videoHostView(in view: NSView?) -> NativeVideoHostView? {
        guard let view else { return nil }
        if let host = view as? NativeVideoHostView { return host }
        for subview in view.subviews {
            if let host = videoHostView(in: subview) { return host }
        }
        return nil
    }

    private func showGeometryOSD(symbol: String, _ text: String) {
        if engine.enableOSD {
            uiState.osd.show(.custom(symbol: symbol, text: text))
        }
    }

    public func toggleDebugHUD() {
        withAnimation {
            engine.toggleDebugHUD()
        }
    }

    public func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    public var isPictureInPictureActive: Bool {
        engine.isPictureInPictureActive
    }

    public var canTogglePictureInPicture: Bool {
        engine.media.hasVideo && (uiState.isPictureInPicturePossible || engine.isPictureInPictureActive)
    }

    public func togglePictureInPicture() {
        guard canTogglePictureInPicture else { return }
        pictureInPicture.toggle()
    }

    private func makePictureInPictureController() -> PictureInPictureController {
        let pip = PictureInPictureController(engine: engine)
        pip.onPossibleChanged = { [weak self] isPossible in
            self?.uiState.isPictureInPicturePossible = isPossible
        }
        pip.onActiveChanged = { [weak self] isActive in
            guard let self else { return }
            if isActive {
                if self.pausesOnPictureInPicture, self.engine.isPlaying {
                    self.engine.pause()
                }
                self.moveWindowAsideForPictureInPicture()
            } else {
                self.isPictureInPictureFromMinimize = false
                self.bringWindowBackAfterPictureInPicture()
            }
        }
        pip.onRestoreUserInterface = { [weak self] windowReady in
            guard let self, !self.isWindowClosing, let window = self.window else {
                windowReady()
                return
            }
            self.isPictureInPictureFromMinimize = false
            self.bringWindowBackAfterPictureInPicture()
            NSApp.activate()
            guard window.isMiniaturized else {
                window.makeKeyAndOrderFront(nil)
                windowReady()
                return
            }
            // PiP waits until the Dock restore animation is over, or it would animate into a window that is
            // still flying out of the Dock.
            self.pendingPictureInPictureRestore = windowReady
            window.deminiaturize(nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.finishPictureInPictureRestore()
            }
        }
        return pip
    }

    /// Lets PiP animate into the window; runs once, from `windowDidDeminiaturize` or the fallback timeout.
    private func finishPictureInPictureRestore() {
        guard let windowReady = pendingPictureInPictureRestore else { return }
        pendingPictureInPictureRestore = nil
        window?.makeKeyAndOrderFront(nil)
        windowReady()
    }

    private func moveWindowAsideForPictureInPicture() {
        // Fullscreen and minimized windows are left alone, as in IINA.
        guard pictureInPictureWindowBehavior == .hide, let window, !window.styleMask.contains(.fullScreen),
            !window.isMiniaturized
        else { return }
        isWindowHiddenForPictureInPicture = true
        window.orderOut(nil)
    }

    private func bringWindowBackAfterPictureInPicture() {
        guard let window, isWindowHiddenForPictureInPicture, !isWindowClosing else { return }
        isWindowHiddenForPictureInPicture = false
        window.makeKeyAndOrderFront(nil)
    }

    public var canJumpToTime: Bool {
        engine.isLoaded && engine.media.duration > 0
    }

    public var isJumpToPresented: Bool {
        uiState.isJumpToPresented
    }

    public var isQuickSettingsPresented: Bool {
        uiState.isQuickSettingsPresented
    }

    public var isPlaylistPresented: Bool {
        uiState.isPlaylistPresented
    }

    public var isPlaylistAvailable: Bool {
        uiState.isPlaylistAvailable
    }

    public var isSidePanelPresented: Bool {
        uiState.sidePanel != nil
    }

    public var hasNextTrack: Bool {
        engine.canPlayNext
    }

    public var hasPreviousTrack: Bool {
        engine.canPlayPrevious
    }

    public func toggleQuickSettings() {
        withAnimation(.spring(duration: 0.25)) {
            uiState.toggleQuickSettings()
        }
    }

    public func togglePlaylist() {
        withAnimation(.spring(duration: 0.25)) {
            uiState.togglePlaylist()
        }
    }

    public func closeSidePanel() {
        withAnimation(.spring(duration: 0.25)) {
            uiState.sidePanel = nil
        }
    }

    public func playNextTrack() {
        uiState.osd.showTrackChange(to: engine.playNext(), isNext: true)
    }

    public func playPreviousTrack() {
        uiState.osd.showTrackChange(to: engine.playPrevious(), isNext: false)
    }

    public var isActionButtonVisible: Bool {
        uiState.actionButton.isVisible
    }

    public func pressActionButton() {
        guard isActionButtonVisible, let button = uiState.actionButton.press() else { return }
        engine.performActionButton(button)
    }

    public func dismissActionButton() {
        withAnimation(.easeInOut(duration: 0.2)) {
            uiState.actionButton.dismiss()
        }
    }

    public var hasChapters: Bool {
        engine.isLoaded && !engine.media.chapters.isEmpty
    }

    public var isChaptersPresented: Bool {
        uiState.isChaptersPresented
    }

    public func toggleChapters() {
        guard hasChapters else { return }
        withAnimation(.spring(duration: 0.25)) {
            uiState.toggleChapters()
        }
    }

    public func nextChapter() {
        guard hasChapters else { return }
        guard let chapter = engine.nextChapter() else {
            showChapterOSD(symbol: "forward.end", text: "Last Chapter")
            return
        }
        showChapterOSD(for: chapter, symbol: "forward.end.fill")
    }

    public func previousChapter() {
        guard hasChapters, let chapter = engine.previousChapter() else { return }
        showChapterOSD(for: chapter, symbol: "backward.end.fill")
    }

    private func showChapterOSD(for chapter: MediaChapter, symbol: String) {
        showChapterOSD(
            symbol: symbol,
            text: chapter.displayTitle,
            subtext:
                "Chapter \(chapter.id + 1) of \(engine.media.chapters.count) · \(TimeParser.format(seconds: chapter.start))"
        )
    }

    private func showChapterOSD(symbol: String, text: String, subtext: String? = nil) {
        guard engine.enableOSD else { return }
        uiState.osd.show(.custom(symbol: symbol, text: text, subtext: subtext))
    }

    public func promptJumpToTime() {
        guard canJumpToTime else { return }
        if uiState.isJumpToPresented {
            dismissJumpToTime()
        } else {
            let wasPlaying = engine.isPlaying
            if wasPlaying {
                engine.pause()
            }
            withAnimation(.spring(duration: 0.25)) {
                uiState.showJumpTo(wasPlaying: wasPlaying)
            }
        }
    }

    public func dismissJumpToTime() {
        guard uiState.isJumpToPresented else { return }
        let shouldResume = uiState.dismissJumpTo()
        withAnimation(.spring(duration: 0.25)) {
            uiState.isJumpToPresented = false
        }
        if shouldResume {
            engine.play()
        }
    }
}
