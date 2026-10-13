import AppKit
import NitsCore
import SwiftUI
import UniformTypeIdentifiers

public struct ControlsOverlay: View {
    @Bindable var engine: PlayerEngine
    var uiState: PlayerUIState? = nil
    @Binding var isInteracting: Bool
    var isFullscreen: Bool = false
    var onOpenFile: () -> Void

    @State private var isDragging: Bool = false
    @State private var dragPosition: Double = 0
    @State private var isBottomHovered: Bool = false
    @State private var isTopHovered: Bool = false
    @State private var isTimelineHovered: Bool = false
    @State private var timelineHoverLocation: CGPoint = .zero
    @State private var timelineHoverRatio: Double = 0

    public var body: some View {
        VStack {
            // Top Header Bar: File title in line with traffic lights (windowed mode only)
            if !isFullscreen {
                HStack(spacing: 8) {
                    if !engine.mediaTitle.isEmpty {
                        Text(engine.mediaTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()
                }
                .frame(height: 40)
                // 78pt leading padding clears the three traffic lights (close, minimize, zoom)
                .padding(.leading, 78)
                .padding(.trailing, 20)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 1)
                }
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        (NSApp.keyWindow ?? NSApp.mainWindow)?.zoom(nil)
                    }
                )
                .allowsWindowActivationEvents()
                .onHover { hovering in
                    isTopHovered = hovering
                    updateInteractionState()
                }
            }

            Spacer()

