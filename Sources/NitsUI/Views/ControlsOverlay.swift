import AppKit
import NitsCore
import SwiftUI

public struct ControlsOverlay: View {
    @Bindable var engine: PlayerEngine
    var uiState: PlayerUIState? = nil
    @Binding var isInteracting: Bool
    var isFullscreen: Bool = false
    /// Width taken by an open side panel; the bars shrink to stay beside it rather than under it.
    var trailingInset: CGFloat = 0
    var onOpenFile: () -> Void

    @State private var isDragging: Bool = false
    @State private var dragPosition: Double = 0
    @State private var isBottomHovered: Bool = false
    @State private var isTopHovered: Bool = false
    @State private var overlayWidth: CGFloat = 0

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

            // Bottom Player Control Panel (Configurable sequence)
            HStack(spacing: 0) {
                let items = uiState?.controlsConfig.visibleItems ?? ControlsConfiguration.defaultItems
                ForEach(items) { item in
                    controlView(for: item)
                        // Keep the timeline's thumbnail preview above neighbouring controls.
                        .zIndex(item == .timeline ? 1 : 0)
                }
            }
            // Bar height stays the tallest control's; height-flexible items (the timeline's hit
            // area) stretch to it instead of growing the bar.
            .fixedSize(horizontal: false, vertical: true)
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
        .coordinateSpace(.named(ControlTimelineSection.previewBoundsSpace))
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            overlayWidth = $0
        }
        .onChange(of: isDragging) { _, _ in
            updateInteractionState()
        }
        .onChange(of: isFullscreen) { _, fs in
            if fs {
                isTopHovered = false
                updateInteractionState()
            }
        }
        // Outside the measured width so the timeline preview stays clear of the side panel too.
        .padding(.trailing, trailingInset)
    }

    @ViewBuilder
    private func controlView(for item: ControlBarItem) -> some View {
        switch item {
        case .playlistPrevious:
            ControlPlaylistNavButton(engine: engine, isNext: false, osd: uiState?.osd)
        case .seekBackward:
            ControlSeekRelativeButton(engine: engine, isForward: false)
        case .playPause:
            ControlPlayPauseButton(engine: engine)
        case .seekForward:
            ControlSeekRelativeButton(engine: engine, isForward: true)
        case .playlistNext:
            ControlPlaylistNavButton(engine: engine, isNext: true, osd: uiState?.osd)
        case .timeline:
            ControlTimelineSection(
                engine: engine,
                uiState: uiState,
                isDragging: $isDragging,
                dragPosition: $dragPosition,
                previewBoundsWidth: overlayWidth
            )
        case .volume:
            ControlVolumeSlider(engine: engine)
        case .audioTrack:
            ControlAudioTrackButton(engine: engine, uiState: uiState)
        case .subtitleTrack:
            ControlSubtitleTrackButton(engine: engine, uiState: uiState)
        case .chapters:
            ControlChaptersToggleButton(engine: engine, uiState: uiState)
        case .playlist:
            ControlPlaylistToggleButton(uiState: uiState)
        case .playlistRepeat:
            ControlPlaylistRepeatButton(engine: engine)
        case .playlistShuffle:
            ControlPlaylistShuffleButton(engine: engine)
        case .quickSettings:
            ControlQuickSettingsToggleButton(uiState: uiState)
        case .pictureInPicture:
            ControlPictureInPictureButton(engine: engine, uiState: uiState)
        }
    }

    private func updateInteractionState() {
        let topActive = !isFullscreen && isTopHovered
        isInteracting = isBottomHovered || topActive || isDragging
    }
}
