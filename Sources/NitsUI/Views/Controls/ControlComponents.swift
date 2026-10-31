import AppKit
import NitsCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Play / Pause Button
public struct ControlPlayPauseButton: View {
    @Bindable var engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
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
        .help("Play / Pause (Space)")
    }
}

// MARK: - Seek Relative Button
public struct ControlSeekRelativeButton: View {
    let engine: PlayerEngine
    let isForward: Bool

    public init(engine: PlayerEngine, isForward: Bool) {
        self.engine = engine
        self.isForward = isForward
    }

    public var body: some View {
        Button {
            let step = isForward ? engine.seekStepSeconds : -engine.seekStepSeconds
            engine.seekRelative(by: step)
        } label: {
            Image(systemName: isForward ? "goforward" : "gobackward")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.all, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isForward ? "Seek Forward (→)" : "Seek Backward (←)")
    }
}

// MARK: - Playlist Navigation Button
public struct ControlPlaylistNavButton: View {
    let engine: PlayerEngine
    let isNext: Bool
    /// Shows where the press went, as the menu and media keys do.
    var osd: OSDManager?

    public init(engine: PlayerEngine, isNext: Bool, osd: OSDManager? = nil) {
        self.engine = engine
        self.isNext = isNext
        self.osd = osd
    }

    public var body: some View {
        let isEnabled = isNext ? engine.canPlayNext : engine.canPlayPrevious
        Button {
            let title = isNext ? engine.playNext() : engine.playPrevious()
            osd?.showTrackChange(to: title, isNext: isNext)
        } label: {
            Image(systemName: isNext ? "forward.end.fill" : "backward.end.fill")
                .font(.system(size: 14))
                .foregroundStyle(isEnabled ? .white.opacity(0.85) : .white.opacity(0.3))
                .padding(.all, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isNext ? "Next Track (⌘→)" : "Previous Track (⌘←)")
    }
}

// MARK: - Volume Control
public struct ControlVolumeSlider: View {
    @Bindable var engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
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
            .help(engine.isMuted ? "Unmute (M)" : "Mute (M)")
            .accessibilityLabel(engine.isMuted ? "Unmute audio" : "Mute audio")

            Slider(value: $engine.volume, in: 0.0...1.0)
                .frame(width: 75)
                .help("Volume: \(Int(round(engine.volume * 100)))%")
                .accessibilityLabel("Volume slider")
                .accessibilityValue("\(Int(round(engine.volume * 100))) percent")
        }
        .padding(.all, 7)
    }
}

// MARK: - Audio Track Selector
public struct ControlAudioTrackButton: View {
    let engine: PlayerEngine
    let uiState: PlayerUIState?

    public init(engine: PlayerEngine, uiState: PlayerUIState?) {
        self.engine = engine
        self.uiState = uiState
    }

