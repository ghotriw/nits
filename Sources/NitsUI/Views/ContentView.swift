import AppKit
import NitsCore
import SwiftUI

public struct ContentView: View {
    public let engine: PlayerEngine
    public var uiState: PlayerUIState
    /// Opens what was dropped on the video or picked in the Open panel; `nil` opens it in the engine here.
    public var onOpenURLs: (([URL]) -> Void)?
    public var onControlsVisibilityChanged: ((Bool) -> Void)?
    public var onToggleFullscreen: (() -> Void)?

    @State private var isControlsVisible: Bool = true
    @State private var isUserInteracting: Bool = false
    /// The pointer is over the action button; holds the controls like hovering the control bar does.
    @State private var isActionButtonHovered: Bool = false
    /// The pointer is over one of the host's overlay buttons; holds the controls as the action button does.
    @State private var isOverlayButtonHovered: Bool = false
    @State private var hideTimer: Task<Void, Never>?
    /// Size of the video area, to turn drags into pan.
    @State private var videoAreaSize: CGSize = .zero
    /// Pan and zoom when the current drag or pinch began.
    @State private var panAtGestureStart: CGPoint?
    @State private var zoomAtGestureStart: Double?
    @Environment(\.displayScale) private var displayScale
    @FocusState private var isFocused: Bool

    @MainActor
    public init(
        engine: PlayerEngine,
        uiState: PlayerUIState = PlayerUIState(),
        onOpenURLs: (([URL]) -> Void)? = nil,
        onControlsVisibilityChanged: ((Bool) -> Void)? = nil,
        onToggleFullscreen: (() -> Void)? = nil
    ) {
        self.engine = engine
        self.uiState = uiState
        self.onOpenURLs = onOpenURLs
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onToggleFullscreen = onToggleFullscreen
    }