            // Bottom Player Control Panel (Single row)
            HStack(spacing: 0) {

                // Previous Track
                Button {
                    engine.playPrevious()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(engine.playlist.hasPrevious ? .white.opacity(0.85) : .white.opacity(0.3))
                        .padding(.all, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!engine.playlist.hasPrevious)
                .help("Previous Track (⌘←)")

                // Seek backward
                Button {
                    engine.seekRelative(by: -engine.seekStepSeconds)
                } label: {
                    Image(systemName: "gobackward")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.all, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Seek Backward (←)")

                // Play / Pause
                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(.white)
                        .padding(.all, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Seek forward
                Button {
                    engine.seekRelative(by: engine.seekStepSeconds)
                } label: {
                    Image(systemName: "goforward")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.all, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Seek Forward (→)")

                // Next Track
                Button {
                    engine.playNext()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(engine.playlist.hasNext ? .white.opacity(0.85) : .white.opacity(0.3))
                        .padding(.all, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!engine.playlist.hasNext)
                .help("Next Track (⌘→)")

                // Current time (clickable to jump to time)
                Text(formatTime(isDragging ? dragPosition : engine.currentTime))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(minWidth: 48, alignment: .trailing)
                    .padding(.trailing, 7)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard engine.isLoaded && engine.duration > 0, let uiState else { return }
                        if uiState.isJumpToPresented {
                            let shouldResume = uiState.dismissJumpTo()
                            withAnimation(.spring(duration: 0.25)) {
                                uiState.isJumpToPresented = false
                            }
                            if shouldResume {
                                engine.play()
                            }
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
                    .help("Jump to Time (⌘J)")

                // Progress Bar with Keyframe Thumbnail Hover & Scrub Preview
                GeometryReader { geo in
                    let total = max(engine.duration, 1)
                    let current = isDragging ? dragPosition : engine.currentTime
                    let progress = min(max(current / total, 0), 1)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.25))
                            .frame(height: 6)

                        Capsule()
                            .fill(.tint)
                            .frame(width: geo.size.width * progress, height: 6)

                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .offset(x: max(0, min(geo.size.width * progress - 7, geo.size.width - 14)))
                    }
                    .frame(height: 18)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            isTimelineHovered = true
                            timelineHoverLocation = location
                            let ratio = min(max(location.x / max(geo.size.width, 1), 0), 1)
                            timelineHoverRatio = ratio
                        case .ended:
                            isTimelineHovered = false
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if (isTimelineHovered || isDragging) && engine.duration > 0 {
                            let previewTime: Double = isDragging ? dragPosition : (timelineHoverRatio * engine.duration)
                            let previewThumbnail = engine.thumbnailManager.thumbnail(at: previewTime)
                            let rawX: CGFloat = isDragging ? (progress * geo.size.width) : timelineHoverLocation.x
                            let clampedCursorX: CGFloat = min(max(rawX, 0), max(geo.size.width, 0))
                            let halfWidth: CGFloat = {
                                if previewThumbnail != nil {
                                    return 85
                                } else {
                                    return engine.duration >= 3600 ? 37 : 29
                                }
                            }()
                            let cardX: CGFloat = clampedCursorX - halfWidth

                            TimelineThumbnailPreviewView(
                                thumbnail: previewThumbnail,
                                time: previewTime,
                                duration: engine.duration
                            )
                            .fixedSize()
                            .offset(x: cardX, y: -31)
                            .zIndex(100)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                                dragPosition = ratio * engine.duration
                                timelineHoverLocation = value.location
                                timelineHoverRatio = ratio
                            }
                            .onEnded { value in
                                let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                                let targetTime = ratio * engine.duration
                                engine.seek(to: targetTime)
                                isDragging = false
                                if value.location.y >= -10 && value.location.y <= 28 {
                                    isTimelineHovered = true
                                    timelineHoverLocation = value.location
                                    timelineHoverRatio = ratio
                                }
                            }
                    )
                }
                .padding(.horizontal, 7)
                .frame(height: 18)
                .zIndex(10)

                // Total duration
                Text(formatTime(engine.duration))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.all, 7)
                    .frame(minWidth: 48, alignment: .leading)

                // Volume Control
                HStack(spacing: 6) {
                    Button {
                        engine.isMuted.toggle()
                    } label: {
                        Image(
                            systemName: engine.isMuted || engine.volume == 0
                                ? "speaker.slash.fill"
                                : (engine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 20, alignment: .leading)

                    Slider(value: $engine.volume, in: 0.0...1.0)
                        .frame(width: 75)
                }
                .padding(.all, 7)

                // Audio Track Selector
                if !engine.audioTracks.isEmpty {
                    Button {
                        showAudioTrackMenu()
                    } label: {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.all, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Select Audio Track")
                }

                // Subtitle Track Selector
                Button {
                    showSubtitleTrackMenu()
                } label: {
                    Image(
                        systemName: engine.selectedSubtitleTrackId != nil
                            ? "captions.bubble.fill"
                            : "captions.bubble"
                    )
                    .font(.system(size: 19))
                    .foregroundStyle(
                        engine.selectedSubtitleTrackId != nil
                            ? Color.accentColor
                            : Color.white.opacity(0.85)
                    )
                    .padding(.all, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Select Subtitles")

                // Playlist Toggle Button
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        uiState?.togglePlaylist()
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16))
                        .foregroundStyle(
                            uiState?.isPlaylistPresented == true
                                ? Color.accentColor
                                : Color.white.opacity(0.85)
                        )
                        .padding(.all, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Playlist (⌥⌘P / P)")

                // Quick Settings Toggle Button
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        uiState?.toggleQuickSettings()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17))
                        .foregroundStyle(
                            uiState?.isQuickSettingsPresented == true
                                ? Color.accentColor
                                : Color.white.opacity(0.85)
                        )
                        .padding(.all, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Quick Settings (⌥⌘S)")
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 1)
            }
            .onHover { hovering in
                isBottomHovered = hovering
                updateInteractionState()
            }
        }
        .ignoresSafeArea()
        .onChange(of: isDragging) { _, _ in
            updateInteractionState()
        }
        .onChange(of: isFullscreen) { _, fs in
            if fs {
                isTopHovered = false
                updateInteractionState()
            }
        }
    }

    private func updateInteractionState() {
        let topActive = !isFullscreen && isTopHovered
        isInteracting = isBottomHovered || topActive || isDragging
    }

    private func formatTime(_ seconds: Double) -> String {
        TimeParser.format(seconds: seconds)
    }

    private func showAudioTrackMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for track in engine.audioTracks {
            let label = formatTrackTitle(track)
            let item = NSMenuItem(
                title: "\(label) (\(track.codecName), \(track.channels)ch)",
                action: #selector(AudioTrackMenuHelper.selectTrack(_:)),
                keyEquivalent: ""
            )
            item.state = (track.id == engine.selectedAudioTrackId) ? .on : .off
            let target = AudioTrackMenuHelper { [weak engine, weak uiState] in
                engine?.selectAudioTrack(id: track.id)
                if engine?.enableOSD == true {
                    uiState?.osd.show(.audioTrack(title: label))
                }
            }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func showSubtitleTrackMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // "Off" option
        let offItem = NSMenuItem(
            title: "Off",
            action: #selector(AudioTrackMenuHelper.selectTrack(_:)),
            keyEquivalent: ""
        )
        offItem.state = (engine.selectedSubtitleTrackId == nil) ? .on : .off
        let offTarget = AudioTrackMenuHelper { [weak engine, weak uiState] in
            engine?.selectSubtitleTrack(id: nil)
            if engine?.enableOSD == true {
                uiState?.osd.show(.subtitleTrack(title: "Subtitles Off"))
            }
        }
        offItem.target = offTarget
        offItem.representedObject = offTarget
        menu.addItem(offItem)

        if !engine.subtitleTracks.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for track in engine.subtitleTracks {
                let item = NSMenuItem(
                    title: track.title,
                    action: #selector(AudioTrackMenuHelper.selectTrack(_:)),
                    keyEquivalent: ""
                )
                item.state = (track.id == engine.selectedSubtitleTrackId) ? .on : .off
                let target = AudioTrackMenuHelper { [weak engine, weak uiState] in
                    engine?.selectSubtitleTrack(id: track.id)
                    if engine?.enableOSD == true {
                        uiState?.osd.show(.subtitleTrack(title: track.title))
                    }
                }
                item.target = target
                item.representedObject = target
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let loadExternalItem = NSMenuItem(
            title: "Load Subtitle File...",
            action: #selector(AudioTrackMenuHelper.selectTrack(_:)),
            keyEquivalent: ""
        )
        let loadTarget = AudioTrackMenuHelper { [weak engine, weak uiState] in
            let panel = NSOpenPanel()
            panel.title = "Select Subtitle File"
            panel.allowedContentTypes = [
                UTType(filenameExtension: "srt"),
                UTType(filenameExtension: "vtt"),
            ].compactMap { $0 }
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            if panel.runModal() == .OK, let url = panel.url {
                engine?.loadExternalSubtitle(url: url)
                if engine?.enableOSD == true {
                    uiState?.osd.show(.subtitleTrack(title: url.lastPathComponent))
                }
            }
        }
        loadExternalItem.target = loadTarget
        loadExternalItem.representedObject = loadTarget
        menu.addItem(loadExternalItem)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func formatTrackTitle(_ track: MediaDemuxer.AudioTrack) -> String {
        if !track.title.isEmpty {
            return track.title
        }
        if !track.language.isEmpty {
            let loc = Locale.current
            if let localized = loc.localizedString(forLanguageCode: track.language) {
                return localized.capitalized
            }
            return track.language.uppercased()
        }
        return "Track \(track.id + 1)"
    }
}

@MainActor
final class AudioTrackMenuHelper: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func selectTrack(_ sender: Any?) {
        action()
    }
}
