import AppKit

extension NSWindow {
    /// Does what a double click on a title bar does by the system setting (Desktop & Dock), for a view standing in for
    /// the title bar. The setting is in the global domain; AppKit's default when it is missing is `Maximize` (zoom).
    public func performTitleBarDoubleClickAction() {
        let defaults = UserDefaults.standard
        let zoomFill = Selector(("_zoomFill:"))  // Window ▸ Fill, which AppKit offers no public API for.
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "None":
            break
        case "Minimize":
            miniaturize(nil)
        case "Fill" where responds(to: zoomFill):
            NSApp.sendAction(zoomFill, to: self, from: nil)
        case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
            // The setting before `AppleActionOnDoubleClick`.
            miniaturize(nil)
        default:
            zoom(nil)
        }
    }

    /// The traffic lights fade with the player's controls, over a title bar the player's header strip stands in for.
    /// In fullscreen they are the title bar's that slides in with the menu bar: they are shown, never hidden.
    func setStandardButtonsVisible(_ isVisible: Bool, animated: Bool = true) {
        guard isVisible || !styleMask.contains(.fullScreen) else { return }
        let buttons = ([.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType])
            .compactMap { standardWindowButton($0) }
        guard animated else {
            for button in buttons {
                button.alphaValue = isVisible ? 1 : 0
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for button in buttons {
                button.animator().alphaValue = isVisible ? 1 : 0
            }
        }
    }

    /// The player's controls hid themselves: the pointer goes with them while it rests over the key window.
    func hideCursorWithPlayerControls() {
        if isKeyWindow { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    /// Brings the window and the app forward for media that was just opened, out of the Dock if it is there.
    func presentForPlayback() {
        if isMiniaturized { deminiaturize(nil) }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