    public var body: some View {
        ZStack {
            // Video Surface View
            VideoSurfaceView(engine: engine) { urls in
                loadMedia(urls: urls)
            }
            .acceptsActivatingClick(movesWindowFromPicture)
            .ignoresSafeArea()
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                videoAreaSize = $0
            }
            // As on the header strip: the double click goes alongside the window's drag, so neither waits for the other.
            .gesture(WindowDragGesture(), including: movesWindowFromPicture ? .all : .subviews)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onToggleFullscreen?() },
                including: uiState.supportsFullscreen && onToggleFullscreen != nil ? .all : .subviews
            )
            .gesture(panGesture, including: canPanVideo ? .all : .subviews)
            .simultaneousGesture(zoomGesture, including: engine.media.hasVideo ? .all : .subviews)
            // The window moves from a drag of the picture while another window is key, as one movable by its background
            // does: the picture's AppKit view takes the activating click (`acceptsActivatingClick` above), and its
            // gestures handle it.
            .allowsWindowActivationEvents()

            // In audio-only mode, mask video layer with a solid black backdrop behind artwork. It lets the pointer
            // through to the video surface, whose gestures (moving the window, double click) stay the area's.
            if engine.isLoaded && !engine.media.hasVideo {
                Color.black
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                AudioOnlyArtworkView(engine: engine, isCompact: uiState.isCompact)
                    .allowsHitTesting(false)
            }

            LoadingOverlayView(engine: engine, isCompact: uiState.isCompact)

            // Error display banner if stream/file fails to load
            if let error = engine.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: uiState.isCompact ? 20 : 32))
                        .foregroundStyle(.yellow)
                    Text("Playback Error")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.system(size: uiState.isCompact ? 11 : 13))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(uiState.isCompact ? 3 : nil)
                        .padding(.horizontal, uiState.isCompact ? 4 : 24)
                }
                .padding(uiState.isCompact ? 10 : 20)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 12)
                .padding(.horizontal, uiState.isCompact ? 12 : 0)
            }

            // Subtitles Overlay
            SubtitleOverlayView(
                cues: engine.subtitles.textCues,
                images: engine.subtitles.images,
                fontSize: engine.subtitles.style.fontSize,
                textColor: Color(hex: engine.subtitles.style.textColorHex) ?? .white,
                backgroundColor: Color(hex: engine.subtitles.style.backgroundColorHex) ?? .black,
                backgroundOpacity: engine.subtitles.style.backgroundOpacity,
                fontName: engine.subtitles.style.fontName,
                fontWeight: engine.subtitles.style.fontWeight,
                letterSpacing: engine.subtitles.style.letterSpacing,
                outlineWidth: engine.subtitles.style.outlineWidth,
                videoWidth: engine.media.video.width,
                videoHeight: engine.media.video.height,
                sampleAspectRatio: engine.media.video.sampleAspectRatio,
                geometry: engine.videoGeometry,
                imageScale: engine.subtitles.effectiveScale,
                raise: engine.subtitles.authoredRaise,
                bottomMargin: engine.subtitles.raise,
                topMargin: engine.subtitles.secondary.inset,
                onRenderSizeChange: { engine.subtitles.renderSize = $0 }
            )
            .equatable()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(uiState.isCapturingScreen ? 0 : 1)

            // On-Screen Display (OSD) Overlay - Top Left, debug log badges stacked below
            let showsOSDEvent = uiState.osd.isVisible && uiState.osd.currentEvent != nil
            let showsDebugOSD = uiState.osd.isDebugEnabled && !uiState.osd.debugMessages.isEmpty
            if (showsOSDEvent || showsDebugOSD) && !uiState.isCapturingScreen {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 10) {
                            if showsOSDEvent, let event = uiState.osd.currentEvent {
                                OSDOverlayView(event: event)
                                    .transition(.opacity.animation(.easeInOut(duration: 0.16)))
                            }
                            if showsDebugOSD {
                                DebugOSDStackView(messages: uiState.osd.debugMessages)
                            }
                        }
                        .padding(.top, uiState.isCompact ? 12 : 28)
                        .padding(.leading, uiState.isCompact ? 12 : 28)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Performance Telemetry HUD
            if uiState.isDebugHUDVisible && !uiState.isCapturingScreen && !uiState.isCompact {
                VStack {
                    HStack {
                        Spacer()
                        PerformanceHUDView(engine: engine)
                            .padding(.top, 28)
                            .padding(.trailing, 28)
                    }
                    Spacer()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }

            // Clicking the video closes an open side panel. Sits below the controls so they stay
            // usable while a panel is open. Single tap only: pairing it with a double tap would delay
            // the close by the system double-click interval.
            if uiState.sidePanel != nil {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeSidePanel()
                    }
                    // It covers the picture: a drag of it moves the window as one of the picture does.
                    .gesture(WindowDragGesture(), isEnabled: uiState.movesWindow && !uiState.isFullscreen)
            }

            // Host overlay buttons (a like, a close) - Top Trailing and Bottom Leading. Below the controls, so what rises
            // from the control bar (the timeline's preview) stays over them.
            if !uiState.overlayButtons.isEmpty && !uiState.isCapturingScreen {
                PlayerOverlayButtonsView(
                    uiState: uiState,
                    areControlsVisible: showsControls,
                    trailingInset: uiState.sidePanel?.width ?? 0,
                    isHovered: $isOverlayButtonHovered
                )
                .ignoresSafeArea()
            }

            // Controls Overlay
            if showsControls && uiState.isCompact {
                CompactControlsOverlay(engine: engine, isInteracting: $isUserInteracting)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            } else if showsControls {
                ControlsOverlay(
                    engine: engine,
                    uiState: uiState,
                    isInteracting: $isUserInteracting,
                    isFullscreen: uiState.isFullscreen,
                    trailingInset: uiState.sidePanel?.width ?? 0
                ) {
                    openFileDialog()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // Host action button ("Skip Intro") - Bottom Trailing, above the control bar
            PlaybackActionButtonView(
                engine: engine,
                presenter: uiState.actionButton,
                areControlsVisible: showsControls,
                trailingInset: uiState.sidePanel?.width ?? 0,
                isCompact: uiState.isCompact,
                isHovered: $isActionButtonHovered
            )
            .ignoresSafeArea()
            .opacity(uiState.isCapturingScreen ? 0 : 1)

            // Jump to Time Dialog Overlay
            if uiState.isJumpToPresented {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            let shouldResume = uiState.dismissJumpTo()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                uiState.isJumpToPresented = false
                            }
                            if shouldResume {
                                engine.play()
                            }
                        }

                    JumpToTimeView(
                        currentTime: engine.currentTime,
                        duration: engine.media.duration,
                        onJump: { targetTime in
                            let offset = targetTime - engine.currentTime
                            engine.seek(to: targetTime)
                            uiState.osd.show(.seek(offsetSeconds: offset, at: targetTime, of: engine))
                            let shouldResume = uiState.dismissJumpTo()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                uiState.isJumpToPresented = false
                            }
                            if shouldResume {
                                engine.play()
                            }
                        },
                        onCancel: {
                            let shouldResume = uiState.dismissJumpTo()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                uiState.isJumpToPresented = false
                            }
                            if shouldResume {
                                engine.play()
                            }
                        }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(100)
            }

            // Side Panel - Trailing Edge. Switching panels swaps the content in place; only
            // opening and closing slide.
            ZStack(alignment: .trailing) {
                if let panel = uiState.sidePanel {
                    SidePanelContainer(width: panel.width) {
                        sidePanelContent(panel)
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .ignoresSafeArea()
            .zIndex(90)
        }
        // A mini player is as small as the host makes it.
        .frame(minWidth: uiState.isCompact ? nil : 700, minHeight: uiState.isCompact ? nil : 450)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showControlsTemporarily()
            case .ended:
                break
            }
        }
        .onChange(of: isInteracting) { _, interacting in
            if interacting {
                hideTimer?.cancel()
                withAnimation { isControlsVisible = true }
            } else {
                scheduleControlsHide()
            }
        }
        // What has no room in a mini player closes as it becomes one; the side panel is closed by `PlayerUIState`.
        .onChange(of: uiState.isCompact) { _, compact in
            isUserInteracting = false
            // `PlayerUIState` closed Jump to Time; the playback it paused goes on.
            guard compact, uiState.wasPlayingBeforeJumpTo else { return }
            uiState.wasPlayingBeforeJumpTo = false
            engine.play()
        }
        .onChange(of: uiState.isJumpToPresented) { _, presented in
            if presented {
                hideTimer?.cancel()
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: uiState.sidePanel == nil) { _, closed in
            if closed {
                isFocused = true
                scheduleControlsHide()
            } else {
                // The panel and the controls beside it form one layout; keep both on screen.
                hideTimer?.cancel()
                withAnimation { isControlsVisible = true }
            }
        }
        .onChange(of: uiState.controlsConfig.isSettingsCustomizingControls) { _, customizing in
            if customizing {
                hideTimer?.cancel()
                withAnimation { isControlsVisible = true }
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: isControlsVisible) { _, visible in
            onControlsVisibilityChanged?(visible)
        }
        .onChange(of: uiState.controlsVisibilityTrigger) { _, _ in
            showControlsTemporarily()
        }
        // From the state, not the HUD's appear / disappear, which a fade out can deliver after the next appear.
        .onChange(of: uiState.isDebugHUDVisible && !uiState.isCompact, initial: true) { _, visible in
            engine.isCollectingMetrics = visible
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .defaultFocus($isFocused, uiState.sidePanel == nil && !uiState.isJumpToPresented)
        .onKeyPress(.escape) {
            guard uiState.sidePanel != nil else { return .ignored }
            closeSidePanel()
            return .handled
        }
        .onAppear {
            onControlsVisibilityChanged?(isControlsVisible)
        }
    }

    /// Where the picture sits in the video area, as `NativeVideoHostView` lays it out.
    private var videoLayout: VideoLayout {
        VideoGeometry.layout(
            viewSize: videoAreaSize,
            videoWidth: engine.media.video.width,
            videoHeight: engine.media.video.height,
            sampleAspectRatio: engine.media.video.sampleAspectRatio,
            settings: engine.videoGeometry,
            backingScale: displayScale
        )
    }

    /// The picture is larger than the view, so a drag moves it instead of the window.
    private var canPanVideo: Bool {
        engine.media.hasVideo && !engine.isPictureInPictureActive && videoLayout.panLimit != .zero
    }

    /// A drag of the picture moves the window (`PlayerUIState.movesWindow`), as the header strip's does, unless it pans
    /// the picture. The view does it itself rather than the window's `isMovableByWindowBackground`: in a host's
    /// window, its own content around the player cuts the background AppKit moves the window by into pieces.
    private var movesWindowFromPicture: Bool {
        uiState.movesWindow && !uiState.isFullscreen && !canPanVideo
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = panAtGestureStart ?? engine.videoGeometry.pan
                panAtGestureStart = start
                var geometry = engine.videoGeometry
                geometry.pan = start
                engine.setVideoPan(VideoGeometry.pan(geometry, movedBy: value.translation, in: videoLayout))
            }
            .onEnded { _ in panAtGestureStart = nil }
    }

    /// Trackpad pinch zooms the picture.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomAtGestureStart ?? engine.videoGeometry.zoom
                zoomAtGestureStart = start
                engine.setVideoZoom(start * value.magnification)
            }
            .onEnded { _ in
                zoomAtGestureStart = nil
                // A pinch that ends close to 1× lands on it, so the picture is exactly fit again.
                if abs(engine.videoGeometry.zoom - 1) < 0.04 { engine.setVideoZoom(1) }
            }
    }

    private var isInteracting: Bool {
        isUserInteracting || isActionButtonHovered || isOverlayButtonHovered
    }

    private var showsControls: Bool {
        guard !uiState.isCapturingScreen else { return false }
        return isControlsVisible || !engine.isLoaded || isInteracting
            || uiState.controlsConfig.isSettingsCustomizingControls
    }

    @ViewBuilder
    private func sidePanelContent(_ panel: PlayerSidePanel) -> some View {
        switch panel {
        case .playlist, .chapters:
            // One view for both tabs, so switching tabs keeps the panel's state.
            PlaylistOverlayView(engine: engine, uiState: uiState, tab: panel, onClose: closeSidePanel)
        case .quickSettings:
            QuickSettingsOverlayView(engine: engine, uiState: uiState, onClose: closeSidePanel)
        }
    }

    private func closeSidePanel() {
        withAnimation(.spring(duration: 0.25)) {
            uiState.sidePanel = nil
        }
    }

    private func showControlsTemporarily() {
        withAnimation {
            isControlsVisible = true
        }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        guard engine.isLoaded, !isInteracting, !uiState.isJumpToPresented, uiState.sidePanel == nil,
            !uiState.controlsConfig.isSettingsCustomizingControls
        else {
            return
        }
        hideTimer?.cancel()
        hideTimer = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled && !isInteracting && !uiState.isJumpToPresented
                && uiState.sidePanel == nil && !uiState.controlsConfig.isSettingsCustomizingControls
            {
                withAnimation {
                    isControlsVisible = false
                }
            }
        }
    }

    private func openFileDialog() {
        let urls = MediaOpenPanel.promptForMediaFiles()
        loadMedia(urls: urls)
    }

    private func loadMedia(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let onOpenURLs {
            onOpenURLs(urls)
        } else {
            Task {
                await MediaOpenRequest.resolving(urls, source: "Drop / open").open(in: engine, osd: uiState.osd)
            }
        }
        scheduleControlsHide()
    }
}

