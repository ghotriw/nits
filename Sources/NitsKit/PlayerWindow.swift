import AppKit
import NitsCore
import NitsUI

@MainActor
public final class PlayerWindow: NSWindow {
    public weak var actionHandler: (any PlayerActions)?

    /// Does what a double click on a title bar does by the system setting (Desktop & Dock), for a view standing in for
    /// the title bar. The setting is in the global domain; AppKit's default when it is missing is `Maximize` (zoom).
    public func performTitleBarDoubleClickAction() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "None":
            break
        case "Minimize":
            miniaturize(nil)
        case "Fill" where responds(to: Self.zoomFillSelector):
            NSApp.sendAction(Self.zoomFillSelector, to: self, from: nil)
        case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
            // The setting before `AppleActionOnDoubleClick`.
            miniaturize(nil)
        default:
            zoom(nil)
        }
    }

    /// Window ▸ Fill, which AppKit offers no public API for.
    private static let zoomFillSelector = Selector(("_zoomFill:"))

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let actionHandler,
            PlayerKeyRouter.handleKeyDown(event, firstResponder: firstResponder, actions: actionHandler)
        {
            return
        }
        // An arrow key scrubs while down (see `handleHardwareKey`). Any key's release ends it: the arrow's own may come
        // with another key code (fn pressed meanwhile turns ← / → into Home / End), and another key pressed meanwhile has
        // stopped the arrow's repeats anyway.
        if event.type == .keyUp {
            actionHandler?.endScrubbing()
        }
        super.sendEvent(event)
    }

    /// The key-up of an arrow held while the window loses focus goes to another window.
    public override func resignKey() {
        super.resignKey()
        actionHandler?.endScrubbing()
    }
}
