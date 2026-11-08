import AppKit
import NitsCore
import NitsUI
import Observation

/// Shows a `PlayerSession` in a window the host already has (its main window, say) instead of a player window of its
/// own, and gives the window back as it was on `detach()`.
///
/// The host puts `session.makeContentView()` in the window and creates this; from there on the presentation:
/// - is the session's `presentation`: the window's own fullscreen (`toggleFullscreen()` and the session's
///   `uiState.isFullscreen` follow it), the HDR screenshot and Picture in Picture's moving the window aside;
/// - gives the session the window's keys (`PlayerKeyMonitor`), taking the focus off whatever had it;
/// - lets drags of the picture and of the header strip move the window, and a double click on the strip do what one on
///   a title bar does (`NSWindow.performTitleBarDoubleClickAction()`);
/// - brings the window forward when media opens (`openStream(presents: true)`);
/// - with `adoptsTitleBar`, makes the window's title bar look like the player window's: the title hidden, the bar
///   transparent over the picture and as tall as the header strip that stands in for it, the traffic lights fading
///   with the controls. For a player shown at the top of the window, as the strip's inset for the traffic lights
///   expects.
///
/// It takes the session's `onControlsVisibilityChanged` and `onOpenStream`; a host follows the controls through
/// `areControlsVisible`. When the window closes it ends the session, detaches and calls `onWindowClose`.
@MainActor
@Observable
public final class HostWindowPresentation: PlayerPresentation {
    public let session: PlayerSession
    @ObservationIgnored public private(set) weak var window: NSWindow?
    /// Whether the player's controls (and the header strip) are on screen.
    public private(set) var areControlsVisible = true
    /// Called after the window closed, which ended the session and detached the presentation: the host lets go of
    /// both.
    @ObservationIgnored public var onWindowClose: (() -> Void)?

    @ObservationIgnored private let adoptsTitleBar: Bool
    @ObservationIgnored private var keyMonitor: PlayerKeyMonitor?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var savedTitleBar: SavedTitleBar?
    /// The toolbar the presentation gave a window that had none: a compact one makes the title bar as tall as the
    /// header strip and centers the traffic lights in it.
    @ObservationIgnored private var installedToolbar: NSToolbar?
    /// The window entered fullscreen while presenting the player, so `detach()` leaves it; one that was in fullscreen
    /// already stays.
    @ObservationIgnored private var enteredFullscreen = false
    @ObservationIgnored private var isAttached = true

    /// - Parameters:
    ///   - adoptsTitleBar: Whether the player takes the window's title bar over (see the type); off, the title bar and
    ///     the traffic lights stay the host's.
    ///   - ignoresResponder: Where the focus keeps its keys from the player (`PlayerKeyMonitor`). A SwiftUI window's
    ///     hosting view is an `NSTextInputClient`, which the default reads as typing; such a host passes
    ///     `{ $0 is NSTextView }` (a text field's field editor) or its own judgment.
    public init(
        session: PlayerSession, window: NSWindow, adoptsTitleBar: Bool = true,
        ignoresResponder: @escaping @MainActor (NSResponder?) -> Bool = { $0 is any NSTextInputClient }
    ) {
        self.session = session
        self.window = window
        self.adoptsTitleBar = adoptsTitleBar

        // A session is presented in one place: one presenting it already gives its window back first, rather than
        // keep its keys and close handling (and, in the same window, hand this one its title bar as the original).
        (session.presentation as? HostWindowPresentation)?.detach()
        session.presentation = self
        session.uiState.isFullscreen = window.styleMask.contains(.fullScreen)
        session.uiState.movesWindow = true
        session.uiState.titleBarDoubleClicked = { [weak window] in
            window?.performTitleBarDoubleClickAction()
        }
        session.onControlsVisibilityChanged = { [weak self] isVisible in
            self?.controlsVisibilityChanged(isVisible)
        }
        session.onOpenStream = { [weak self] presents in
            self?.streamOpened(presents: presents)
        }

        // The window's first responder may be a text field of the content underneath, which would keep the keys.
        window.makeFirstResponder(nil)
        keyMonitor = PlayerKeyMonitor(actions: session, window: window, ignoresResponder: ignoresResponder)
        observeWindow(window)
        adoptTitleBar()
    }

    isolated deinit {
        detach()
    }

    /// Gives the window back: its title bar and traffic lights, its keys, and the fullscreen the player entered. The
    /// session goes on (the host may show it elsewhere or `end()` it); it is no longer presented here. Safe to call
    /// more than once.
    public func detach() {
        detach(windowClosing: false)
    }

