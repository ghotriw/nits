import AppKit
import Foundation
import MediaPlayer
import NitsCore
import Observation

#if canImport(NowPlaying)
    import NowPlaying
#endif

/// Common interface for coordinating media playback status with the system
/// (macOS Control Center / Menu Bar Now Playing and AirPods / Media Key controls).
@MainActor
public protocol NowPlayingController: AnyObject {
    var actions: (any PlayerActions)? { get set }
    var isKeyWindow: Bool { get set }
    func update(
        title: String,
        currentTime: Double,
        duration: Double,
        isPlaying: Bool,
        artworkData: Data?,
        artworkURL: URL?
    )
    func clear()
}

extension NowPlayingController {
    public func update(title: String, currentTime: Double, duration: Double, isPlaying: Bool) {
        update(
            title: title,
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            artworkData: nil,
            artworkURL: nil
        )
    }
}

/// Factory that selects the appropriate Now Playing implementation:
/// - macOS 27.0+: Modern Swift `NowPlaying` framework (`MediaSession`).
/// - Earlier macOS: Classic `MediaPlayer` framework (`MPNowPlayingInfoCenter` & `MPRemoteCommandCenter`).
@MainActor
public enum NowPlayingControllerFactory {
    public static func makeController(
        engine: any PlayerEngineProtocol,
        actions: (any PlayerActions)? = nil
    ) -> any NowPlayingController {
        #if canImport(NowPlaying)
            if #available(macOS 27.0, *) {
                return ModernNowPlayingController(engine: engine, actions: actions)
            }
        #endif
        return LegacyMediaPlayerController(engine: engine, actions: actions)
    }
}

// MARK: - Artwork Image Cache & Loader

actor NowPlayingArtworkLoader {
    static let shared = NowPlayingArtworkLoader()
    private let cache = NSCache<NSURL, NSData>()

    init(countLimit: Int = 50, totalCostLimit: Int = 50 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func load(from url: URL) async -> Data? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached as Data
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            let http = response as? HTTPURLResponse,
            http.statusCode >= 200 && http.statusCode < 300,
            !data.isEmpty
        else {
            return nil
        }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }
}

// MARK: - Throttler & Update Detection

/// Encapsulates throttling and update-detection logic for system Now Playing updates.
/// Filters out frequent 0.1s tick updates during normal 1x playback (allowing system timeline
/// extrapolation to run smoothly) while immediately forwarding play/pause state changes,
/// seek jumps (>1.5s difference from expected position), and periodic heartbeat refreshes (>=5s).
public struct NowPlayingThrottler: Sendable {
    public private(set) var lastReportedTime: Double = -1
    public private(set) var lastReportedTitle: String = ""
    public private(set) var lastReportedIsPlaying: Bool? = nil
    public private(set) var lastReportedPlaybackRate: Double = 1.0
    public private(set) var lastReportedDate: Date = .distantPast

    public init() {}

    /// Determines if an update should be dispatched to the system.
    /// If returning `true`, the internal state is updated to the provided values.
    public mutating func shouldUpdate(
        title: String,
        currentTime: Double,
        duration: Double,
        isPlaying: Bool,
        playbackRate: Double = 1.0,
        now: Date = Date()
    ) -> Bool {
        guard !title.isEmpty else { return false }

        let isStateChange =
            (isPlaying != lastReportedIsPlaying) || (title != lastReportedTitle)
            || (abs(playbackRate - lastReportedPlaybackRate) > 0.01)
        let elapsed = now.timeIntervalSince(lastReportedDate)
        let rateFactor = (lastReportedIsPlaying == true ? lastReportedPlaybackRate : 0.0)
        let expectedTime =
            lastReportedTime >= 0
            ? lastReportedTime + (elapsed * rateFactor)
            : currentTime
        let isSeeking = abs(currentTime - expectedTime) > 1.5
        let isHeartbeat = elapsed >= 5.0

        guard isStateChange || isSeeking || isHeartbeat else {
            return false
        }

        forceRecord(title: title, currentTime: currentTime, isPlaying: isPlaying, playbackRate: playbackRate, now: now)
        return true
    }

