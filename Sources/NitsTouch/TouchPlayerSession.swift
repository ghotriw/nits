#if os(iOS)
    import NitsCore
    import Observation
    import SwiftUI

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

    /// Owns the engine of the iOS player and what has to follow the app's life: the file being played, which stays
    /// accessible while it plays, and the scene's phase.
    @Observable
    @MainActor
    public final class TouchPlayerSession {
        /// What the decoded-frame queue may hold on a phone (a 4K 10-bit frame is ~25 MB; a 4 GB phone's foreground limit is
        /// ~2 GB). A starting value; Task 6 of the iOS plan measures it.
        public static let frameQueueByteBudget = 300 << 20
        /// How far network sources are read ahead and kept behind; also a starting value.
        public static let readAheadLimits = MediaDemuxer.ReadAheadLimits(
            seconds: 30, bytes: 96 << 20, backBytes: 32 << 20)

        public let engine: PlayerEngine
        /// Why the last thing asked of the session could not be done (a string that is no network address).
        public var errorMessage: String?

        @ObservationIgnored private let access: any ScopedURLAccessing
        @ObservationIgnored private let hooks: any HostLifecycleHooks
        @ObservationIgnored private let loadPath: @MainActor (String) -> Void
        /// The file whose access is held: the one playing or loading.
        @ObservationIgnored private var heldURL: URL?
        @ObservationIgnored private var isInBackground = false

        /// For tests (and the one below): the seams are not API.
        ///
        /// - Parameters:
        ///   - engine: A test's own; by default one made with the iOS configuration (system render mode, byte budgets).
        ///   - hooks: Where the scene's phase goes; the engine by default.
        ///   - load: How a path is loaded; the engine's `load(path:)` by default.
        init(
            engine: PlayerEngine? = nil, access: any ScopedURLAccessing = SystemScopedURLAccess(),
            hooks: (any HostLifecycleHooks)? = nil, load: (@MainActor (String) -> Void)? = nil
        ) {
            let engine =
                engine
                ?? PlayerEngine(
                    configuration: PlayerConfiguration(
                        defaultRenderMode: .system, frameQueueByteBudget: Self.frameQueueByteBudget,
                        readAheadLimits: Self.readAheadLimits))
            self.engine = engine
            self.access = access
            self.hooks = hooks ?? engine
            self.loadPath = load ?? { [engine] path in engine.load(path: path) }
        }

        /// A session with an engine of the iOS configuration: system render mode and the byte budgets above.
        public convenience init() {
            self.init(engine: nil)
        }

        /// Plays a file. Its access is taken before the load and the previous file's let go of after the load has started,
        /// not before: the previous one is still being read until then.
        public func open(_ url: URL) {
            errorMessage = nil
            let previous = heldURL
            let started = access.start(url)
            loadPath(url.path)
            heldURL = started ? url : nil
            if let previous { access.stop(previous) }
        }

        /// Plays a network address (HLS, DASH, plain HTTP); `false`, with `errorMessage` set, for a string that is not an
        /// `http` or `https` address.
        @discardableResult
        public func openNetwork(_ string: String) -> Bool {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                url.host?.isEmpty == false
            else {
                errorMessage = "Enter an address that starts with http:// or https://."
                return false
            }
            errorMessage = nil
            loadPath(trimmed)
            releaseHeldURL()
            return true
        }

        /// Stops and lets go of the file.
        public func close() {
            engine.stop()
            releaseHeldURL()
        }

        /// The scene's phase: the engine hears of the background and of coming back from it. `.inactive` (Control Center, a
        /// banner, Split View) changes nothing: the app is still on screen and playing.
        public func scenePhaseChanged(_ phase: ScenePhase) {
            switch phase {
            case .background:
                guard !isInBackground else { return }
                isInBackground = true
                hooks.hostDidEnterBackground()
            case .active:
                guard isInBackground else { return }
                isInBackground = false
                hooks.hostWillEnterForeground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }

        private func releaseHeldURL() {
            if let heldURL { access.stop(heldURL) }
            heldURL = nil
        }
    }
#endif
