import AVKit
import AppKit
import NitsCore
import QuartzCore
import os

/// Playback state as Picture in Picture sees it, and its mapping onto PiP's clock.
///
/// The display layer has no `controlTimebase` of its own: it runs on the host clock at rate 1.0 and is never
/// paused (see the synchronizer note in `PlayerEngine`). PiP reads the position from that timebase, so the time
/// range is shifted into host time (`start = hostNow - position`). At other playback rates it is expressed in
/// wall-clock seconds at that rate (position and duration divided by the rate), which keeps progress and remaining
/// time right.
struct PictureInPicturePlaybackSnapshot: Sendable, Equatable {
    var mediaTime: Double = 0
    var hostTime: CFTimeInterval = 0
    var duration: Double = 0
    var isPlaying = false
    var rate: Double = 1.0

    /// Position extrapolated to `hostNow` (media seconds).
    func mediaTime(at hostNow: CFTimeInterval) -> Double {
        isPlaying ? mediaTime + (hostNow - hostTime) * rate : mediaTime
    }

    /// The range PiP shows, on the host clock; unbounded (live) when the duration is unknown.
    func timeRange(at hostNow: CFTimeInterval) -> CMTimeRange {
        guard duration > 0 else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        let rate = rate > 0 ? rate : 1.0
        return CMTimeRange(
            start: CMTime(seconds: hostNow - mediaTime(at: hostNow) / rate, preferredTimescale: 1_000_000),
            duration: CMTime(seconds: duration / rate, preferredTimescale: 1_000_000)
        )
    }

    /// Whether PiP must re-read its state: playback paused or resumed, the rate or duration changed, or the
    /// position jumped (a seek) more than half a second away from where `previous` extrapolates.
    func needsReport(after previous: Self, at hostNow: CFTimeInterval) -> Bool {
        previous.isPlaying != isPlaying || previous.rate != rate || previous.duration != duration
            || abs(previous.mediaTime(at: hostNow) - mediaTime) > 0.5
    }
}

/// Mirrors `PlayerEngine.displayLayer` into the system Picture in Picture window.
///
/// Follows the engine on its own (through observation): PiP's timeline and play / pause button track playback, and
/// AVKit is prepared once there is video. A host only toggles it and handles its window: `onActiveChanged` (hide or
/// keep the window while PiP runs), `onRestoreUserInterface` (bring it back) and `onPossibleChanged` (enable the
/// toggle). The window behaviour in `PlayerConfiguration` is `PlayerWindowController`'s; other hosts apply their own.
/// Subtitles drawn above the video are not part of the display layer, so PiP shows none.
@MainActor
public final class PictureInPictureController: NSObject {
    private let engine: PlayerEngine
    /// Created on first use (`prepare()`), with `delegateProxy` as its delegates.
    private var lazyController: AVPictureInPictureController?
    /// Read by the nonisolated playback delegate methods, which AVKit may call off the main thread.
    private let snapshot = OSAllocatedUnfairLock(initialState: PictureInPicturePlaybackSnapshot())
    /// Windows that existed before PiP started; the one that appears afterwards is the PiP panel.
    private var windowsBeforeStart: Set<ObjectIdentifier> = []
    private var panelResizeObserver: (any NSObjectProtocol)?
    /// The display layer is back at full size while PiP animates into the window.
    private var isLayerHandedBack = false
    /// Set when PiP hands playback back (restore button or our own stop); a stop without it is the close button.
    private var isHandingBack = false
    private var possibleObservation: NSKeyValueObservation?
    private lazy var delegateProxy = DelegateProxy(owner: self, snapshot: snapshot)

    /// Called on the main actor when PiP starts or stops.
    public var onActiveChanged: ((Bool) -> Void)?
    /// Called when the user asks PiP to hand playback back to the player window. The host brings the window back
    /// and calls the closure once it is on screen; PiP then animates into it. For a minimized window that is after
    /// the Dock restore animation (`windowDidDeminiaturize`, with a timeout in case it never comes), or PiP lands in a
    /// window still flying out of the Dock. Without this callback the closure runs right away.
    public var onRestoreUserInterface: ((_ windowReady: @escaping @MainActor () -> Void) -> Void)?
    /// Called on the main actor when AVKit reports whether PiP can start.
    public var onPossibleChanged: ((Bool) -> Void)?

    public var isActive: Bool { lazyController?.isPictureInPictureActive ?? false }
    /// The playback state PiP reads; for tests.
    var playbackSnapshot: PictureInPicturePlaybackSnapshot { snapshot.withLock { $0 } }
    /// Whether PiP can start now; `false` until AVKit is prepared (the first video plays) or without PiP support.
    public var isPossible: Bool { lazyController?.isPictureInPicturePossible ?? false }

    /// Can be created at any point, also with media already loaded: it starts from the engine's current state.
    public init(engine: PlayerEngine) {
        self.engine = engine
        super.init()
        engineDidChange()
    }

