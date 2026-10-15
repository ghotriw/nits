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
@MainActor
final class PictureInPictureController: NSObject {
    private let engine: PlayerEngine
    /// Created on first use: the content source needs `self` as its playback delegate.
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

    /// Called on the main actor when PiP starts or stops.
    var onActiveChanged: ((Bool) -> Void)?
    /// Called when the user asks PiP to hand playback back to the player window. The host brings the window back
    /// and calls the closure once it is on screen; PiP then animates into it.
    var onRestoreUserInterface: ((_ windowReady: @escaping @MainActor () -> Void) -> Void)?
    /// Called on the main actor when AVKit reports whether PiP can start.
    var onPossibleChanged: ((Bool) -> Void)?

    var isActive: Bool { lazyController?.isPictureInPictureActive ?? false }

    init(engine: PlayerEngine) {
        self.engine = engine
        super.init()
    }

    private func makeControllerIfNeeded() -> AVPictureInPictureController? {
        if let lazyController { return lazyController }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            AppLog.info(.ui, "Picture in Picture is not supported on this system")
            return nil
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: engine.displayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
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
    func prepare() {
        _ = makeControllerIfNeeded()
    }

    func toggle() {
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

    /// Feeds the latest engine state to PiP. Cheap enough for the 20 Hz time observer: PiP is only told to re-read
    /// its state when playback paused, resumed or jumped away from the extrapolated position.
    func refreshSnapshot(invalidate force: Bool = false) {
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

extension PictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
    ) {
        Task { @MainActor in
            // PiP may act on a stale state; re-issuing play() to a playing engine restarts its pipeline (a stutter).
            if playing != self.engine.isPlaying {
                playing ? self.engine.play() : self.engine.pause()
            }
            self.refreshSnapshot(invalidate: true)
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
            self.engine.seekRelative(by: skipInterval.seconds, exact: false)
            self.refreshSnapshot(invalidate: true)
        }
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

extension PictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // Synchronously when possible: the start animation begins right after this returns.
        let start: @MainActor @Sendable () -> Void = {
            self.trackPanelSize(source: "willStart")
            self.engine.isPictureInPictureActive = true
            self.onActiveChanged?(true)
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
            // Fallback in case the panel did not exist yet at `willStart`; no-op once tracking.
            self.trackPanelSize(source: "didStart", warnIfMissing: true)
            // PiP caches the paused state from an earlier session or from before playback started.
            self.refreshSnapshot(invalidate: true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.stopTrackingPanelSize()
            self.engine.isPictureInPictureActive = false
            // The close button stops PiP without handing playback back to the window.
            if !self.isHandingBack, self.engine.isPlaying {
                self.engine.pause()
            }
            self.isHandingBack = false
            self.onActiveChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        AppLog.error(.ui, "Picture in Picture failed to start: \(error.localizedDescription)")
        Task { @MainActor in
            self.stopTrackingPanelSize()
            self.engine.isPictureInPictureActive = false
            self.onActiveChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            self.isHandingBack = true
            // AVKit animates the panel back onto the display layer's current frame, so the layer moves to the
            // video's rect (`handLayerBack`) right before that, once the window is back on screen; otherwise the
            // panel lands small in a corner and the video snaps to full size afterwards. Until then the layer
            // keeps matching the panel, which still shows the video.
            let windowReady: @MainActor () -> Void = {
                self.handLayerBack()
                completion(true)
            }
            if let onRestoreUserInterface = self.onRestoreUserInterface {
                onRestoreUserInterface(windowReady)
            } else {
                windowReady()
            }
        }
    }
}