    /// Explicitly updates recorded state (e.g. following an immediate user seek command).
    public mutating func forceRecord(
        title: String,
        currentTime: Double,
        isPlaying: Bool,
        playbackRate: Double = 1.0,
        now: Date = Date()
    ) {
        lastReportedTitle = title
        lastReportedTime = currentTime
        lastReportedIsPlaying = isPlaying
        lastReportedPlaybackRate = playbackRate
        lastReportedDate = now
    }

    /// Resets all tracked state.
    public mutating func reset() {
        lastReportedTitle = ""
        lastReportedTime = -1
        lastReportedIsPlaying = nil
        lastReportedDate = .distantPast
    }
}

// MARK: - Modern Implementation (macOS 27.0+)

#if canImport(NowPlaying)
    /// Data model conforming to `MediaSessionRepresentable`.
    /// Separated from `ModernNowPlayingController` to avoid strong retain cycles with `MediaSession`.
    @available(macOS 27.0, *)
    @Observable
    @MainActor
    public final class ModernNowPlayingModel: MediaSessionRepresentable {
        public let id: String
        public var title: String = ""
        public var currentTime: Double = 0
        public var duration: Double = 0
        public var isPlaying: Bool = false
        public var playbackRate: Double = 1.0
        public var rawArtworkData: Data? = nil

        public var onTogglePlayPause: (() -> Void)?
        public var onPlay: (() -> Void)?
        public var onPause: (() -> Void)?
        public var onSeekToPosition: ((Double) -> Void)?
        public var onSkip: ((Double) -> Void)?

        public init(id: String = UUID().uuidString) {
            self.id = id
        }

        public var content: (any MediaContentRepresentable)? {
            guard !title.isEmpty else { return nil }
            let artwork: NowPlaying.Artwork?
            if let rawArtworkData {
                artwork = NowPlaying.Artwork(id: "\(id)-\(rawArtworkData.count)") { _ in
                    // NowPlaying.ArtworkRepresentation currently requires JPEG encoded image data
                    if let directRep = try? ArtworkRepresentation(data: rawArtworkData) {
                        return directRep
                    }
                    if let image = NSImage(data: rawArtworkData),
                        let tiff = image.tiffRepresentation,
                        let rep = NSBitmapImageRep(data: tiff),
                        let jpegData = rep.representation(using: .jpeg, properties: [:])
                    {
                        return try ArtworkRepresentation(data: jpegData)
                    }
                    throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
                }
            } else {
                artwork = nil
            }

            return MovieContent(
                id: title,
                title: title,
                duration: duration > 0 ? .finite(duration) : nil,
                artwork: artwork
            )
        }

        public var playbackSnapshot: MediaPlaybackSnapshot? {
            guard !title.isEmpty else { return nil }
            return MediaPlaybackSnapshot(
                state: isPlaying ? .playing(rate: Float(playbackRate)) : .paused,
                elapsedTime: max(0, currentTime),
                timestamp: .now
            )
        }

        public var commands: [MediaCommand] {
            [
                .togglePlayPause { [weak self] in
                    self?.onTogglePlayPause?()
                },
                .play { [weak self] in
                    self?.onPlay?()
                },
                .pause { [weak self] in
                    self?.onPause?()
                },
                .seekToPosition { [weak self] seconds in
                    self?.onSeekToPosition?(seconds)
                },
                .skipForward(preferredIntervals: [10]) { [weak self] interval in
                    let delta = interval > 0 ? interval : 10
                    self?.onSkip?(delta)
                },
                .skipBackward(preferredIntervals: [10]) { [weak self] interval in
                    let delta = interval > 0 ? interval : 10
                    self?.onSkip?(-delta)
                },
            ]
        }
    }

    @available(macOS 27.0, *)
    @MainActor
    public final class ModernNowPlayingController: NowPlayingController {
        public let model: ModernNowPlayingModel
        public weak var actions: (any PlayerActions)?
        public var isKeyWindow: Bool = true

        private weak var engine: (any PlayerEngineProtocol)?
        private var session: MediaSession<ModernNowPlayingModel>?
        private var activationTask: Task<Void, Never>?
        private var artworkFetchTask: Task<Void, Never>?
        private var throttler = NowPlayingThrottler()
        private var currentArtworkURL: URL?

        public init(
            engine: any PlayerEngineProtocol,
            actions: (any PlayerActions)? = nil,
            id: String = UUID().uuidString
        ) {
            self.engine = engine
            self.actions = actions
            let model = ModernNowPlayingModel(id: id)
            self.model = model

            model.onTogglePlayPause = { [weak self] in
                self?.executeTogglePlayPause()
            }

            model.onPlay = { [weak self] in
                self?.executePlay()
            }

            model.onPause = { [weak self] in
                self?.executePause()
            }

            model.onSeekToPosition = { [weak self] seconds in
                guard let self else { return }
                self.executeSeek(to: seconds)
                // Immediately sync model currentTime so the scrubber doesn't snap back when paused
                self.model.currentTime = seconds
                self.throttler.forceRecord(
                    title: self.throttler.lastReportedTitle,
                    currentTime: seconds,
                    isPlaying: self.model.isPlaying
                )
            }

            model.onSkip = { [weak self] delta in
                guard let self else { return }
                self.executeSkip(by: delta)
                if let engine = self.engine {
                    self.model.currentTime = engine.currentTime
                    self.throttler.forceRecord(
                        title: self.throttler.lastReportedTitle,
                        currentTime: engine.currentTime,
                        isPlaying: self.model.isPlaying
                    )
                }
            }
        }

        private func executeTogglePlayPause() {
            if let actions {
                actions.togglePlayPause()
            } else {
                engine?.togglePlayPause()
            }
        }

        private func executePlay() {
            if let actions {
                actions.play()
            } else {
                engine?.play()
            }
        }

        private func executePause() {
            if let actions {
                actions.pause()
            } else {
                engine?.pause()
            }
        }

        private func executeSeek(to seconds: Double) {
            if let actions {
                actions.seek(to: seconds)
            } else {
                engine?.seek(to: seconds)
            }
        }

        private func executeSkip(by delta: Double) {
            if let actions {
                actions.seekRelative(by: delta)
            } else {
                engine?.seekRelative(by: delta)
            }
        }

        public func update(
            title: String,
            currentTime: Double,
            duration: Double,
            isPlaying: Bool,
            artworkData: Data?,
            artworkURL: URL?
        ) {
            guard !title.isEmpty else {
                clear()
                return
            }

            resolveArtwork(data: artworkData, url: artworkURL)

            let currentRate = engine?.playbackRate ?? 1.0
            guard
                throttler.shouldUpdate(
                    title: title,
                    currentTime: currentTime,
                    duration: duration,
                    isPlaying: isPlaying,
                    playbackRate: currentRate
                )
            else {
                return
            }

            model.title = title
            model.currentTime = currentTime
            model.duration = duration
            model.isPlaying = isPlaying
            model.playbackRate = currentRate

            ensureActiveSession()
        }

        private func resolveArtwork(data: Data?, url: URL?) {
            if let data {
                if model.rawArtworkData != data {
                    model.rawArtworkData = data
                }
                artworkFetchTask?.cancel()
                artworkFetchTask = nil
                currentArtworkURL = nil
                return
            }

            guard let url else {
                return
            }

            if currentArtworkURL == url {
                return
            }
            currentArtworkURL = url

            artworkFetchTask?.cancel()
            artworkFetchTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let fetchedData = await NowPlayingArtworkLoader.shared.load(from: url)
                guard !Task.isCancelled, self.currentArtworkURL == url else { return }
                if let fetchedData {
                    self.model.rawArtworkData = fetchedData
                }
                self.artworkFetchTask = nil
            }
        }

        private func ensureActiveSession() {
            if session == nil {
                let newSession = MediaSession(model)
                self.session = newSession
                activationTask?.cancel()
                activationTask = Task { [weak self] in
                    try? await self?.session?.requestToBecomeApplicationPrimary()
                    self?.activationTask = nil
                }
            } else if let session, !session.isApplicationPrimary {
                guard activationTask == nil else { return }
                activationTask = Task { [weak self] in
                    try? await self?.session?.requestToBecomeApplicationPrimary()
                    self?.activationTask = nil
                }
            }
        }

        public func clear() {
            activationTask?.cancel()
            activationTask = nil
            artworkFetchTask?.cancel()
            artworkFetchTask = nil
            currentArtworkURL = nil

            model.title = ""
            model.rawArtworkData = nil
            model.isPlaying = false
            throttler.reset()

            // Removing reference deactivates the session from system Control Center
            session = nil
        }
    }
