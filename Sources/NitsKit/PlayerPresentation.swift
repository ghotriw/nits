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
    /// The window the picture is in. An HDR screenshot reads the picture from it on the screen, and Picture in Picture
    /// moves it aside and brings it back as `AppSettings` asks (hiding it, entering PiP when it is minimized); `nil`
    /// does neither. Read once, when the presentation is set.
    var window: NSWindow? { get }
}

extension PlayerPresentation {
    public var supportsFullscreen: Bool { false }
    public var isFullscreen: Bool { false }
    public func toggleFullscreen() {}
    public func exitFullscreen() {}
    public var window: NSWindow? { nil }
}
