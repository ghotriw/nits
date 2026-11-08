import AppKit

/// What the place a `PlayerSession` is shown in can do. `PlayerWindowController` is one (a window of the player's
/// own, with a fullscreen of its own); a host that puts `makeContentView()` in a window or pane of its own gives
/// what it has, and says what it has not: a session shown in a pane has no fullscreen to offer.
@MainActor
public protocol PlayerPresentation: AnyObject {
    /// Whether `toggleFullscreen()` does anything. The session's `F`, double click and menu item call it regardless.
    var supportsFullscreen: Bool { get }
    var isFullscreen: Bool { get }
    func toggleFullscreen()
    func exitFullscreen()
    /// The window the picture is in, which an HDR screenshot reads from the screen; `nil` captures nothing that way.
    var captureWindow: NSWindow? { get }
}

extension PlayerPresentation {
    public var supportsFullscreen: Bool { false }
    public var isFullscreen: Bool { false }
    public func toggleFullscreen() {}
    public func exitFullscreen() {}
    public var captureWindow: NSWindow? { nil }
}