#endif

// MARK: - Legacy Fallback Implementation (macOS < 27.0 using MediaPlayer)

@MainActor
public final class LegacyMediaPlayerController: NowPlayingController {
    public weak var actions: (any PlayerActions)?
    public var isKeyWindow: Bool = true

    public private(set) var isActive: Bool = false {
        didSet {
            updateCommandsEnabledState()
        }
    }

    private weak var engine: (any PlayerEngineProtocol)?
    private var targets: [(command: MPRemoteCommand, target: Any)] = []
    private var throttler = NowPlayingThrottler()
    private var rawArtworkData: Data?
    private var currentArtworkURL: URL?
    private var artworkFetchTask: Task<Void, Never>?

    public init(
        engine: any PlayerEngineProtocol,
        actions: (any PlayerActions)? = nil
    ) {
        self.engine = engine
        self.actions = actions
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // 1. AirPods stem press & hardware media keys
        center.togglePlayPauseCommand.isEnabled = true
        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            return self.executeTogglePlayPause() ? .success : .noActionableNowPlayingItem
        }
        targets.append((center.togglePlayPauseCommand, toggleTarget))

        // 2. Play command
        center.playCommand.isEnabled = true
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            return self.executePlay() ? .success : .noActionableNowPlayingItem
        }
        targets.append((center.playCommand, playTarget))

        // 3. Pause command
        center.pauseCommand.isEnabled = true
        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            return self.executePause() ? .success : .noActionableNowPlayingItem
        }
        targets.append((center.pauseCommand, pauseTarget))

        // 4. Scrubber in macOS Control Center
        center.changePlaybackPositionCommand.isEnabled = true
        let posTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.isActive,
                let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else {
                return .commandFailed
            }
            let targetSeconds = positionEvent.positionTime
            guard self.executeSeek(to: targetSeconds) else { return .commandFailed }
            // Immediately sync so scrubber position doesn't bounce back on pause
            self.forceUpdateNowPlayingInfo(
                title: self.throttler.lastReportedTitle,
                currentTime: targetSeconds,
                duration: self.engine?.duration ?? 0,
                isPlaying: self.engine?.isPlaying ?? false
            )
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, posTarget))

        // 5. Skip forward
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.isEnabled = true
        let skipFwdTarget = center.skipForwardCommand.addTarget { [weak self] event in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            let step = interval > 0 ? interval : 10
            guard self.executeSkip(by: step) else { return .noActionableNowPlayingItem }
            if let engine = self.engine {
                self.forceUpdateNowPlayingInfo(
                    title: self.throttler.lastReportedTitle,
                    currentTime: engine.currentTime,
                    duration: engine.duration,
                    isPlaying: engine.isPlaying
                )
            }
            return .success
        }
        targets.append((center.skipForwardCommand, skipFwdTarget))

        // 6. Skip backward
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.isEnabled = true
        let skipBwdTarget = center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            let step = interval > 0 ? interval : 10
            guard self.executeSkip(by: -step) else { return .noActionableNowPlayingItem }
            if let engine = self.engine {
                self.forceUpdateNowPlayingInfo(
                    title: self.throttler.lastReportedTitle,
                    currentTime: engine.currentTime,
                    duration: engine.duration,
                    isPlaying: engine.isPlaying
                )
            }
            return .success
        }
        targets.append((center.skipBackwardCommand, skipBwdTarget))
    }

    private func executeTogglePlayPause() -> Bool {
        if let actions {
            actions.togglePlayPause()
            return true
        } else if let engine {
            engine.togglePlayPause()
            return true
        }
        return false
    }

    private func executePlay() -> Bool {
        if let actions {
            actions.play()
            return true
        } else if let engine {
            engine.play()
            return true
        }
        return false
    }

    private func executePause() -> Bool {
        if let actions {
            actions.pause()
            return true
        } else if let engine {
            engine.pause()
            return true
        }
        return false
    }

    private func executeSeek(to seconds: Double) -> Bool {
        if let actions {
            actions.seek(to: seconds)
            return true
        } else if let engine {
            engine.seek(to: seconds)
            return true
        }
        return false
    }

    private func executeSkip(by delta: Double) -> Bool {
        if let actions {
            actions.seekRelative(by: delta)
            return true
        } else if let engine {
            engine.seekRelative(by: delta)
            return true
        }
        return false
    }

    private func updateCommandsEnabledState() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = isActive
        center.playCommand.isEnabled = isActive
        center.pauseCommand.isEnabled = isActive
        center.changePlaybackPositionCommand.isEnabled = isActive
        center.skipForwardCommand.isEnabled = isActive
        center.skipBackwardCommand.isEnabled = isActive
    }

    public func update(
        title: String,
        currentTime: Double,
        duration: Double,
        isPlaying: Bool,
        artworkData: Data?,
        artworkURL: URL?
    ) {
        guard !title.isEmpty else {
            clear()
            return
        }

        resolveArtwork(data: artworkData, url: artworkURL)

        let currentRate = engine?.playbackRate ?? 1.0
        guard
            throttler.shouldUpdate(
                title: title,
                currentTime: currentTime,
                duration: duration,
                isPlaying: isPlaying,
                playbackRate: currentRate
            )
        else {
            return
        }

        forceUpdateNowPlayingInfo(
            title: title,
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }

    private func resolveArtwork(data: Data?, url: URL?) {
        if let data {
            let changed = (self.rawArtworkData != data)
            self.rawArtworkData = data
            artworkFetchTask?.cancel()
            artworkFetchTask = nil
            currentArtworkURL = nil
            if changed && isActive {
                forceUpdateNowPlayingInfo(
                    title: throttler.lastReportedTitle,
                    currentTime: throttler.lastReportedTime,
                    duration: engine?.duration ?? 0,
                    isPlaying: throttler.lastReportedIsPlaying ?? false
                )
            }
            return
        }

        guard let url else {
            return
        }

        if currentArtworkURL == url {
            return
        }
        currentArtworkURL = url

        artworkFetchTask?.cancel()
        artworkFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let fetchedData = await NowPlayingArtworkLoader.shared.load(from: url)
            guard !Task.isCancelled, self.currentArtworkURL == url else { return }
            if let fetchedData {
                self.rawArtworkData = fetchedData
                if self.isActive {
                    self.forceUpdateNowPlayingInfo(
                        title: self.throttler.lastReportedTitle,
                        currentTime: self.throttler.lastReportedTime,
                        duration: self.engine?.duration ?? 0,
                        isPlaying: self.throttler.lastReportedIsPlaying ?? false
                    )
                }
            }
            self.artworkFetchTask = nil
        }
    }

    private func forceUpdateNowPlayingInfo(
        title: String,
        currentTime: Double,
        duration: Double,
        isPlaying: Bool
    ) {
        isActive = true
        let currentRate = engine?.playbackRate ?? 1.0
        throttler.forceRecord(
            title: title,
            currentTime: currentTime,
            isPlaying: isPlaying,
            playbackRate: currentRate
        )

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? currentRate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = currentRate

        if let rawArtworkData, let image = NSImage(data: rawArtworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                image
            }
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info

        // macOS requirement: explicit playbackState is required for Control Center to sync correctly
        center.playbackState = isPlaying ? .playing : .paused
    }

    public func clear() {
        isActive = false
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        currentArtworkURL = nil
        rawArtworkData = nil
        throttler.reset()

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    isolated deinit {
        for item in targets {
            item.command.removeTarget(item.target)
        }
    }
}
