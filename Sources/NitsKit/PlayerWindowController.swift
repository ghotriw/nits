import AppKit
import NitsCore
import NitsUI
import SwiftUI

/// A window of the player's own around a `PlayerSession`: the title bar and its traffic lights, the toolbar and the
/// fullscreen animation. What is not the window's (callbacks, Now Playing, Picture in Picture, actions, opening media)
/// is the session's; the members below forward to it.
@MainActor
public final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    public let session: PlayerSession
    public var engine: PlayerEngine { session.engine }
    public var uiState: PlayerUIState { session.uiState }
    public var nowPlayingController: any NowPlayingController { session.nowPlayingController }
    public var onKeyStatusChanged: ((Bool) -> Void)?

    /// See `PlayerSession.onClose`; called as the window closes.
    public var onClose: ((_ finalTime: Double, _ duration: Double) -> Void)? {
        get { session.onClose }
        set { session.onClose = newValue }
    }
    public var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)? {
        get { session.onTimeUpdate }
        set { session.onTimeUpdate = newValue }
    }
    public var onPlaybackStateChanged: ((PlaybackState) -> Void)? {
        get { session.onPlaybackStateChanged }
        set { session.onPlaybackStateChanged = newValue }
    }
    public var onPlaybackEnded: (() -> Void)? {
        get { session.onPlaybackEnded }
        set { session.onPlaybackEnded = newValue }
    }
    public var onActionButton: ((_ id: String) -> Void)? {
        get { session.onActionButton }
        set { session.onActionButton = newValue }
    }
    public var onTrackNavigation: ((_ direction: TrackNavigationDirection) -> Void)? {
        get { session.onTrackNavigation }
        set { session.onTrackNavigation = newValue }
    }

    public func setActionButtons(_ buttons: [PlaybackActionButton]) { session.setActionButtons(buttons) }
    public func setTrackNavigation(_ navigation: TrackNavigation) { session.setTrackNavigation(navigation) }
    public func applyConfiguration(_ config: PlayerConfiguration) { session.applyConfiguration(config) }
    public func applySettings(_ settings: AppSettings) { session.applySettings(settings) }

    /// The windowed frame while the window is in or entering fullscreen: the exit animation returns to it.
    private var frameBeforeFullscreen: NSRect?

    /// - Parameters:
    ///   - configuration: The engine's settings (`applyConfiguration(_:)`), for a session that creates its engine.
    ///   - settings: The app's settings (`applySettings(_:)`).
    ///   - engine: An engine built with the same `configuration` and the host's own stores (tests pass
    ///     in-memory ones); `nil` creates one that uses the app's.
    ///   - recentMediaStore: Where loaded media is recorded for Recent Media; `nil` for hosts and tests.
    public init(
        configuration: PlayerConfiguration = PlayerConfiguration(),
        settings: AppSettings = AppSettings(),
        engine: PlayerEngine? = nil,
        recentMediaStore: RecentMediaStore? = nil
    ) {
        let session = PlayerSession(
            configuration: configuration, settings: settings, engine: engine, recentMediaStore: recentMediaStore)
        self.session = session
        let window = PlayerWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        session.presentation = self
        session.uiState.movesWindow = true
        window.actionHandler = session
        session.uiState.titleBarDoubleClicked = { [weak window] in
            window?.performTitleBarDoubleClickAction()
        }
        session.onControlsVisibilityChanged = { [weak window] isVisible in
            window?.setStandardButtonsVisible(isVisible)
            if !isVisible { window?.hideCursorWithPlayerControls() }
        }
        session.onOpenStream = { [weak self] presents in
            self?.streamOpened(presentsWindow: presents)
        }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        observeMediaTitle()

        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        updateToolbar(isFullscreen: false)

        let hostingView = NSHostingView(rootView: session.makeContentView())
        window.contentView = hostingView
        window.initialFirstResponder = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func openFile(
        url: URL,
        title: String? = nil,
        artworkData: Data? = nil,
        artworkURL: URL? = nil,
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil,
        actionButtons: [PlaybackActionButton] = [],
        trackNavigation: TrackNavigation = TrackNavigation()
    ) {
        openStream(
            url: url,
            title: title,
            artworkData: artworkData,
            artworkURL: artworkURL,
            headers: [:],
            startTime: startTime,
            audioTrack: audioTrack,
            subtitleTrack: subtitleTrack,
            actionButtons: actionButtons,
            trackNavigation: trackNavigation
        )
    }

    /// Loads `url` and, with `presentsWindow`, brings the window and the app to the front.
    public func openStream(
        url: URL,
        title: String? = nil,
        artworkData: Data? = nil,
        artworkURL: URL? = nil,
        headers: [String: String] = [:],
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil,
        actionButtons: [PlaybackActionButton] = [],
        trackNavigation: TrackNavigation = TrackNavigation(),
        presentsWindow: Bool = true
    ) {
        session.openStream(
            url: url, title: title, artworkData: artworkData, artworkURL: artworkURL, headers: headers,
            startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack,
            actionButtons: actionButtons, trackNavigation: trackNavigation, presents: presentsWindow)
    }

    /// The session loaded a stream: the controls come back, and the window with them if asked. Not called once the
    /// session ended, so a window closed while a link resolved stays closed.
    private func streamOpened(presentsWindow: Bool) {
        window?.setStandardButtonsVisible(true)
        guard presentsWindow else { return }

        showWindow(nil)
        window?.presentForPlayback()
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        onKeyStatusChanged?(true)
    }

    /// The window's title follows the media's, which a load sets late for a playlist file and refines from the
    /// container's metadata or a resolver. Re-registered after every change, as `withObservationTracking` reports one.
    private func observeMediaTitle() {
        window?.title = engine.mediaTitle.isEmpty ? "Nits" : engine.mediaTitle
        withObservationTracking {
            _ = engine.mediaTitle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeMediaTitle() }
        }
    }

    public func exitFullscreen() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    public override func cancelOperation(_ sender: Any?) {
        if window?.styleMask.contains(.fullScreen) == true {
            exitFullscreen()
        } else {
            super.cancelOperation(sender)
        }
    }

    private func updateToolbar(isFullscreen: Bool) {
        guard let window else { return }
        if isFullscreen {
            window.toolbar = nil
        } else {
            let toolbar = NSToolbar()
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        onKeyStatusChanged?(true)
        nowPlayingController.isKeyWindow = true
    }

    public func windowDidResignKey(_ notification: Notification) {
        onKeyStatusChanged?(false)
        nowPlayingController.isKeyWindow = false
    }

    /// The share of the system's duration the custom transition takes: shorter feels more responsive.
    private static let fullscreenAnimationSpeedFactor = 0.75

    /// The window animates its own frame (see `window(_:startCustomAnimationToEnterFullScreenOn:withDuration:)`), so
    /// the video keeps playing during the transition. With the system animation AppKit animates a snapshot of the
    /// window and the picture freezes until it ends.
    public func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    public func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    /// Where the window goes on leaving fullscreen: the frame it had before. One on a screen that is gone (a monitor
    /// unplugged meanwhile) is centered on the window's screen at its old size, cut to fit; with none at all (it
    /// entered fullscreen some other way) the window takes 2/3 of the screen. (`constrainFrameRect` leaves the
    /// horizontal position alone, so it can't bring a frame from a gone screen back.)
    private func windowedFrame(for window: NSWindow) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return window.frame }
        if let frame = frameBeforeFullscreen,
            let home = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
        {
            return window.constrainFrameRect(frame, to: home)
        }
        let area = screen.visibleFrame
        let size =
            frameBeforeFullscreen.map { NSSize(width: min($0.width, area.width), height: min($0.height, area.height)) }
            ?? NSSize(width: area.width * 2 / 3, height: area.height * 2 / 3)
        return NSRect(
            x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    public func window(
        _ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen,
        withDuration duration: TimeInterval
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration * Self.fullscreenAnimationSpeedFactor
            window.animator().setFrame(screen.frame, display: true)
        }
    }

    public func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        let target = windowedFrame(for: window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration * Self.fullscreenAnimationSpeedFactor
            window.animator().setFrame(target, display: true)
        }
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        frameBeforeFullscreen = window?.frame
        updateToolbar(isFullscreen: true)
        window?.titleVisibility = .visible
        window?.titlebarAppearsTransparent = false
        uiState.isFullscreen = true
        window?.setStandardButtonsVisible(true, animated: false)
    }

    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        // The custom animation may already have stretched the window.
        if let frame = frameBeforeFullscreen { window.setFrame(frame, display: true) }
        frameBeforeFullscreen = nil
        updateToolbar(isFullscreen: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        uiState.isFullscreen = false
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        window?.titleVisibility = .hidden
    }

    public func windowDidFailToExitFullScreen(_ window: NSWindow) {
        // The window stays in fullscreen, but the custom animation may already have shrunk it;
        // `frameBeforeFullscreen` is kept for the next exit.
        if let screen = window.screen { window.setFrame(screen.frame, display: true) }
        window.titleVisibility = .visible
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        frameBeforeFullscreen = nil
        updateToolbar(isFullscreen: false)
        window?.titlebarAppearsTransparent = true
        uiState.isFullscreen = false
    }

    public func windowWillClose(_ notification: Notification) {
        session.end(windowClosing: true)
    }
}

extension PlayerWindowController: PlayerPresentation {
    public var supportsFullscreen: Bool { true }

    public var isFullscreen: Bool {
        window?.styleMask.contains(.fullScreen) == true
    }

    public func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }
}
