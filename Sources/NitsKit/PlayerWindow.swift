import AppKit
import NitsCore
import NitsUI

@MainActor
public final class PlayerWindow: NSWindow {
    public weak var actionHandler: (any PlayerActions)?

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleHardwareKey(event) {
            return
        }
        super.sendEvent(event)
    }

    private func handleHardwareKey(_ event: NSEvent) -> Bool {
        // Do not intercept if user is typing in a text field
        if firstResponder is NSTextView || firstResponder is NSText {
            return false
        }

        guard let actionHandler else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option])

        // Option-modified shortcuts (e.g. frame stepping)
        if modifiers == [.option] {
            switch event.keyCode {
            case 0x7C:  // Option + Right Arrow
                actionHandler.stepFrameForward()
                return true
            case 0x7B:  // Option + Left Arrow
                actionHandler.stepFrameBackward()
                return true
            default:
                return false
            }
        }

        // If Command or Control are pressed, leave them to system/menu commands
        guard modifiers.isEmpty else { return false }

        // Unmodified shortcuts based on hardware keyCode (layout-independent)
        switch event.keyCode {
        case 0x31:  // Space
            actionHandler.togglePlayPause()
            return true
        case 0x2B:  // Physical ',' (ANSI Comma, 0x2B / 43) -> Step 1 Frame Backward
            actionHandler.stepFrameBackward()
            return true
        case 0x2F:  // Physical '.' (ANSI Period, 0x2F / 47) -> Step 1 Frame Forward
            actionHandler.stepFrameForward()
            return true
        case 0x7B:  // Left Arrow
            actionHandler.seekBackward()
            return true
        case 0x7C:  // Right Arrow
            actionHandler.seekForward()
            return true
        case 0x79:  // Page Down (fn+↓ on laptop keyboards) -> Next Chapter
            guard actionHandler.hasChapters else { return false }
            actionHandler.nextChapter()
            return true
        case 0x74:  // Page Up (fn+↑) -> Previous Chapter
            guard actionHandler.hasChapters else { return false }
            actionHandler.previousChapter()
            return true
        case 0x7E:  // Up Arrow
            actionHandler.stepVolume(by: 0.05)
            return true
        case 0x7D:  // Down Arrow
            actionHandler.stepVolume(by: -0.05)
            return true
        case 0x2E:  // Physical 'M' (ANSI M) -> Mute on any keyboard layout (Russian, Hebrew, etc.)
            actionHandler.toggleMute()
            return true
        case 0x02:  // Physical 'D' (ANSI D) -> Performance HUD on any layout
            actionHandler.toggleDebugHUD()
            return true
        case 0x03:  // Physical 'F' (ANSI F) -> Toggle Fullscreen on any layout
            actionHandler.toggleFullscreen()
            return true
        case 0x23:  // Physical 'P' (ANSI P) -> Toggle Playlist on any layout
            actionHandler.togglePlaylist()
            return true
        case 0x21:  // Physical '[' (ANSI LeftBracket, 0x21 / 33) -> Decrease Speed by 0.1x
            actionHandler.stepPlaybackRate(by: -0.1)
            return true
        case 0x1E:  // Physical ']' (ANSI RightBracket, 0x1E / 30) -> Increase Speed by 0.1x
            actionHandler.stepPlaybackRate(by: 0.1)
            return true
        case 0x2A, 0x33:  // Physical '\' (0x2A / 42) or Backspace (0x33 / 51) -> Reset Speed to 1.0x
            actionHandler.resetPlaybackRate()
            return true
        case 0x35:  // Escape -> Dismiss dialogs/sidebars if active, or Exit Fullscreen if active
            if actionHandler.isJumpToPresented {
                actionHandler.dismissJumpToTime()
                return true
            }
            if actionHandler.isSidePanelPresented {
                actionHandler.closeSidePanel()
                return true
            }
            if styleMask.contains(.fullScreen) {
                actionHandler.exitFullscreen()
                return true
            }
            return false
        default:
            return false
        }
    }
}
