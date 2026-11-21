import Foundation

// MARK: - Artwork Image Cache & Loader

package actor NowPlayingArtworkLoader {
    package static let shared = NowPlayingArtworkLoader()
    private let cache = NSCache<NSURL, NSData>()

    package init(countLimit: Int = 50, totalCostLimit: Int = 50 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    package func load(from url: URL) async -> Data? {
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

/// The artwork Now Playing shows for the current media. The request's (`url`) wins; the data given with it (the
/// container's, which the engine falls back to) stands in while it loads and when it cannot be loaded. Media without
/// either shows none, never the previous media's. A host that gives both gets the URL's: the engine does not tell the
/// request's data from the container's.
@MainActor
package final class NowPlayingArtwork {
    /// What to show.
    package private(set) var data: Data?
    /// Called when a load that finished changed `data` (not for a change `resolve` reports).
    package var onLoaded: (() -> Void)?

    private var url: URL?
    private var loaded: Data?
    private var fallback: Data?
    private var loadTask: Task<Void, Never>?

    package init() {}

    /// Takes the artwork the media has now; returns whether `data` changed.
    @discardableResult
    package func resolve(data given: Data?, url: URL?) -> Bool {
        fallback = given
        if url != self.url {
            loadTask?.cancel()
            loadTask = nil
            loaded = nil
            self.url = url
            if let url { startLoading(url) }
        }
        return show(loaded ?? given)
    }

    package func clear() {
        loadTask?.cancel()
        loadTask = nil
        url = nil
        loaded = nil
        fallback = nil
        data = nil
    }

    private func startLoading(_ url: URL) {
        loadTask = Task { [weak self] in
            let fetched = await NowPlayingArtworkLoader.shared.load(from: url)
            guard let self, !Task.isCancelled, self.url == url else { return }
            self.loadTask = nil
            self.loaded = fetched
            if self.show(fetched ?? self.fallback) { self.onLoaded?() }
        }
    }

    private func show(_ newData: Data?) -> Bool {
        guard data != newData else { return false }
        data = newData
        return true
    }
}

// MARK: - Throttler & Update Detection

/// Encapsulates throttling and update-detection logic for system Now Playing updates.
/// Filters out frequent 0.1s tick updates during normal 1x playback (allowing system timeline
/// extrapolation to run smoothly) while immediately forwarding play/pause state changes,
/// seek jumps (>1.5s difference from expected position), and periodic heartbeat refreshes (>=5s).
package struct NowPlayingThrottler: Sendable {
    package private(set) var lastReportedTime: Double = -1
    package private(set) var lastReportedTitle: String = ""
    package private(set) var lastReportedIsPlaying: Bool? = nil
    package private(set) var lastReportedPlaybackRate: Double = 1.0
    package private(set) var lastReportedDate: Date = .distantPast

    package init() {}

    /// Determines if an update should be dispatched to the system.
    /// If returning `true`, the internal state is updated to the provided values.
    package mutating func shouldUpdate(
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
    package mutating func forceRecord(
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
    package mutating func reset() {
        lastReportedTitle = ""
        lastReportedTime = -1
        lastReportedIsPlaying = nil
        lastReportedDate = .distantPast
    }
}
