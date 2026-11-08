import AppKit
import NitsCore
import NitsUI

@MainActor
public final class PlayerWindow: NSWindow {
    public weak var actionHandler: (any PlayerActions)?

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
