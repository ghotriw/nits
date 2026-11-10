import NitsCore
import NitsUI
import SwiftUI

public struct PlayerCommands: Commands {
    @FocusedValue(\.playerActions) private var focusedPlayer: (any PlayerActions)?
    private let fallbackPlayer: (@MainActor () -> (any PlayerActions)?)?

    public init(fallbackPlayer: (@MainActor () -> (any PlayerActions)?)? = nil) {
        self.fallbackPlayer = fallbackPlayer
    }

    private var playerActions: (any PlayerActions)? {
        focusedPlayer ?? fallbackPlayer?()
    }

    /// Everything the menus show of the player. Read nothing else of it in `body`: the menus depend on whatever
    /// `body` reads, and each change rebuilds the main menu, closing a submenu the pointer is in (`PlayerMenuState`).
    private var menuState: PlayerMenuState {
        playerActions?.menuState ?? PlayerMenuState()
    }

    /// The encoding of a subtitle file: the default (automatic detection, or the one in Settings) or a choice.
    private func encodingPicker(
        get: @escaping @MainActor @Sendable () -> String.Encoding?,
        set: @escaping @MainActor @Sendable (String.Encoding?) -> Void, isEnabled: Bool
    ) -> some View {
        Picker("Encoding", selection: Binding(get: get, set: set)) {
            Text("Default").tag(String.Encoding?.none)
            Divider()
            ForEach(SubtitleEncodingCatalog.all, id: \.name) { entry in
                Text(entry.title).tag(String.Encoding?.some(entry.encoding))
            }
        }
        .disabled(!isEnabled)
    }

