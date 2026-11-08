import AppKit

/// The player's keys without a modifier (and `⌥←` / `⌥→`), read by physical key code so they work on any keyboard
/// layout and while focus is in a panel (text fields excepted). Menu shortcuts see keys before the view does, which
/// is why these are not `CommandMenu` items or `.onKeyPress`.
///
/// `PlayerWindow` calls it from `sendEvent`; a host with a window of its own installs a `PlayerKeyMonitor`.
@MainActor
public enum PlayerKeyRouter {
    /// Handles a key press; `true` when it was the player's. The press of ←/→ begins scrubbing.
    public static func handleKeyDown(
        _ event: NSEvent, firstResponder: NSResponder?, actions actionHandler: any PlayerActions
    )
        -> Bool
    {
        // Do not intercept if user is typing in a text field
        if firstResponder is NSTextView || firstResponder is NSText {
            return false
        }

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
        case 0x7B, 0x7C:  // Left / Right Arrow
            // From the press to the release the seeks show frames, and playback resumes once, on release: a tap resumes
            // as the finger lifts (or as its seek lands, if later), a held key after its last repeat. Begun at the press,
            // not the first repeat, so the presses of a held key are one burst however long the system waits to repeat.
            actionHandler.beginScrubbing()
            if event.keyCode == 0x7B {
                actionHandler.seekBackward()
            } else {
                actionHandler.seekForward()
            }
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
        case 0x2E:  // Physical 'M' (ANSI M) -> Mute on any keyboard layout (Ukrainian, Hebrew, etc.)
            actionHandler.toggleMute()
            return true
        case 0x02:  // Physical 'D' (ANSI D) -> Performance HUD on any layout
            actionHandler.toggleDebugHUD()
            return true
        case 0x03:  // Physical 'F' (ANSI F) -> Toggle Fullscreen on any layout
            guard actionHandler.supportsFullscreen else { return false }
            actionHandler.toggleFullscreen()
            return true
        case 0x23:  // Physical 'P' (ANSI P) -> Toggle Playlist on any layout
            actionHandler.togglePlaylist()
            return true
        case 0x08:  // Physical 'C' (ANSI C) -> Toggle Chapters on any layout, when the media has them
            guard actionHandler.hasChapters else { return false }
            actionHandler.toggleChapters()
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
        case 0x06:  // Physical 'Z' (ANSI Z) -> Show subtitles 100 ms earlier
            actionHandler.stepSubtitleDelay(by: -0.1)
            return true
        case 0x07:  // Physical 'X' (ANSI X) -> Show subtitles 100 ms later
            actionHandler.stepSubtitleDelay(by: 0.1)
            return true
        case 0x26:  // Physical 'J' (ANSI J) -> Play audio 50 ms earlier (VLC's binding)
            actionHandler.stepAudioDelay(by: -0.05)
            return true
        case 0x28:  // Physical 'K' (ANSI K) -> Play audio 50 ms later
            actionHandler.stepAudioDelay(by: 0.05)
            return true
        case 0x00:  // Physical 'A' (ANSI A) -> Cycle the aspect ratio override (VLC / mpv)
            guard actionHandler.hasVideo else { return false }
            actionHandler.cycleVideoAspectRatio()
            return true
        case 0x0D:  // Physical 'W' (ANSI W) -> Cycle scaling: Fit, Fill, Stretch, Original Size (mpv's panscan key)
            guard actionHandler.hasVideo else { return false }
            actionHandler.cycleVideoScaling()
            return true
        case 0x24, 0x4C:  // Return / keypad Enter -> Press the action button ("Skip Intro") while it is on screen
            guard actionHandler.isActionButtonVisible else { return false }
            actionHandler.pressActionButton()
            return true
        case 0x35:  // Escape -> Dismiss dialogs/sidebars/action button if active, or Exit Fullscreen if active
            if actionHandler.isJumpToPresented {
                actionHandler.dismissJumpToTime()
                return true
            }
            if actionHandler.isSidePanelPresented {
                actionHandler.closeSidePanel()
                return true
            }
            if actionHandler.isActionButtonVisible {
                actionHandler.dismissActionButton()
                return true
            }
            if actionHandler.isFullscreen {
                actionHandler.exitFullscreen()
                return true
            }
            return false
        default:
            return false
        }
    }
}

/// Gives a session the player's keys in a window of the host's: a local event monitor for that window (the host's
/// `sendEvent` stays its own). Hold it as long as the session is shown; it removes itself when released.
///
/// Keys go to the session only while the window is key and `ignoresResponder` says the focus is not somewhere that
/// keeps its keys. By default that is a text input (an `NSTextInputClient`, which a web view is, even with no field
/// selected); a host that wants the player's keys with the focus in its web view passes its own judgment. A key's
/// release in the window, or the window resigning key, ends scrubbing.
///
/// It can be released from any thread; the monitor comes off on the main actor.
@MainActor
public final class PlayerKeyMonitor {
    private weak var actions: (any PlayerActions)?
    private weak var window: NSWindow?
    private let ignoresResponder: @MainActor (NSResponder?) -> Bool
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?

    /// - Parameter ignoresResponder: Whether the focus is somewhere that keeps its keys; the monitor leaves them alone.
    ///   Replaces the default (any `NSTextInputClient`), it does not add to it.
    public init(
        actions: any PlayerActions, window: NSWindow,
        ignoresResponder: @escaping @MainActor (NSResponder?) -> Bool = { $0 is any NSTextInputClient }
    ) {
        self.ignoresResponder = ignoresResponder
        self.actions = actions
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors are called on the main thread.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.actions?.endScrubbing() }
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    /// `true` when the event was the player's.
    private func handle(_ event: NSEvent) -> Bool {
        guard let actions, let window, event.window === window else { return false }
        // Any release ends scrubbing, wherever the focus went meanwhile (as `PlayerWindow` does).
        if event.type == .keyUp {
            actions.endScrubbing()
            return false
        }
        guard window.isKeyWindow, !ignoresResponder(window.firstResponder) else { return false }
        return PlayerKeyRouter.handleKeyDown(event, firstResponder: window.firstResponder, actions: actions)
    }
}
