import AppKit
import NitsCore
import SwiftUI

public struct ContentView: View {
    public let engine: PlayerEngine
    public var uiState: PlayerUIState
    public var onFileLoaded: ((URL) -> Void)?
    public var onControlsVisibilityChanged: ((Bool) -> Void)?
    public var onToggleFullscreen: (() -> Void)?

    @State private var isControlsVisible: Bool = true
    @State private var isUserInteracting: Bool = false
    @State private var hideTimer: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    @MainActor
    public init(
        engine: PlayerEngine,
        uiState: PlayerUIState = PlayerUIState(),
        onFileLoaded: ((URL) -> Void)? = nil,
        onControlsVisibilityChanged: ((Bool) -> Void)? = nil,
        onToggleFullscreen: (() -> Void)? = nil
    ) {
        self.engine = engine
        self.uiState = uiState
        self.onFileLoaded = onFileLoaded
        self.onControlsVisibilityChanged = onControlsVisibilityChanged
        self.onToggleFullscreen = onToggleFullscreen
    }

    public var body: some View {
        ZStack {
            // Video Surface View
            VideoSurfaceView(engine: engine) { filePath in
                let url = URL(fileURLWithPath: filePath)
                engine.load(path: filePath)
                onFileLoaded?(url)
                scheduleControlsHide()
            }
            .ignoresSafeArea()
            .onTapGesture(count: 2) {
                onToggleFullscreen?()
            }

            // In audio-only mode, mask video layer with a solid black backdrop behind artwork
            if engine.isLoaded && !engine.hasVideo {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    if let artworkData = engine.artworkData, let nsImage = NSImage(data: artworkData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 280, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 110, weight: .light))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 200, height: 160)
                            .shadow(color: .white.opacity(0.15), radius: 24, x: 0, y: 0)
                    }

                    VStack(spacing: 6) {
                        Text(engine.mediaTitle)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        if !engine.audioTracks.isEmpty,
                            let currentTrack = engine.audioTracks.first(where: { $0.id == engine.selectedAudioTrackId })
                        {
                            let kHz = Double(currentTrack.sampleRate) / 1000.0
                            let formattedRate =
                                kHz.truncatingRemainder(dividingBy: 1) == 0
                                ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)
                            Text(
                                "\(currentTrack.codecName.uppercased()) • \(formattedRate) kHz • \(currentTrack.channels) ch"
                            )
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .padding(32)
                .allowsHitTesting(false)
            }

            // Subtle loading indicator while engine is parsing/decoding first frame or buffering stream
            if (engine.isLoading || !engine.isLoaded) && engine.loadError == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .shadow(radius: 8)
            }

            // Error display banner if stream/file fails to load
            if let error = engine.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.yellow)
                    Text("Playback Error")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 12)
            }

            // Subtitles Overlay
            SubtitleOverlayView(
                cues: engine.currentSubtitleCues,
                fontSize: engine.subtitleFontSize,
                textColor: Color(hex: engine.subtitleTextColorHex) ?? .white,
                backgroundColor: Color(hex: engine.subtitleBgColorHex) ?? .black,
                backgroundOpacity: engine.subtitleBgOpacity,
                fontName: engine.subtitleFontName,
                fontWeight: engine.subtitleFontWeight,
                videoWidth: engine.videoWidth,
                videoHeight: engine.videoHeight
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // On-Screen Display (OSD) Overlay - Top Left
            if engine.enableOSD, uiState.osd.isVisible, let event = uiState.osd.currentEvent {
                VStack {
                    HStack {
                        OSDOverlayView(event: event)
                            .transition(.opacity.animation(.easeInOut(duration: 0.16)))
                            .padding(.top, 28)
                            .padding(.leading, 28)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Performance Telemetry HUD
            if engine.showDebugHUD {
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

            // Controls Overlay
            if isControlsVisible || !engine.isLoaded || isUserInteracting {
                ControlsOverlay(
                    engine: engine,
                    uiState: uiState,
                    isInteracting: $isUserInteracting,
                    isFullscreen: uiState.isFullscreen
                ) {
                    openFileDialog()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

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
                        duration: engine.duration,
                        onJump: { targetTime in
                            let offset = targetTime - engine.currentTime
                            engine.seek(to: targetTime)
                            if engine.enableOSD {
                                uiState.osd.show(
                                    .seek(offsetSeconds: offset, currentTime: targetTime, duration: engine.duration))
                            }
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

            // Quick Settings Overlay Drawer - Trailing Side
            if uiState.isQuickSettingsPresented {
                ZStack(alignment: .trailing) {
                    // Transparent backdrop covering the rest of the window
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.25)) {
                                uiState.isQuickSettingsPresented = false
                            }
                        }

                    QuickSettingsOverlayView(
                        engine: engine,
                        uiState: uiState,
                        onClose: {
                            withAnimation(.spring(duration: 0.25)) {
                                uiState.isQuickSettingsPresented = false
                            }
                        }
                    )
                    .transition(.move(edge: .trailing))
                }
                .ignoresSafeArea()
                .zIndex(90)
            }

            // Playlist Overlay Drawer - Trailing Side
            if uiState.isPlaylistPresented {
                ZStack(alignment: .trailing) {
                    // Transparent backdrop covering the rest of the window
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.25)) {
                                uiState.isPlaylistPresented = false
                            }
                        }

                    PlaylistOverlayView(
                        engine: engine,
                        uiState: uiState,
                        onClose: {
                            withAnimation(.spring(duration: 0.25)) {
                                uiState.isPlaylistPresented = false
                            }
                        }
                    )
                    .transition(.move(edge: .trailing))
                }
                .ignoresSafeArea()
                .zIndex(90)
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showControlsTemporarily()
            case .ended:
                break
            }
        }
        .onChange(of: isUserInteracting) { _, interacting in
            if interacting {
                hideTimer?.cancel()
                withAnimation { isControlsVisible = true }
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: uiState.isJumpToPresented) { _, presented in
            if presented {
                hideTimer?.cancel()
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: uiState.isQuickSettingsPresented) { _, presented in
            if presented {
                hideTimer?.cancel()
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: uiState.isPlaylistPresented) { _, presented in
            if presented {
                hideTimer?.cancel()
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
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .defaultFocus($isFocused, true)
        .onKeyPress(.escape) {
            if uiState.isPlaylistPresented {
                withAnimation(.spring(duration: 0.25)) {
                    uiState.isPlaylistPresented = false
                }
                return .handled
            }
            if uiState.isQuickSettingsPresented {
                withAnimation(.spring(duration: 0.25)) {
                    uiState.isQuickSettingsPresented = false
                }
                return .handled
            }
            return .ignored
        }
        .onAppear {
            onControlsVisibilityChanged?(isControlsVisible)
        }
    }

    private func showControlsTemporarily() {
        withAnimation {
            isControlsVisible = true
        }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        guard engine.isLoaded, !isUserInteracting, !uiState.isJumpToPresented, !uiState.isQuickSettingsPresented,
            !uiState.isPlaylistPresented
        else {
            return
        }
        hideTimer?.cancel()
        hideTimer = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled && !isUserInteracting && !uiState.isJumpToPresented
                && !uiState.isQuickSettingsPresented && !uiState.isPlaylistPresented
            {
                withAnimation {
                    isControlsVisible = false
                }
            }
        }
    }

    private func openFileDialog() {
        if let url = MediaOpenPanel.promptForMediaFile() {
            engine.load(path: url.path)
            onFileLoaded?(url)
            scheduleControlsHide()
        }
    }
}