    public var body: some Commands {
        CommandMenu("Playback") {
            let menu = menuState
            Button("Play / Pause") {
                playerActions?.togglePlayPause()
            }
            .disabled(!menu.hasPlayer)

            Button("Next Track") {
                playerActions?.playNextTrack()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!menu.hasPlayer || !menu.hasNextTrack)

            Button("Previous Track") {
                playerActions?.playPreviousTrack()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!menu.hasPlayer || !menu.hasPreviousTrack)

            // Also PageDown / PageUp, handled by `PlayerWindow`.
            Button("Next Chapter") {
                playerActions?.nextChapter()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            .disabled(!menu.hasChapters)

            Button("Previous Chapter") {
                playerActions?.previousChapter()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            .disabled(!menu.hasChapters)

            Divider()

            Button("Step Forward (1 Frame)") {
                playerActions?.stepFrameForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            .disabled(!menu.hasPlayer)

            Button("Step Backward (1 Frame)") {
                playerActions?.stepFrameBackward()
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            .disabled(!menu.hasPlayer)

            Divider()

            let stepText = "\(Int(menu.seekStepSeconds))s"
            Button("Jump Forward (\(stepText))") {
                playerActions?.seekForward()
            }
            .disabled(!menu.hasPlayer)

            Button("Jump Backward (\(stepText))") {
                playerActions?.seekBackward()
            }
            .disabled(!menu.hasPlayer)

            Divider()

            Button("Jump to Time…") {
                playerActions?.promptJumpToTime()
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(!menu.hasPlayer || !menu.canJumpToTime)

            Divider()

            Menu("Playback Speed") {
                Button("0.5×") { playerActions?.setPlaybackRate(0.5) }
                Button("0.75×") { playerActions?.setPlaybackRate(0.75) }
                Button("1.0× (Normal)") { playerActions?.setPlaybackRate(1.0) }
                Button("1.25×") { playerActions?.setPlaybackRate(1.25) }
                Button("1.5×") { playerActions?.setPlaybackRate(1.5) }
                Button("2.0×") { playerActions?.setPlaybackRate(2.0) }
                Divider()
                Button("Slower (-0.1×)") { playerActions?.stepPlaybackRate(by: -0.1) }
                    .keyboardShortcut("[", modifiers: [.option])
                Button("Faster (+0.1×)") { playerActions?.stepPlaybackRate(by: 0.1) }
                    .keyboardShortcut("]", modifiers: [.option])
                Button("Reset to Normal (1.0×)") { playerActions?.resetPlaybackRate() }
                    .keyboardShortcut("\\", modifiers: [.option])
            }
            .disabled(!menu.hasPlayer)
        }

        CommandMenu("Audio") {
            let menu = menuState
            Button("Increase Volume") {
                playerActions?.stepVolume(by: 0.05)
            }
            .disabled(!menu.hasPlayer)

            Button("Decrease Volume") {
                playerActions?.stepVolume(by: -0.05)
            }
            .disabled(!menu.hasPlayer)

            Divider()

            Toggle(
                "Mute",
                isOn: Binding(
                    get: { menu.isMuted },
                    set: { _ in playerActions?.toggleMute() }
                )
            )
            .disabled(!menu.hasPlayer)
        }

        CommandMenu("Subtitles") {
            let menu = menuState
            let tracks = menu.subtitleTracks
            // The tracks are the media loaded's.
            let loaded = menu.isMediaLoaded
            Picker(
                "Subtitle Track",
                selection: Binding(
                    get: { menu.selectedSubtitleTrackId },
                    set: { playerActions?.selectSubtitleTrack($0) }
                )
            ) {
                Text("Off").tag(Int?.none)
                if !tracks.isEmpty { Divider() }
                ForEach(tracks) { track in
                    Text(TrackTitleFormatter.format(track))
                        .tag(Int?.some(track.id))
                }
            }
            .pickerStyle(.inline)
            .disabled(!loaded)

            Divider()

            Button("Load External Subtitle…") {
                playerActions?.loadSubtitleFile()
            }
            .disabled(!loaded)

            // Of this track's file: files differ in encoding as tracks do in language.
            encodingPicker(
                get: { menu.subtitleEncoding }, set: { playerActions?.setSubtitleEncoding($0) },
                isEnabled: menu.canSetSubtitleEncoding)

            Divider()

            let delay = menu.subtitleDelay
            let hasMain = menu.selectedSubtitleTrackId != nil
            Button("Delay Later (+0.1 s)") { playerActions?.stepSubtitleDelay(by: 0.1) }
                .disabled(!hasMain)
            Button("Delay Earlier (−0.1 s)") { playerActions?.stepSubtitleDelay(by: -0.1) }
                .disabled(!hasMain)
            Button("Reset Delay (\(String(format: "%+.1f s", delay)))") { playerActions?.resetSubtitleDelay() }
                .disabled(!hasMain || delay == 0)

            Divider()

            // The same for the second track, shown above the main one.
            Menu("Second Subtitle Track") {
                let candidates = menu.secondarySubtitleCandidates
                Picker(
                    "Second Subtitle Track",
                    selection: Binding(
                        get: { menu.selectedSecondarySubtitleTrackId },
                        set: { playerActions?.selectSecondarySubtitleTrack($0) }
                    )
                ) {
                    Text("Off").tag(Int?.none)
                    if !candidates.isEmpty { Divider() }
                    ForEach(candidates) { track in
                        Text(TrackTitleFormatter.format(track))
                            .tag(Int?.some(track.id))
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Button("Load External Subtitle…") {
                    playerActions?.loadSecondarySubtitleFile()
                }

                encodingPicker(
                    get: { menu.secondarySubtitleEncoding },
                    set: { playerActions?.setSecondarySubtitleEncoding($0) },
                    isEnabled: menu.canSetSecondarySubtitleEncoding)

                Divider()

                let secondDelay = menu.secondarySubtitleDelay
                let hasSecond = menu.selectedSecondarySubtitleTrackId != nil
                Button("Delay Later (+0.1 s)") { playerActions?.stepSecondarySubtitleDelay(by: 0.1) }
                    .disabled(!hasSecond)
                Button("Delay Earlier (−0.1 s)") { playerActions?.stepSecondarySubtitleDelay(by: -0.1) }
                    .disabled(!hasSecond)
                Button("Reset Delay (\(String(format: "%+.1f s", secondDelay)))") {
                    playerActions?.resetSecondarySubtitleDelay()
                }
                .disabled(!hasSecond || secondDelay == 0)
            }
            .disabled(!loaded)
        }

        CommandMenu("Video") {
            let menu = menuState
            Picker(
                "Render Mode",
                selection: Binding(
                    get: { menu.renderMode },
                    set: { mode in
                        if let playerActions {
                            playerActions.renderMode = mode
                        }
                    }
                )
            ) {
                ForEach(RenderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .disabled(!menu.hasPlayer)

            Menu("Tone Mapping Sharpness") {
                Button("0.0 (Off)") { playerActions?.metalSharpness = 0.0 }
                Button("0.3 (Soft)") { playerActions?.metalSharpness = 0.3 }
                Button("0.5 (Default)") { playerActions?.metalSharpness = 0.5 }
                Button("0.7 (Crisp)") { playerActions?.metalSharpness = 0.7 }
                Button("1.0 (Maximum)") { playerActions?.metalSharpness = 1.0 }
            }
            .disabled(!menu.hasPlayer)

            Divider()

            let hasVideo = menu.hasVideo
            Picker(
                "Aspect Ratio",
                selection: Binding(
                    get: { menu.aspectRatio },
                    set: { playerActions?.setVideoAspectRatio($0) }
                )
            ) {
                Text("Default").tag(RationalAspectRatio?.none)
                ForEach(RationalAspectRatio.displayPresets, id: \.self) { ratio in
                    Text(ratio.displayName).tag(RationalAspectRatio?.some(ratio))
                }
            }
            .disabled(!hasVideo)

            Picker(
                "Crop",
                selection: Binding(
                    get: { menu.crop },
                    set: { playerActions?.setVideoCrop($0) }
                )
            ) {
                Text("None").tag(RationalAspectRatio?.none)
                ForEach(RationalAspectRatio.displayPresets, id: \.self) { ratio in
                    Text(ratio.displayName).tag(RationalAspectRatio?.some(ratio))
                }
            }
            .disabled(!hasVideo)

            Picker(
                "Scaling",
                selection: Binding(
                    get: { menu.scaling },
                    set: { playerActions?.setVideoScaling($0) }
                )
            ) {
                ForEach(VideoScaling.allCases) { scaling in
                    Text(scaling.title).tag(scaling)
                }
            }
            .disabled(!hasVideo)

            Button("Zoom In") { playerActions?.stepVideoZoom(by: 1) }
                .keyboardShortcut("=", modifiers: [.option, .command])
                .disabled(!hasVideo)
            Button("Zoom Out") { playerActions?.stepVideoZoom(by: -1) }
                .keyboardShortcut("-", modifiers: [.option, .command])
                .disabled(!hasVideo)
            Button("Actual Zoom") { playerActions?.resetVideoZoom() }
                .keyboardShortcut("0", modifiers: [.option, .command])
                .disabled(!hasVideo || menu.isZoomReset)

            Divider()

            Button("Save Screenshot") { playerActions?.captureFrame() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasVideo)
        }

        CommandMenu("View") {
            let menu = menuState
            Toggle(
                "Playlist",
                isOn: Binding(
                    get: { menu.isPlaylistPresented },
                    set: { _ in playerActions?.togglePlaylist() }
                )
            )
            .keyboardShortcut("p", modifiers: [.option, .command])
            .disabled(!menu.isPlaylistAvailable)

            Toggle(
                "Chapters",
                isOn: Binding(
                    get: { menu.isChaptersPresented },
                    set: { _ in playerActions?.toggleChapters() }
                )
            )
            .keyboardShortcut("c", modifiers: [.option, .command])
            .disabled(!menu.hasChapters)

            Toggle(
                "Quick Settings",
                isOn: Binding(
                    get: { menu.isQuickSettingsPresented },
                    set: { _ in playerActions?.toggleQuickSettings() }
                )
            )
            .keyboardShortcut("s", modifiers: [.option, .command])
            .disabled(!menu.hasPlayer)

            Toggle(
                "Performance HUD",
                isOn: Binding(
                    get: { menu.showDebugHUD },
                    set: { _ in playerActions?.toggleDebugHUD() }
                )
            )
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(!menu.hasPlayer)

            Divider()

            Button("Toggle Full Screen") {
                playerActions?.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.control, .command])
            .disabled(!menu.supportsFullscreen)

            Toggle(
                "Picture in Picture",
                isOn: Binding(
                    get: { menu.isPictureInPictureActive },
                    set: { _ in playerActions?.togglePictureInPicture() }
                )
            )
            .keyboardShortcut("p", modifiers: [.control, .command])
            .disabled(!menu.canTogglePictureInPicture)
        }

        CommandGroup(after: .windowArrangement) {
            Divider()

            Button("Show Log Console…") {
                LogViewerWindowController.shared.showLogs()
            }
            .keyboardShortcut("l", modifiers: [.option, .command])
        }
    }
}