    public var body: some View {
        // A picture without audio can still take an audio file.
        if !engine.audioTracks.isEmpty || (engine.isLoaded && engine.media.hasVideo) {
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
    }

    private func showAudioTrackMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for track in engine.audioTracks {
            let label = TrackTitleFormatter.format(
                title: track.title, language: track.language, fallbackId: track.id + 1)
            let item = NSMenuItem(
                title: "\(label) (\(track.codecName), \(track.channels)ch)",
                action: #selector(ControlMenuHelper.executeAction(_:)),
                keyEquivalent: ""
            )
            item.state = (track.id == engine.selectedAudioTrackId) ? NSControl.StateValue.on : NSControl.StateValue.off
            let target = ControlMenuHelper { [weak engine, weak uiState] in
                engine?.selectAudioTrack(id: track.id)
                uiState?.osd.show(.audioTrack(title: label))
            }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        if !engine.audioTracks.isEmpty { menu.addItem(NSMenuItem.separator()) }
        let loadExternalItem = NSMenuItem(
            title: "Load Audio File...",
            action: #selector(ControlMenuHelper.executeAction(_:)),
            keyEquivalent: ""
        )
        let loadTarget = ControlMenuHelper { [weak engine, weak uiState] in
            AudioFilePicker.pick { url in
                Task {
                    // The track chosen once the file opened, not the file asked for: it may not be read.
                    guard let track = await engine?.loadExternalAudio(urls: [url]) else {
                        return
                    }
                    let label = TrackTitleFormatter.format(
                        title: track.title, language: track.language, fallbackId: track.id + 1)
                    uiState?.osd.show(.audioTrack(title: label))
                }
            }
        }
        loadExternalItem.target = loadTarget
        loadExternalItem.representedObject = loadTarget
        menu.addItem(loadExternalItem)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Subtitle Track Selector
public struct ControlSubtitleTrackButton: View {
    let engine: PlayerEngine
    let uiState: PlayerUIState?

    public init(engine: PlayerEngine, uiState: PlayerUIState?) {
        self.engine = engine
        self.uiState = uiState
    }

    public var body: some View {
        Button {
            showSubtitleTrackMenu()
        } label: {
            Image(
                systemName: engine.subtitles.selectedTrackId != nil
                    ? "captions.bubble.fill"
                    : "captions.bubble"
            )
            .font(.system(size: 19))
            .foregroundStyle(
                engine.subtitles.selectedTrackId != nil
                    ? Color.accentColor
                    : Color.white.opacity(0.85)
            )
            .padding(.all, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Select Subtitles")
    }

    private func showSubtitleTrackMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // "Off" option
        let offItem = NSMenuItem(
            title: "Off",
            action: #selector(ControlMenuHelper.executeAction(_:)),
            keyEquivalent: ""
        )
        offItem.state = (engine.subtitles.selectedTrackId == nil) ? NSControl.StateValue.on : NSControl.StateValue.off
        let offTarget = ControlMenuHelper { [weak engine, weak uiState] in
            engine?.subtitles.select(trackId: nil)
            uiState?.osd.show(.subtitleTrack(title: "Subtitles Off"))
        }
        offItem.target = offTarget
        offItem.representedObject = offTarget
        menu.addItem(offItem)

        if !engine.subtitles.tracks.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for track in engine.subtitles.tracks {
                let label = TrackTitleFormatter.format(
                    title: track.title, language: track.language, fallbackId: track.id + 1)
                let item = NSMenuItem(
                    title: label,
                    action: #selector(ControlMenuHelper.executeAction(_:)),
                    keyEquivalent: ""
                )
                item.state =
                    (track.id == engine.subtitles.selectedTrackId) ? NSControl.StateValue.on : NSControl.StateValue.off
                let target = ControlMenuHelper { [weak engine, weak uiState] in
                    engine?.subtitles.select(trackId: track.id)
                    uiState?.osd.show(.subtitleTrack(title: label))
                }
                item.target = target
                item.representedObject = target
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let loadExternalItem = NSMenuItem(
            title: "Load Subtitle File...",
            action: #selector(ControlMenuHelper.executeAction(_:)),
            keyEquivalent: ""
        )
        let loadTarget = ControlMenuHelper { [weak engine, weak uiState] in
            let panel = NSOpenPanel()
            panel.title = "Select Subtitle File"
            panel.allowedContentTypes = SidecarSubtitles.pickableExtensions.compactMap {
                UTType(filenameExtension: $0)
            }
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true

            let handleSelection: (NSApplication.ModalResponse) -> Void = { response in
                if response == .OK, let url = panel.url {
                    Task { @MainActor in
                        guard let engine, let osd = uiState?.osd else { return }
                        await SubtitleFileDrop.attach([url], to: engine, osd: osd)
                    }
                }
            }

            if let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: targetWindow, completionHandler: handleSelection)
            } else {
                panel.begin(completionHandler: handleSelection)
            }
        }
        loadExternalItem.target = loadTarget
        loadExternalItem.representedObject = loadTarget
        menu.addItem(loadExternalItem)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Playlist Toggle Button
public struct ControlPlaylistToggleButton: View {
    let uiState: PlayerUIState?

    public init(uiState: PlayerUIState?) {
        self.uiState = uiState
    }

    public var body: some View {
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
    }
}

// MARK: - Chapters Toggle Button
/// Opens the playlist panel on its chapters tab; shown only when the media has chapters.
public struct ControlChaptersToggleButton: View {
    let engine: PlayerEngine
    let uiState: PlayerUIState?

    public init(engine: PlayerEngine, uiState: PlayerUIState?) {
        self.engine = engine
        self.uiState = uiState
    }

    public var body: some View {
        if let uiState, !engine.media.chapters.isEmpty {
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    uiState.toggleChapters()
                }
            } label: {
                Image(systemName: "list.and.film")
                    .font(.system(size: 16))
                    .foregroundStyle(uiState.isChaptersPresented ? Color.accentColor : Color.white.opacity(0.85))
                    .padding(.all, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Chapters (⌥⌘C / C)")
        }
    }
}

// MARK: - Picture in Picture Toggle Button
public struct ControlPictureInPictureButton: View {
    let engine: PlayerEngine
    let uiState: PlayerUIState?

    public init(engine: PlayerEngine, uiState: PlayerUIState?) {
        self.engine = engine
        self.uiState = uiState
    }

    public var body: some View {
        // Observed properties first: a body that bails out before reading them would never be re-evaluated.
        if let uiState, engine.media.hasVideo, uiState.isPictureInPicturePossible || engine.isPictureInPictureActive,
            let toggle = uiState.togglePictureInPicture
        {
            Button {
                toggle()
            } label: {
                Image(systemName: engine.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.all, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Picture in Picture (⌃⌘P)")
        }
    }
}

// MARK: - Quick Settings Toggle Button
public struct ControlQuickSettingsToggleButton: View {
    let uiState: PlayerUIState?

    public init(uiState: PlayerUIState?) {
        self.uiState = uiState
    }

    public var body: some View {
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
}

// MARK: - Playlist Repeat Mode Button
public struct ControlPlaylistRepeatButton: View {
    let engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        Button {
            engine.playlist.cycleRepeatMode()
        } label: {
            Image(systemName: engine.playlist.repeatMode.iconName)
                .font(.system(size: 16))
                .foregroundStyle(
                    engine.playlist.repeatMode != .off
                        ? Color.accentColor
                        : Color.white.opacity(0.85)
                )
                .padding(.all, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engine.playlist.repeatMode.title)
    }
}

// MARK: - Playlist Shuffle Button
public struct ControlPlaylistShuffleButton: View {
    let engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        Button {
            engine.playlist.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 16))
                .foregroundStyle(
                    engine.playlist.isShuffled
                        ? Color.accentColor
                        : Color.white.opacity(0.85)
                )
                .padding(.all, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engine.playlist.isShuffled ? "Shuffle: On" : "Shuffle: Off")
    }
}

// MARK: - Timeline Section (Current Time + Scrub Bar + Duration)
public struct ControlTimelineSection: View {
    /// Coordinate space of the container the thumbnail preview may extend across.
    public static let previewBoundsSpace = "nits.timelinePreviewBounds"
    private static let previewEdgeMargin: CGFloat = 8
    private static let trackHeight: CGFloat = 18

    let engine: PlayerEngine
    let uiState: PlayerUIState?
    @Binding var isDragging: Bool
    @Binding var dragPosition: Double
    /// Width of the `previewBoundsSpace` container; `nil` keeps the preview within the slider.
    let previewBoundsWidth: CGFloat?

    @State private var isTimelineHovered: Bool = false
    @State private var timelineHoverLocation: CGPoint = .zero
    @State private var timelineHoverRatio: Double = 0

    public init(
        engine: PlayerEngine,
        uiState: PlayerUIState?,
        isDragging: Binding<Bool>,
        dragPosition: Binding<Double>,
        previewBoundsWidth: CGFloat? = nil
    ) {
        self.engine = engine
        self.uiState = uiState
        self._isDragging = isDragging
        self._dragPosition = dragPosition
        self.previewBoundsWidth = previewBoundsWidth
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Current time (clickable to jump to time)
            Text(TimeParser.format(seconds: isDragging ? dragPosition : engine.currentTime))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(minWidth: 48, alignment: .trailing)
                .padding(.trailing, 7)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard engine.isLoaded && engine.media.duration > 0, let uiState else { return }
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
                let total = max(engine.media.duration, 1)
                let current = isDragging ? dragPosition : engine.currentTime
                let progress = min(max(current / total, 0), 1)

                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.25))
                            .frame(height: 6)

                        // What a network source has read ahead of playback (half a minute at most); a local file's few
                        // seconds would only flicker. `bufferedTime` isn't observable, and grows while paused or
                        // buffering, when the time stands: read twice a second.
                        if engine.media.isNetworkSource {
                            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                                let buffered = min(max(engine.bufferedTime / total, 0), 1)
                                Capsule()
                                    .fill(.white.opacity(0.25))
                                    .frame(width: geo.size.width * max(buffered, progress), height: 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 6)
                        }

                        Capsule()
                            .fill(.tint)
                            .frame(width: geo.size.width * progress, height: 6)

                    }
                    .frame(height: 6)
                    .mask {
                        ChapterGapMask(chapters: engine.media.chapters, duration: engine.media.duration)
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, min(geo.size.width * progress - 7, geo.size.width - 14)))
                }
                .frame(height: Self.trackHeight)
                .overlay(alignment: .bottomLeading) {
                    if (isTimelineHovered || isDragging) && engine.media.duration > 0 {
                        let previewTime: Double =
                            isDragging ? dragPosition : (timelineHoverRatio * engine.media.duration)
                        let previewThumbnail = engine.thumbnailManager.thumbnail(at: previewTime)
                        let chapterTitle = ChapterNavigator.index(at: previewTime, in: engine.media.chapters)
                            .map { engine.media.chapters[$0].displayTitle }
                        let rawX: CGFloat = isDragging ? (progress * geo.size.width) : timelineHoverLocation.x
                        let clampedCursorX: CGFloat = min(max(rawX, 0), max(geo.size.width, 0))
                        let cardWidth = TimelineThumbnailPreviewView.size(
                            thumbnail: previewThumbnail,
                            duration: engine.media.duration,
                            hasChapterTitle: chapterTitle != nil,
                            geometry: engine.videoGeometry
                        ).width
                        // Allowed range for the card's leading edge, in slider coordinates.
                        let (minCardX, maxCardX): (CGFloat, CGFloat) = {
                            guard let boundsWidth = previewBoundsWidth, boundsWidth > 0 else {
                                return (0, geo.size.width - cardWidth)
                            }
                            let sliderMinX = geo.frame(in: .named(Self.previewBoundsSpace)).minX
                            let margin = Self.previewEdgeMargin
                            return (margin - sliderMinX, boundsWidth - margin - sliderMinX - cardWidth)
                        }()
                        let cardX: CGFloat = min(max(clampedCursorX - cardWidth / 2, minCardX), max(maxCardX, minCardX))

                        TimelineThumbnailPreviewView(
                            thumbnail: previewThumbnail,
                            time: previewTime,
                            duration: engine.media.duration,
                            chapterTitle: chapterTitle,
                            geometry: engine.videoGeometry
                        )
                        .fixedSize()
                        .offset(x: cardX, y: -31)
                        .zIndex(100)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                // Hover / click area spans the full row height; the track stays centred.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                            dragPosition = ratio * engine.media.duration
                            timelineHoverLocation = value.location
                            timelineHoverRatio = ratio
                        }
                        .onEnded { value in
                            let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                            let targetTime = ratio * engine.media.duration
                            engine.seek(to: targetTime)
                            isDragging = false
                            if value.location.y >= 0 && value.location.y <= geo.size.height {
                                isTimelineHovered = true
                                timelineHoverLocation = value.location
                                timelineHoverRatio = ratio
                            }
                        }
                )
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            // Fills the row when the container fixes its height (see `ControlsOverlay`).
            .frame(minHeight: Self.trackHeight, maxHeight: .infinity)
            .zIndex(10)

            // Total duration
            Text(TimeParser.format(seconds: engine.media.duration))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.all, 7)
                .frame(minWidth: 48, alignment: .leading)
        }
    }
}

// MARK: - Chapter Gap Mask
/// Mask for the timeline track: opaque everywhere except thin gaps at chapter boundaries (none at the very start),
/// so the gaps show whatever is behind the bar instead of a painted colour.
struct ChapterGapMask: View {
    let chapters: [MediaChapter]
    let duration: Double

    private static let gapWidth: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard duration > 0 else { return }
            context.blendMode = .destinationOut
            for chapter in chapters where chapter.start > 0 && chapter.start < duration {
                let x = size.width * chapter.start / duration
                let rect = CGRect(x: x - Self.gapWidth / 2, y: 0, width: Self.gapWidth, height: size.height)
                context.fill(Path(rect), with: .color(.black))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Menu Action Target Helper
@MainActor
final class ControlMenuHelper: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func executeAction(_ sender: Any?) {
        action()
    }
}
