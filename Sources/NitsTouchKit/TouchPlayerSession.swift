#if os(iOS)
    import Foundation
    import NitsCore
    import Observation

    /// What the session tells the engine about the app's life; the engine's own methods, a recording fake in tests.
    @MainActor
    protocol HostLifecycleHooks: AnyObject {
        func hostDidEnterBackground()
        func hostWillEnterForeground()
    }

    extension PlayerEngine: HostLifecycleHooks {}

    /// Access to a file outside the app's sandbox, which Files hands over only for as long as it is held.
    @MainActor
    protocol ScopedURLAccessing {
        /// `false` for a URL that needs no access (the app's own files).
        func start(_ url: URL) -> Bool
        func stop(_ url: URL)
    }

    @MainActor
    struct SystemScopedURLAccess: ScopedURLAccessing {
        func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
        func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    }

    /// The phase of the host's scene, as the session needs it (SwiftUI's `ScenePhase` without SwiftUI: the Kit has no views, and a
    /// UIKit host maps its own scene states). `NitsTouchUI` converts `ScenePhase`.
    public enum HostScenePhase: Sendable {
        case active, inactive, background
    }

    /// The session of the iOS player: owns the engine and what has to follow the app's life (the file being played,
    /// which stays accessible while it plays, and the scene's phase), and gives a host app what `PlayerSession` gives a
    /// macOS host: `openStream`, the callbacks, action buttons and the host's Next / Previous.
    ///
    /// Owns the engine's callbacks (`engine.onTimeUpdate`, `onPlaybackStateChanged`, … are single closures, and the
    /// session takes them): a host subscribes through the session's own callbacks, never on `engine`.
    @Observable
    @MainActor
    public final class TouchPlayerSession {
        /// What the decoded-frame queue may hold on a phone (a 4K 10-bit frame is ~25 MB; a 4 GB phone's foreground limit is
        /// ~2 GB). A starting value; Task 6 of the iOS plan measures it.
        public static let frameQueueByteBudget = 300 << 20
        /// How far network sources are read ahead and kept behind; also a starting value.
        public static let readAheadLimits = MediaDemuxer.ReadAheadLimits(
            seconds: 30, bytes: 96 << 20, backBytes: 32 << 20)

        /// The engine's configuration of the iOS player (system render mode, the byte budgets above): what a host
        /// starts from when it changes one setting.
        public static var defaultConfiguration: PlayerConfiguration {
            PlayerConfiguration(
                defaultRenderMode: .system, frameQueueByteBudget: frameQueueByteBudget,
                readAheadLimits: readAheadLimits)
        }

        public let engine: PlayerEngine
        /// Why the last thing asked of the session could not be done (a string that is no network address).
        public var errorMessage: String?

        /// Decides when the action button is on screen and when it presses itself; `ActionButtonView` feeds it.
        @ObservationIgnored package let actionButton = ActionButtonPresenter()

        /// Seconds of playback an action button stays up on its own, then it shows only with the controls.
        public var actionButtonDisplayDuration: Double {
            get { actionButton.displayDuration }
            set { actionButton.displayDuration = newValue }
        }
        /// Whether an action button that allows it presses itself when its display time runs out.
        public var actionButtonAutoPress: Bool {
            get { actionButton.autoPress }
            set { actionButton.autoPress = newValue }
        }

        @ObservationIgnored private let core: PlayerSessionCore
        @ObservationIgnored private let access: any ScopedURLAccessing
        @ObservationIgnored private let hooks: any HostLifecycleHooks
        @ObservationIgnored private let saveProgress: @MainActor () -> Void
        /// The file whose access is held: the one playing or loading.
        @ObservationIgnored private var heldURL: URL?
        @ObservationIgnored private var isInBackground = false

        /// For tests (and the one below): the seams are not API.
        ///
        /// - Parameters:
        ///   - engine: The engine the session owns.
        ///   - hooks: Where the scene's phase goes; the engine by default.
        ///   - load: How a request is loaded; the engine's `load(_:)` by default.
        ///   - saveProgress: What writes the position and the history when the app goes to the background; the core's
        ///     `saveProgress()` by default.
        init(
            engine: PlayerEngine, access: any ScopedURLAccessing = SystemScopedURLAccess(),
            hooks: (any HostLifecycleHooks)? = nil, load: (@MainActor (MediaLoadRequest) -> Void)? = nil,
            saveProgress: (@MainActor () -> Void)? = nil
        ) {
            let core =
                load.map { PlayerSessionCore(engine: engine, load: $0) } ?? PlayerSessionCore(engine: engine)
            self.engine = engine
            self.core = core
            self.access = access
            self.hooks = hooks ?? engine
            self.saveProgress = saveProgress ?? { [core] in core.saveProgress() }
            // Now Playing and the remote commands (AirPods, the lock screen): a sink of the core, as on macOS.
            core.addSink(TouchNowPlaying(engine: engine))
        }

        /// A session with an engine of the iOS configuration.
        ///
        /// - Parameters:
        ///   - configuration: The engine's settings; `defaultConfiguration` to start from.
        ///   - historyStore: Where playback positions and per-media preferences are kept; `nil` for the app's own file.
        ///     A host that keeps its own progress passes `PlaybackHistoryStore(fileURL: nil)`.
        public convenience init(
            configuration: PlayerConfiguration = TouchPlayerSession.defaultConfiguration,
            historyStore: PlaybackHistoryStore? = nil
        ) {
            self.init(engine: PlayerEngine(configuration: configuration, historyStore: historyStore))
        }

        // MARK: - Callbacks

        /// Called by `close()` (when something was opened since the last one) and by `end()`, before the engine
        /// stops: (finalTime, duration), the engine's. A host that saves progress reads `engine.playbackProgress` here.
        public var onClose: ((_ finalTime: Double, _ duration: Double) -> Void)? {
            get { core.onClose }
            set { core.onClose = newValue }
        }
        /// Periodic time observer callback: (currentTime, duration)
        public var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)? {
            get { core.onTimeUpdate }
            set { core.onTimeUpdate = newValue }
        }
        /// Playback state change callback
        public var onPlaybackStateChanged: ((PlaybackState) -> Void)? {
            get { core.onPlaybackStateChanged }
            set { core.onPlaybackStateChanged = newValue }
        }
        /// Dedicated callback when video finishes playing to the end
        public var onPlaybackEnded: (() -> Void)? {
            get { core.onPlaybackEnded }
            set { core.onPlaybackEnded = newValue }
        }
        /// Called with the button's `id` when an action button is pressed, by the user or by auto-press.
        public var onActionButton: ((_ id: String) -> Void)? {
            get { core.onActionButton }
            set { core.onActionButton = newValue }
        }
        /// Set by a host that keeps its own queue (a media server client's series): Next and Previous call it instead
        /// of moving through the playlist, and the end of the media no longer plays the playlist's next item. The host
        /// answers by opening the item it moves to; `onPlaybackEnded` is the signal to play the next one.
        public var onTrackNavigation: ((_ direction: TrackNavigationDirection) -> Void)? {
            get { core.onTrackNavigation }
            set { core.onTrackNavigation = newValue }
        }

        /// Replaces the action buttons of the media playing now, preserving any resolved buttons; the next load
        /// replaces them again (see `openStream(actionButtons:)`).
        public func setActionButtons(_ buttons: [PlaybackActionButton]) {
            core.setActionButtons(buttons)
        }

        /// Replaces what the host's queue has around the media playing now, e.g. once the host learns the next episode;
        /// the next load replaces it again (see `openStream(trackNavigation:)`).
        public func setTrackNavigation(_ navigation: TrackNavigation) {
            core.setTrackNavigation(navigation)
        }

        /// Set by `end()`, after its `onClose`; opens that follow do nothing. Stored here, not read from the core, so
        /// that a view that shows it is redrawn when the session ends.
        public private(set) var isEnded = false

        // MARK: - Opening

        /// Plays a file. Its access is taken before the load and the previous file's let go of after the load has started,
        /// not before: the previous one is still being read until then.
        public func open(_ url: URL) {
            openStream(url: url)
        }

        /// Loads `url`: a file (from Files too: its access is held while it plays) or a stream, with what the host
        /// knows of it. Does nothing once the session has ended.
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
            trackNavigation: TrackNavigation = TrackNavigation()
        ) {
            guard core.acceptsLoads else { return }
            errorMessage = nil
            let previous = heldURL
            let started = url.isFileURL && access.start(url)
            core.openStream(
                url: url, title: title, artworkData: artworkData, artworkURL: artworkURL, headers: headers,
                startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack,
                actionButtons: actionButtons, trackNavigation: trackNavigation)
            heldURL = started ? url : nil
            if let previous { access.stop(previous) }
        }

        /// Loads a whole request: what `openStream` leaves out (`audioFiles`, `subtitleFiles`, `httpRequestSize`).
        /// Takes no file access: a file from Files opens through `open(_:)` / `openStream(url:)`, and the access of
        /// the request's `audioFiles` and `subtitleFiles` is the host's to keep while they are read. The access of a
        /// file opened that way stays held if the request loads it again. Does nothing once the session has ended.
        public func load(_ request: MediaLoadRequest) {
            guard core.load(request) else { return }
            errorMessage = nil
            if let heldURL, !Self.isSameFile(request.path, as: heldURL) { releaseHeldURL() }
        }

        /// Whether `path` names the file of `url`, however either is written (`..`, `/var` for `/private/var`).
        private static func isSameFile(_ path: String, as url: URL) -> Bool {
            // Paths, not URLs: a URL's equality counts its base URL, which a relative path gets from the working directory.
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
        }

        /// Plays a network address (HLS, DASH, plain HTTP); `false`, with `errorMessage` set, for a string that is not an
        /// `http` or `https` address.
        @discardableResult
        public func openNetwork(_ string: String) -> Bool {
            guard core.acceptsLoads else { return false }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                url.host?.isEmpty == false
            else {
                errorMessage = "Enter an address that starts with http:// or https://."
                return false
            }
            openStream(url: url)
            return true
        }

        // MARK: - Closing

        /// Stops and lets go of the file, reporting `onClose` when something was opened. What the control bar's X and the
        /// error alert's "Close" do; the session stays usable, and opens the next media.
        public func close() {
            // Not when the host opened the next media from `onClose`: its file is the one held now.
            if core.close() { releaseHeldURL() }
        }

        /// Ends the session: reports `onClose`, stops the engine and lets go of the file. Later opens do nothing.
        public func end() {
            core.end()
            isEnded = core.isEnded
            releaseHeldURL()
        }

        /// The scene's phase: the engine hears of the background and of coming back from it. `.inactive` (Control Center, a
        /// banner, Split View) changes nothing: the app is still on screen and playing.
        ///
        /// Going to the background, the engine hears of it first (pausing saves the position), and then the history is
        /// written: the app is suspended before the history's own delayed write.
        public func scenePhaseChanged(_ phase: HostScenePhase) {
            switch phase {
            case .background:
                guard !isInBackground else { return }
                isInBackground = true
                hooks.hostDidEnterBackground()
                saveProgress()
            case .active:
                guard isInBackground else { return }
                isInBackground = false
                hooks.hostWillEnterForeground()
            case .inactive:
                break
            }
        }

        private func releaseHeldURL() {
            if let heldURL { access.stop(heldURL) }
            heldURL = nil
        }
    }
#endif
