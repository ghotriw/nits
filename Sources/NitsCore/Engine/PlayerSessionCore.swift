import Foundation

/// What a session adds to the engine's events: Now Playing, recent media, the OSD. Called after the host's own
/// callback of the same event; every method has an empty default.
@MainActor
package protocol PlayerSessionSink: AnyObject {
    func mediaLoaded(request: MediaLoadRequest, historyKey: String, title: String, duration: Double)
    func timeUpdated(current: Double, duration: Double)
    func stateChanged(_ state: PlaybackState)
    func trackNavigationChanged()
    func relativeSeekResolved(offset: Double, at time: Double)
    /// `close()` or `end()` is about to stop the engine.
    func sessionClosing()
}

extension PlayerSessionSink {
    package func mediaLoaded(request: MediaLoadRequest, historyKey: String, title: String, duration: Double) {}
    package func timeUpdated(current: Double, duration: Double) {}
    package func stateChanged(_ state: PlaybackState) {}
    package func trackNavigationChanged() {}
    package func relativeSeekResolved(offset: Double, at time: Double) {}
    package func sessionClosing() {}
}

/// The part of a player's session that does not depend on the platform or on where the picture is shown: the owner of
/// the engine's single callbacks (`engine.onTimeUpdate`, `onPlaybackStateChanged`, … take one closure each, and the
/// core takes them in `init`: nothing else may set them afterwards), the host's callbacks made of them, `openStream`,
/// `close()` and `end()`. `PlayerSession` (macOS) and `TouchPlayerSession` (iOS) hold one and repeat its API under the
/// same names; it is not API itself, so it can change freely. Parts the platform adds (Now Playing, recent media, the
/// OSD) are `PlayerSessionSink`s.
@MainActor
package final class PlayerSessionCore {
    package let engine: PlayerEngine

    /// Called by `close()` (when something was opened since the last one) and by `end()`, before the engine stops:
    /// (finalTime, duration), the engine's.
    package var onClose: ((_ finalTime: Double, _ duration: Double) -> Void)?
    /// Periodic time observer callback: (currentTime, duration)
    package var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)?
    package var onPlaybackStateChanged: ((PlaybackState) -> Void)?
    /// Called when the media plays to its end.
    package var onPlaybackEnded: (() -> Void)?

    /// Set by `end()`: nothing opens afterwards.
    package private(set) var isEnded = false
    /// Inside `end()`, from before `onClose` is reported: a host that opens media from that callback gets nothing, as
    /// after the end (`isEnded` itself turns true only after it, for the host that reads it there).
    private var isEnding = false
    /// Whether a load is taken: not after the end, nor while it is reporting.
    package var acceptsLoads: Bool { !isEnded && !isEnding }

    /// Called with the button's `id` when an action button is pressed, by the user or by auto-press.
    package var onActionButton: ((_ id: String) -> Void)? {
        get { engine.actionButtons.onPress }
        set { engine.actionButtons.onPress = newValue }
    }

    /// Set by a host that keeps its own queue: Next and Previous call it instead of moving through the playlist, and
    /// the end of the media no longer plays the playlist's next item.
    package var onTrackNavigation: ((_ direction: TrackNavigationDirection) -> Void)? {
        get { engine.onTrackNavigation }
        set { engine.onTrackNavigation = newValue }
    }

    private var sinks: [any PlayerSessionSink] = []
    private var lastLoggedTimeSeconds: Double = -1.0
    /// Whether something was loaded since the last `close()`, a load that then failed included: the engine's own state
    /// cannot tell (a failed load leaves it neither loaded nor loading).
    private var hasOpenSinceClose = false
    /// Whether `close()` has reported `onClose` for what is open (cleared by the next load): the `end()` that follows
    /// it, a host's "done with the session", does not report again, with the engine stopped and its time and duration 0.
    private var hasReportedClose = false
    private let loadRequest: @MainActor (MediaLoadRequest) -> Void

    package convenience init(engine: PlayerEngine) {
        self.init(engine: engine, load: { [engine] request in engine.load(request) })
    }

    /// - Parameter load: Called in place of `engine.load(_:)`, after the `isEnded` check: the seam of tests.
    package init(engine: PlayerEngine, load: @escaping @MainActor (MediaLoadRequest) -> Void) {
        self.engine = engine
        self.loadRequest = load
        takeEngineCallbacks()
    }

    package func addSink(_ sink: any PlayerSessionSink) {
        sinks.append(sink)
    }

    // MARK: - Host's queue and buttons

    /// Replaces the action buttons of the media playing now, keeping those the engine resolved itself (SponsorBlock);
    /// the next load replaces them again.
    package func setActionButtons(_ buttons: [PlaybackActionButton]) {
        engine.actionButtons.setHostButtons(buttons)
    }

    /// Replaces what the host's queue has around the media playing now; the next load replaces it again.
    package func setTrackNavigation(_ navigation: TrackNavigation) {
        engine.trackNavigation = navigation
    }

    // MARK: - Loading and ending

    /// Loads `request`; `false` when the session has ended and nothing was loaded.
    @discardableResult
    package func load(_ request: MediaLoadRequest) -> Bool {
        guard acceptsLoads else { return false }
        hasOpenSinceClose = true
        hasReportedClose = false
        loadRequest(request)
        return true
    }

    /// Loads `url`; `false` when the session has ended and nothing was loaded.
    @discardableResult
    package func openStream(
        url: URL,
        title: String? = nil,
        artworkData: Data? = nil,
        artworkURL: URL? = nil,
        headers: [String: String] = [:],
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil,
        actionButtons: [PlaybackActionButton] = [],
        trackNavigation: TrackNavigation = TrackNavigation()
    ) -> Bool {
        load(
            MediaLoadRequest(
                path: MediaLoadRequest.path(for: url),
                title: title,
                artworkData: artworkData,
                artworkURL: artworkURL,
                headers: headers,
                startTime: startTime,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack,
                actionButtons: actionButtons,
                trackNavigation: trackNavigation
            ))
    }

    /// Stops the engine, reporting `onClose` first if something was opened since the last close. The session stays
    /// usable: a player's screen shows its empty state and opens the next media. A host that opens media from inside
    /// `onClose` keeps it: the engine is not stopped then, and `false` is returned (`true`: stopped).
    @discardableResult
    package func close() -> Bool {
        if hasOpenSinceClose {
            hasOpenSinceClose = false
            hasReportedClose = true
            reportClose()
            // Opened from the callback (the next episode): that is what plays now.
            if hasOpenSinceClose { return false }
        }
        for sink in sinks { sink.sessionClosing() }
        engine.stop()
        return true
    }

    /// Ends the session: reports `onClose` (whether or not anything was loaded; not again if `close()` has reported
    /// for what is open), stops the engine, and nothing opens afterwards. `beforeStopping` runs after the report,
    /// before the engine stops.
    package func end(beforeStopping: () -> Void = {}) {
        guard !isEnded, !isEnding else { return }
        isEnding = true
        if !hasReportedClose { reportClose() }
        isEnded = true
        isEnding = false
        hasOpenSinceClose = false
        beforeStopping()
        for sink in sinks { sink.sessionClosing() }
        engine.stop()
    }

    /// Saves the position and writes the history now: it otherwise writes a moment after a change, which a process
    /// that is quitting or suspended does not live to see.
    package func saveProgress() {
        engine.saveCurrentPlaybackProgress()
        engine.historyStore.flush()
    }

    private func reportClose() {
        let finalTime = engine.currentTime
        let finalDuration = engine.media.duration
        AppLog.info(
            .ui,
            "Player session ending for: '\(engine.mediaTitle)' at \(String(format: "%.2f", finalTime))s / \(String(format: "%.2f", finalDuration))s"
        )
        onClose?(finalTime, finalDuration)
    }

    // MARK: - The engine's callbacks

    private func takeEngineCallbacks() {
        engine.onMediaLoaded = { [weak self] request, historyKey, title, duration in
            guard let self else { return }
            for sink in self.sinks {
                sink.mediaLoaded(request: request, historyKey: historyKey, title: title, duration: duration)
            }
        }
        engine.onTimeUpdate = { [weak self] current, duration in
            guard let self else { return }
            if abs(current - self.lastLoggedTimeSeconds) >= 5.0 {
                self.lastLoggedTimeSeconds = current
                AppLog.debug(
                    .engine,
                    "Playback progress: \(String(format: "%.1f", current))s / \(String(format: "%.1f", duration))s"
                )
            }
            self.onTimeUpdate?(current, duration)
            for sink in self.sinks { sink.timeUpdated(current: current, duration: duration) }
        }
        engine.onPlaybackStateChanged = { [weak self] state in
            guard let self else { return }
            self.logState(state)
            self.onPlaybackStateChanged?(state)
            for sink in self.sinks { sink.stateChanged(state) }
            if state == .completed {
                AppLog.info(.engine, "Playback ended naturally")
                self.onPlaybackEnded?()
            }
        }
        engine.onTrackNavigationChanged = { [weak self] in
            guard let self else { return }
            for sink in self.sinks { sink.trackNavigationChanged() }
        }
        engine.onRelativeSeekResolved = { [weak self] actualOffset, completedTime in
            guard let self else { return }
            for sink in self.sinks { sink.relativeSeekResolved(offset: actualOffset, at: completedTime) }
        }
    }

    private func logState(_ state: PlaybackState) {
        switch state {
        case .idle:
            AppLog.info(.engine, "Playback state: idle")
        case .loading:
            AppLog.info(.engine, "Playback state: loading '\(engine.mediaTitle)'")
        case .playing:
            AppLog.info(.engine, "Playback state: playing at \(String(format: "%.2f", engine.currentTime))s")
        case .paused:
            AppLog.info(.engine, "Playback state: paused at \(String(format: "%.2f", engine.currentTime))s")
        case .completed:
            AppLog.info(.engine, "Playback state: completed (EOF reached)")
        case .failed(let error):
            AppLog.error(.engine, "Playback state: failed with error: '\(error)'")
        }
    }
}

extension MediaLoadRequest {
    /// The path `url` loads by: the address of a stream, the standardized path of a file.
    public static func path(for url: URL) -> String {
        MediaURL.isNetworkURL(url.absoluteString)
            ? url.absoluteString : url.standardizedFileURL.path(percentEncoded: false)
    }
}
