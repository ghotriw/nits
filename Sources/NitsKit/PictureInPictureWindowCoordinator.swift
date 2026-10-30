import AppKit
import NitsCore
import NitsUI

/// Moves the player window aside while Picture in Picture runs and brings it back afterwards, as `AppSettings` asks:
/// hides it, pauses playback, enters PiP when the window is minimized and leaves it when the window is restored.
///
/// Owns the window's `PictureInPictureController`. `PlayerWindowController` forwards the window's events to it
/// (`windowDidMiniaturize()`, `windowDidChangeOcclusionState()`, `windowDidDeminiaturize()`, `windowWillClose()`).
@MainActor
final class PictureInPictureWindowCoordinator {
    private let engine: PlayerEngine
    private let uiState: PlayerUIState
    private weak var window: NSWindow?
    /// Created with the coordinator, not on first toggle: it follows the engine from here on and prepares AVKit for
    /// the first video, and only then reports whether PiP can start (`uiState.isPictureInPicturePossible`).
    private let pictureInPicture: PictureInPictureController
    private var windowBehavior: PictureInPictureWindowBehavior = .hide
    private var pausesPlayback = false
    private var entersOnMinimize = false
    /// The window was ordered out by PiP and must come back when PiP ends.
    private var isWindowHidden = false
    /// PiP was started by minimizing the window, so restoring the window from the Dock ends it.
    private var isStartedFromMinimize = false
    /// PiP's restore, held back while the window comes out of the Dock.
    private var pendingRestore: (@MainActor () -> Void)?
    /// Ends `pendingRestore` if `windowDidDeminiaturize()` never comes; replaced by each restore, so an earlier one's
    /// cannot cut a later one short.
    private var restoreTimeout: Task<Void, Never>?
    /// Set by `windowWillClose()`; PiP callbacks that follow must not show the window again.
    private var isWindowClosing = false

    init(engine: PlayerEngine, uiState: PlayerUIState, window: NSWindow) {
        self.engine = engine
        self.uiState = uiState
        self.window = window
        pictureInPicture = PictureInPictureController(engine: engine)
        pictureInPicture.onPossibleChanged = { [weak self] isPossible in
            self?.uiState.isPictureInPicturePossible = isPossible
        }
        pictureInPicture.onActiveChanged = { [weak self] isActive in
            self?.activeChanged(isActive)
        }
        pictureInPicture.onRestoreUserInterface = { [weak self] windowReady in
            guard let self else {
                windowReady()
                return
            }
            restoreUserInterface(windowReady: windowReady)
        }
        uiState.togglePictureInPicture = { [weak self] in
            self?.toggle()
        }
    }

    func apply(_ settings: AppSettings) {
        windowBehavior = settings.pictureInPictureWindowBehavior
        pausesPlayback = settings.pausesOnPictureInPicture
        entersOnMinimize = settings.entersPictureInPictureOnMinimize
    }

    /// The engine's flag, for the menu and the control bar: set at `willStart`, before AVKit reports PiP active. The
    /// window events below check AVKit's (`pictureInPicture.isActive`), which `PictureInPictureController.toggle()`
    /// decides by: toggled on the engine's flag between `willStart` and `didStart`, they would start PiP again instead
    /// of stopping it. A menu toggle in that gap does ask AVKit to start again, which it should ignore.
    var isActive: Bool {
        engine.isPictureInPictureActive
    }

    var canToggle: Bool {
        engine.media.hasVideo && (uiState.isPictureInPicturePossible || engine.isPictureInPictureActive)
    }

    func toggle() {
        guard canToggle else { return }
        pictureInPicture.toggle()
    }

    // MARK: - Window events

    func windowDidMiniaturize() {
        guard entersOnMinimize, engine.media.hasVideo, engine.isPlaying, !pictureInPicture.isActive else { return }
        isStartedFromMinimize = true
        pictureInPicture.toggle()
    }

    /// Restoring from the Dock reports the window visible before the restore animation ends; stopping PiP here keeps
    /// it from mirroring the layer while the animation distorts it. `windowDidDeminiaturize()` stays as a fallback.
    func windowDidChangeOcclusionState() {
        guard isStartedFromMinimize, window?.occlusionState.contains(.visible) == true else { return }
        AppLog.debug(.ui, "Player window visible again; leaving minimize-started Picture in Picture")
        windowDidDeminiaturize()
    }

    func windowDidDeminiaturize() {
        finishRestore()
        guard isStartedFromMinimize else { return }
        isStartedFromMinimize = false
        if pictureInPicture.isActive {
            pictureInPicture.toggle()
        }
    }

    func windowWillClose() {
        // Stopping PiP below must not bring the closing window back.
        isWindowClosing = true
        isWindowHidden = false
        finishRestore()
        if pictureInPicture.isActive {
            pictureInPicture.toggle()
        }
    }

    // MARK: - PiP callbacks

    private func activeChanged(_ isActive: Bool) {
        if isActive {
            if pausesPlayback, engine.isPlaying {
                engine.pause()
            }
            moveWindowAside()
        } else {
            isStartedFromMinimize = false
            bringWindowBack()
        }
    }

    private func restoreUserInterface(windowReady: @escaping @MainActor () -> Void) {
        guard !isWindowClosing, let window else {
            windowReady()
            return
        }
        isStartedFromMinimize = false
        bringWindowBack()
        NSApp.activate()
        guard window.isMiniaturized else {
            window.makeKeyAndOrderFront(nil)
            windowReady()
            return
        }
        // PiP waits until the Dock restore animation is over, or it would animate into a window that is still flying
        // out of the Dock.
        pendingRestore = windowReady
        window.deminiaturize(nil)
        restoreTimeout?.cancel()
        restoreTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.finishRestore()
        }
    }

    /// Lets PiP animate into the window; runs once, from `windowDidDeminiaturize()`, `windowWillClose()` or the
    /// fallback timeout. A closing window stays closed, but PiP still gets its answer: AVKit waits for it.
    private func finishRestore() {
        guard let windowReady = pendingRestore else { return }
        pendingRestore = nil
        restoreTimeout?.cancel()
        restoreTimeout = nil
        if !isWindowClosing {
            window?.makeKeyAndOrderFront(nil)
        }
        windowReady()
    }

    private func moveWindowAside() {
        // Fullscreen and minimized windows are left alone, as in IINA.
        guard windowBehavior == .hide, let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized
        else { return }
        isWindowHidden = true
        window.orderOut(nil)
    }

    private func bringWindowBack() {
        guard let window, isWindowHidden, !isWindowClosing else { return }
        isWindowHidden = false
        window.makeKeyAndOrderFront(nil)
    }
}