/// Shows a spinner while the media loads, buffers, or waits on a slow seek, isolated in its own view so seek and
/// buffering state changes do not re-evaluate `ContentView`.
private struct LoadingOverlayView: View {
    let engine: PlayerEngine
    var isCompact = false

    @State private var isSeekSpinnerVisible = false

    private var isSeekInFlight: Bool {
        engine.isSeeking || (isSeekSpinnerVisible && engine.isAwaitingClockStart)
    }

    var body: some View {
        ZStack {
            if (engine.isLoading || !engine.isLoaded || engine.isStartingPlayback || engine.isBuffering
                || isSeekSpinnerVisible)
                && engine.loadError == nil
            {
                ProgressView()
                    .controlSize(isCompact ? .regular : .large)
                    .tint(.white)
                    .padding(isCompact ? 10 : 16)
                    .background(.black.opacity(0.40), in: Circle())
                    .environment(\.colorScheme, .dark)
            }
        }
        .allowsHitTesting(false)
        .task(id: isSeekInFlight) {
            if isSeekInFlight {
                guard !isSeekSpinnerVisible else { return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, engine.isSeeking else { return }
                isSeekSpinnerVisible = true
            } else if isSeekSpinnerVisible {
                if engine.isPlaying {
                    // Covers two 50 ms ticks of the periodic time observer for `checkForStarvation()` to set `isBuffering`.
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, !isSeekInFlight else { return }
                }
                isSeekSpinnerVisible = false
            }
        }
        .onChange(of: engine.isLoading || engine.loadError != nil) { _, reset in
            if reset { isSeekSpinnerVisible = false }
        }
    }
}

/// What stands in for the picture of audio-only media: the artwork (or a waveform symbol), the title and the audio
/// track's format; a mini player shows the artwork alone, smaller.
private struct AudioOnlyArtworkView: View {
    let engine: PlayerEngine
    let isCompact: Bool

    var body: some View {
        VStack(spacing: 20) {
            if let artworkData = engine.artworkData, let nsImage = NSImage(data: artworkData) {
                let side: CGFloat = isCompact ? 120 : 280
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: side, maxHeight: side)
                    .clipShape(RoundedRectangle(cornerRadius: isCompact ? 10 : 16, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: isCompact ? 10 : 20, x: 0, y: isCompact ? 5 : 10)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: isCompact ? 56 : 110, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: isCompact ? 100 : 200, height: isCompact ? 80 : 160)
                    .shadow(color: .white.opacity(0.15), radius: 24, x: 0, y: 0)
            }

            if !isCompact {
                VStack(spacing: 6) {
                    Text(engine.mediaTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    if let format = audioFormatText {
                        Text(format)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(isCompact ? 12 : 32)
    }

    /// The selected audio track's codec, sample rate and channels.
    private var audioFormatText: String? {
        engine.audioTracks.first(where: { $0.id == engine.selectedAudioTrackId })?.formatSummary
    }
}
