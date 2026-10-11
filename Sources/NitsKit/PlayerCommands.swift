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

    public var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") {
                playerActions?.togglePlayPause()
            }
            .disabled(playerActions == nil)

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

            Button("Jump Forward (5s)") {
                playerActions?.seekRelative(by: 5.0)
            }
            .disabled(playerActions == nil)

            Button("Jump Backward (5s)") {
                playerActions?.seekRelative(by: -5.0)
            }
            .disabled(playerActions == nil)

            Divider()

            Button("Jump to Time…") {
                playerActions?.promptJumpToTime()
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(playerActions == nil || !(playerActions?.canJumpToTime ?? false))
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
        }

        CommandMenu("View") {
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
