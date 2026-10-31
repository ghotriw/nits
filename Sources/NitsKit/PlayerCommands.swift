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
            Button("Play / Pause") {
                playerActions?.togglePlayPause()
            }
            .disabled(playerActions == nil)

            Button("Next Track") {
                playerActions?.playNextTrack()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(playerActions == nil || !(playerActions?.hasNextTrack ?? false))

            Button("Previous Track") {
                playerActions?.playPreviousTrack()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(playerActions == nil || !(playerActions?.hasPreviousTrack ?? false))

            // Also PageDown / PageUp, handled by `PlayerWindow`.
            Button("Next Chapter") {
                playerActions?.nextChapter()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            .disabled(!(playerActions?.hasChapters ?? false))

            Button("Previous Chapter") {
                playerActions?.previousChapter()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            .disabled(!(playerActions?.hasChapters ?? false))

            Divider()

            Button("Step Forward (1 Frame)") {
                playerActions?.stepFrameForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            .disabled(playerActions == nil)

            Button("Step Backward (1 Frame)") {
                playerActions?.stepFrameBackward()
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            .disabled(playerActions == nil)

            Divider()

            let stepText = "\(Int(playerActions?.seekStepSeconds ?? 5))s"
            Button("Jump Forward (\(stepText))") {
                playerActions?.seekForward()
            }
            .disabled(playerActions == nil)

            Button("Jump Backward (\(stepText))") {
                playerActions?.seekBackward()
            }
            .disabled(playerActions == nil)

            Divider()

            Button("Jump to Time…") {
                playerActions?.promptJumpToTime()
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(playerActions == nil || !(playerActions?.canJumpToTime ?? false))

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
            .disabled(playerActions == nil)
        }

        CommandMenu("Audio") {
            Button("Increase Volume") {
                playerActions?.stepVolume(by: 0.05)
            }
            .disabled(playerActions == nil)

            Button("Decrease Volume") {
                playerActions?.stepVolume(by: -0.05)
            }
            .disabled(playerActions == nil)

            Divider()

            Toggle(
                "Mute",
                isOn: Binding(
                    get: { playerActions?.isMuted ?? false },
                    set: { _ in playerActions?.toggleMute() }
                )
            )
            .disabled(playerActions == nil)
        }

        CommandMenu("Subtitles") {
            let tracks = playerActions?.subtitleTracks ?? []
            // The tracks are the media loaded's.
            let loaded = playerActions?.isMediaLoaded ?? false
            Picker(
                "Subtitle Track",
                selection: Binding(
                    get: { playerActions?.selectedSubtitleTrackId },
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
                get: { playerActions?.subtitleEncoding }, set: { playerActions?.setSubtitleEncoding($0) },
                isEnabled: playerActions?.canSetSubtitleEncoding ?? false)

            Divider()

            let delay = playerActions?.subtitleDelay ?? 0
            let hasMain = playerActions?.selectedSubtitleTrackId != nil
            Button("Delay Later (+0.1 s)") { playerActions?.stepSubtitleDelay(by: 0.1) }
                .disabled(!hasMain)
            Button("Delay Earlier (−0.1 s)") { playerActions?.stepSubtitleDelay(by: -0.1) }
                .disabled(!hasMain)
            Button("Reset Delay (\(String(format: "%+.1f s", delay)))") { playerActions?.resetSubtitleDelay() }
                .disabled(!hasMain || delay == 0)

            Divider()

            // The same for the second track, shown above the main one.
            Menu("Second Subtitle Track") {
                let candidates = playerActions?.secondarySubtitleCandidates ?? []
                Picker(
                    "Second Subtitle Track",
                    selection: Binding(
                        get: { playerActions?.selectedSecondarySubtitleTrackId },
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
                    get: { playerActions?.secondarySubtitleEncoding },
                    set: { playerActions?.setSecondarySubtitleEncoding($0) },
                    isEnabled: playerActions?.canSetSecondarySubtitleEncoding ?? false)

                Divider()

                let secondDelay = playerActions?.secondarySubtitleDelay ?? 0
                let hasSecond = playerActions?.selectedSecondarySubtitleTrackId != nil
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
            Picker(
                "Render Mode",
                selection: Binding(
                    get: { playerActions?.renderMode ?? .auto },
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
            .disabled(playerActions == nil)

            Menu("Tone Mapping Sharpness") {
                Button("0.0 (Off)") { playerActions?.metalSharpness = 0.0 }
                Button("0.3 (Soft)") { playerActions?.metalSharpness = 0.3 }
                Button("0.5 (Default)") { playerActions?.metalSharpness = 0.5 }
                Button("0.7 (Crisp)") { playerActions?.metalSharpness = 0.7 }
                Button("1.0 (Maximum)") { playerActions?.metalSharpness = 1.0 }
            }
            .disabled(playerActions == nil)

            Divider()

            let hasVideo = playerActions?.hasVideo ?? false
            Picker(
                "Aspect Ratio",
                selection: Binding(
                    get: { playerActions?.videoGeometry.aspectRatio },
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
                    get: { playerActions?.videoGeometry.crop },
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
                    get: { playerActions?.videoGeometry.scaling ?? .fit },
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
                .disabled(
                    !hasVideo
                        || (playerActions?.videoGeometry.zoom == 1.0 && playerActions?.videoGeometry.pan == .zero))

            Divider()

            Button("Save Screenshot") { playerActions?.captureFrame() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasVideo)
        }

        CommandMenu("View") {
            Toggle(
                "Playlist",
                isOn: Binding(
                    get: { playerActions?.isPlaylistPresented ?? false },
                    set: { _ in playerActions?.togglePlaylist() }
                )
            )
            .keyboardShortcut("p", modifiers: [.option, .command])
            .disabled(!(playerActions?.isPlaylistAvailable ?? false))

            Toggle(
                "Chapters",
                isOn: Binding(
                    get: { playerActions?.isChaptersPresented ?? false },
                    set: { _ in playerActions?.toggleChapters() }
                )
            )
            .keyboardShortcut("c", modifiers: [.option, .command])
            .disabled(!(playerActions?.hasChapters ?? false))

            Toggle(
                "Quick Settings",
                isOn: Binding(
                    get: { playerActions?.isQuickSettingsPresented ?? false },
                    set: { _ in playerActions?.toggleQuickSettings() }
                )
            )
            .keyboardShortcut("s", modifiers: [.option, .command])
            .disabled(playerActions == nil)

            Toggle(
                "Performance HUD",
                isOn: Binding(
                    get: { playerActions?.showDebugHUD ?? false },
                    set: { _ in playerActions?.toggleDebugHUD() }
                )
            )
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(playerActions == nil)

            Divider()

            Button("Toggle Full Screen") {
                playerActions?.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.control, .command])
            .disabled(playerActions == nil)

            Toggle(
                "Picture in Picture",
                isOn: Binding(
                    get: { playerActions?.isPictureInPictureActive ?? false },
                    set: { _ in playerActions?.togglePictureInPicture() }
                )
            )
            .keyboardShortcut("p", modifiers: [.control, .command])
            .disabled(!(playerActions?.canTogglePictureInPicture ?? false))
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