    /// Released while PiP runs, AVKit closes it without telling the (gone) delegate, so the engine is handed back
    /// here: otherwise it stays in PiP mode, with Metal tone mapping off and the display layer sized for the panel.
    isolated deinit {
        if let panelResizeObserver {
            NotificationCenter.default.removeObserver(panelResizeObserver)
        }
        if lazyController?.isPictureInPictureActive == true || panelResizeObserver != nil {
            engine.pictureInPictureLayerGeometry = nil
            engine.isPictureInPictureActive = false
        }
    }

    /// Re-registered after every change: `withObservationTracking` reports one change, before it is applied, so the
    /// state is read on the next main-actor turn, which also folds changes made together into one update. The
    /// position (20 updates a second) is followed only while PiP shows it; `toggle()` reads it when PiP starts.
    private func observeEngine() {
        withObservationTracking {
            _ = (engine.isPlaying, engine.playbackRate, engine.duration, engine.playbackState, engine.hasVideo)
            if engine.isPictureInPictureActive {
                _ = engine.currentTime
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.engineDidChange() }
        }
    }

    private func engineDidChange() {
        observeEngine()
        // PiP is told to re-read only on a pause, resume, rate change or jump (`needsReport`).
        refreshSnapshot()
        if engine.hasVideo, engine.playbackState == .playing || engine.playbackState == .paused {
            prepare()
        }
    }

    private func makeControllerIfNeeded() -> AVPictureInPictureController? {
        if let lazyController { return lazyController }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            AppLog.info(.ui, "Picture in Picture is not supported on this system")
            return nil
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: engine.displayLayer,
            playbackDelegate: delegateProxy
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = delegateProxy
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] _, change in
            let isPossible = change.newValue ?? false
            Task { @MainActor in self?.onPossibleChanged?(isPossible) }
        }
        lazyController = pip
        return pip
    }

    /// Creates the AVKit controller ahead of the first toggle. AVKit prepares a new content source asynchronously,
    /// and starting PiP right after creating it makes the first transition glitchy.
    private func prepare() {
        _ = makeControllerIfNeeded()
    }

    public func toggle() {
        guard let pip = makeControllerIfNeeded() else { return }
        if pip.isPictureInPictureActive {
            isHandingBack = true
            pip.stopPictureInPicture()
        } else {
            refreshSnapshot(invalidate: true)
            windowsBeforeStart = Set(NSApp.windows.map(ObjectIdentifier.init))
            pip.startPictureInPicture()
        }
    }

    /// macOS AVKit does not lay out the PiP panel for a sample buffer source (developer forums thread 821582; iOS is
    /// fine): its view keeps the panel's start size, the mirrored display layer is shown 1:1 instead of scaled, and
    /// an opaque, empty `…CALayerHostView` sits at a fixed offset over the video once the panel grows past it.
    /// So the display layer follows the panel's content size, and the broken pieces are fixed only when found
    /// broken — a fixed AVKit makes this a no-op.
    ///
    /// The panel is the window that appeared after `startPictureInPicture()`, looked for at `willStart` and again
    /// at `didStart`. Known limitation: on the first PiP after launch AVKit creates the panel late and animates it
    /// by transform, so the first frames of that start animation show the layer unscaled. Catching the panel
    /// earlier (polling the window list) was worse: it resizes the layer mid-transform and shows a double image.
    private func trackPanelSize(source: String, warnIfMissing: Bool = false) {
        guard panelResizeObserver == nil else { return }
        // AVKit's panel (`PIPPanel`) first; any other new window (a tooltip, say) only if it is not found.
        let newWindows = NSApp.windows.filter { !windowsBeforeStart.contains(ObjectIdentifier($0)) }
        guard let panel = newWindows.first(where: { "\(type(of: $0))".contains("PIP") }) ?? newWindows.first else {
            if warnIfMissing {
                AppLog.warning(.ui, "Picture in Picture panel not found; video will not follow its size")
            }
            return
        }
        AppLog.debug(.ui, "Picture in Picture panel found at \(source)")
        let apply: @MainActor (NSWindow) -> Void = { [weak self] window in
            guard let self, let content = window.contentView else { return }
            if !self.isLayerHandedBack {
                self.engine.pictureInPictureLayerGeometry = .pipWindow(content.bounds.size)
            }
            Self.repairPanelLayout(content)
        }
        apply(panel)
        panelResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { apply(window) }
        }
    }

    /// Right before PiP animates into the window, the display layer stops following the panel and covers the
    /// video's rect in the window, which the panel animates onto. A full-view layer would not do: AVKit animates the
    /// video at its own aspect ratio, so a layer of another one (a fullscreen window on a 16:10 screen) leaves a band
    /// beside it. The layer goes back to filling the view when PiP stops; the picture does not move.
    private func handLayerBack() {
        isLayerHandedBack = true
        engine.pictureInPictureLayerGeometry = .videoRect
    }

    private static func repairPanelLayout(_ content: NSView) {
        // Only AVKit's video view is stretched; anything else it may add at this level (controls) is left alone.
        for view in content.subviews
        where view.frame != content.bounds && "\(type(of: view))".contains("SampleBufferDisplayLayerView") {
            view.frame = content.bounds
            view.autoresizingMask = [.width, .height]
        }
        for view in allSubviews(of: content)
        where !view.isHidden && view.layer?.contents == nil && "\(type(of: view))".hasSuffix("CALayerHostView") {
            AppLog.debug(.ui, "Hiding empty \(type(of: view)) over the Picture in Picture video")
            view.isHidden = true
        }
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func stopTrackingPanelSize() {
        if let panelResizeObserver {
            NotificationCenter.default.removeObserver(panelResizeObserver)
        }
        panelResizeObserver = nil
        isLayerHandedBack = false
        engine.pictureInPictureLayerGeometry = nil
    }

    /// Feeds the latest engine state to PiP. Cheap enough for every time update: PiP is only told to re-read its
    /// state when playback paused, resumed or jumped away from the extrapolated position.
    private func refreshSnapshot(invalidate force: Bool = false) {
        let now = CACurrentMediaTime()
        let next = PictureInPicturePlaybackSnapshot(
            mediaTime: engine.currentTime,
            hostTime: now,
            duration: engine.duration,
            isPlaying: engine.isPlaying,
            rate: engine.playbackRate
        )
        let changed = snapshot.withLock { current -> Bool in
            defer { current = next }
            return next.needsReport(after: current, at: now)
        }
        if let pip = lazyController, force || (changed && pip.isPictureInPictureActive) {
            pip.invalidatePlaybackState()
        }
    }
}