    /// A closing window is left in fullscreen: it goes away, and the exit animation would run on a window that does.
    private func detach(windowClosing: Bool) {
        guard isAttached else { return }
        isAttached = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        keyMonitor = nil
        // Out of fullscreen first, so the title bar comes back to a window, not to a fullscreen frame.
        if enteredFullscreen, !windowClosing, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        enteredFullscreen = false
        restoreTitleBar()

        // The session may be presented elsewhere by now (in `deinit` the weak reference to this one already reads nil).
        guard session.presentation == nil || session.presentation === self else { return }
        session.presentation = nil
        session.uiState.isFullscreen = false
        session.uiState.movesWindow = false
        session.uiState.titleBarDoubleClicked = nil
        session.onControlsVisibilityChanged = nil
        session.onOpenStream = nil
    }

    // MARK: - PlayerPresentation

    public var supportsFullscreen: Bool { true }

    public var isFullscreen: Bool {
        window?.styleMask.contains(.fullScreen) == true
    }

    public func toggleFullscreen() {
        guard let window else { return }
        window.toggleFullScreen(nil)
    }

    public func exitFullscreen() {
        guard isFullscreen else { return }
        window?.toggleFullScreen(nil)
    }

    // MARK: - Session events

    private func controlsVisibilityChanged(_ isVisible: Bool) {
        areControlsVisible = isVisible
        guard let window else { return }
        if adoptsTitleBar { window.setStandardButtonsVisible(isVisible) }
        if !isVisible { window.hideCursorWithPlayerControls() }
    }

    private func streamOpened(presents: Bool) {
        areControlsVisible = true
        guard let window else { return }
        if adoptsTitleBar { window.setStandardButtonsVisible(true) }
        if presents { window.presentForPlayback() }
    }

    // MARK: - Window

    private func observeWindow(_ window: NSWindow) {
        let center = NotificationCenter.default
        // Entered once it is done, not at `willEnter`: an entry the system refuses comes with no notification of its own
        // (only the window's delegate, which is the host's, hears of it), and would leave the player in fullscreen.
        let fullscreen: [(Notification.Name, Bool)] = [
            (NSWindow.didEnterFullScreenNotification, true),
            (NSWindow.didExitFullScreenNotification, false),
        ]
        observers = fullscreen.map { name, isFullscreen in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullscreenChanged(isFullscreen) }
            }
        }
        observers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            })
    }

    private func fullscreenChanged(_ isFullscreen: Bool) {
        session.uiState.isFullscreen = isFullscreen
        // However it was entered: the player's `F`, its double click, or the green button over its header strip.
        enteredFullscreen = isFullscreen
        applyTitleBar(isFullscreen: isFullscreen)
        if adoptsTitleBar {
            window?.setStandardButtonsVisible(isFullscreen || areControlsVisible, animated: false)
        }
    }

    private func windowWillClose() {
        session.end(windowClosing: true)
        detach(windowClosing: true)
        onWindowClose?()
    }

    // MARK: - Title bar

    /// Takes the window's title bar over, keeping what it was to give back in `restoreTitleBar()`.
    private func adoptTitleBar() {
        guard adoptsTitleBar, let window, savedTitleBar == nil else { return }
        savedTitleBar = SavedTitleBar(
            toolbarStyle: window.toolbarStyle,
            separatorStyle: window.titlebarSeparatorStyle,
            titleVisibility: window.titleVisibility,
            appearsTransparent: window.titlebarAppearsTransparent,
            hasFullSizeContent: window.styleMask.contains(.fullSizeContentView)
        )
        if window.toolbar == nil {
            let toolbar = NSToolbar()
            toolbar.displayMode = .iconOnly
            installedToolbar = toolbar
        }
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        applyTitleBar(isFullscreen: window.styleMask.contains(.fullScreen))
    }

    /// Windowed, the header strip stands in for the title bar; in fullscreen the title bar that slides in with the menu
    /// bar is an ordinary one, as in the player window. A host's own toolbar stays (its items are the host's to hide).
    private func applyTitleBar(isFullscreen: Bool) {
        guard let window, savedTitleBar != nil else { return }
        window.titleVisibility = isFullscreen ? .visible : .hidden
        window.titlebarAppearsTransparent = !isFullscreen
        if let installedToolbar {
            window.toolbar = isFullscreen ? nil : installedToolbar
        }
    }

    private func restoreTitleBar() {
        guard let window, let saved = savedTitleBar else { return }
        window.setStandardButtonsVisible(true, animated: false)
        savedTitleBar = nil
        if let installedToolbar, window.toolbar === installedToolbar { window.toolbar = nil }
        installedToolbar = nil
        window.toolbarStyle = saved.toolbarStyle
        window.titlebarSeparatorStyle = saved.separatorStyle
        window.titleVisibility = saved.titleVisibility
        window.titlebarAppearsTransparent = saved.appearsTransparent
        if !saved.hasFullSizeContent { window.styleMask.remove(.fullSizeContentView) }
    }

    private struct SavedTitleBar {
        let toolbarStyle: NSWindow.ToolbarStyle
        let separatorStyle: NSTitlebarSeparatorStyle
        let titleVisibility: NSWindow.TitleVisibility
        let appearsTransparent: Bool
        let hasFullSizeContent: Bool
    }
}