extension PictureInPictureController {
    /// AVKit's delegates, kept off the controller's public interface. AVKit holds delegates weakly; the controller
    /// owns this. The nonisolated methods only read the snapshot, and reach the controller on the main actor.
    @MainActor
    fileprivate final class DelegateProxy: NSObject {
        weak var owner: PictureInPictureController?
        let snapshot: OSAllocatedUnfairLock<PictureInPicturePlaybackSnapshot>

        init(owner: PictureInPictureController, snapshot: OSAllocatedUnfairLock<PictureInPicturePlaybackSnapshot>) {
            self.owner = owner
            self.snapshot = snapshot
        }
    }
}

extension PictureInPictureController.DelegateProxy: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
    ) {
        Task { @MainActor in
            guard let owner = self.owner else { return }
            // PiP may act on a stale state. Forward only real changes: play() on a playing engine within 0.25 s of
            // the end restarts it from the beginning.
            if playing != owner.engine.isPlaying {
                playing ? owner.engine.play() : owner.engine.pause()
            }
            owner.refreshSnapshot(invalidate: true)
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        snapshot.withLock { $0 }.timeRange(at: CACurrentMediaTime())
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !snapshot.withLock { $0.isPlaying }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // Render size only matters for picking a stream variant; Nits decodes one rendition.
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime
    ) async {
        await MainActor.run {
            guard let owner = self.owner else { return }
            owner.engine.seekRelative(by: skipInterval.seconds, exact: false)
            owner.refreshSnapshot(invalidate: true)
        }
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

extension PictureInPictureController.DelegateProxy: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // Synchronously when possible: the start animation begins right after this returns.
        let start: @MainActor @Sendable () -> Void = {
            guard let owner = self.owner else { return }
            owner.trackPanelSize(source: "willStart")
            owner.engine.isPictureInPictureActive = true
            owner.onActiveChanged?(true)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(start)
        } else {
            Task { @MainActor in start() }
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            guard let owner = self.owner else { return }
            // Fallback in case the panel did not exist yet at `willStart`; no-op once tracking.
            owner.trackPanelSize(source: "didStart", warnIfMissing: true)
            // PiP caches the paused state from an earlier session or from before playback started.
            owner.refreshSnapshot(invalidate: true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            guard let owner = self.owner else { return }
            owner.stopTrackingPanelSize()
            owner.engine.isPictureInPictureActive = false
            // The close button stops PiP without handing playback back to the window.
            if !owner.isHandingBack, owner.engine.isPlaying {
                owner.engine.pause()
            }
            owner.isHandingBack = false
            owner.onActiveChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        AppLog.error(.ui, "Picture in Picture failed to start: \(error.localizedDescription)")
        Task { @MainActor in
            guard let owner = self.owner else { return }
            owner.stopTrackingPanelSize()
            owner.engine.isPictureInPictureActive = false
            owner.onActiveChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            guard let owner = self.owner else {
                completion(true)
                return
            }
            owner.isHandingBack = true
            // AVKit animates the panel back onto the display layer's current frame, so the layer moves to the
            // video's rect (`handLayerBack`) right before that, once the window is back on screen; otherwise the
            // panel lands small in a corner and the video snaps to full size afterwards. Until then the layer
            // keeps matching the panel, which still shows the video.
            let windowReady: @MainActor () -> Void = {
                owner.handLayerBack()
                completion(true)
            }
            if let onRestoreUserInterface = owner.onRestoreUserInterface {
                onRestoreUserInterface(windowReady)
            } else {
                windowReady()
            }
        }
    }
}
