import CoreGraphics
import Foundation
import Observation
import os

/// Orchestrates in-memory caching, on-disk caching, and background generation of video thumbnails.
/// Conforms to Swift Observation `@Observable` to drive UI updates directly.
@Observable
@MainActor
public final class ThumbnailManager {
    /// In-memory array of sorted thumbnails by timestamp.
    public private(set) var thumbnails: [ThumbnailItem] = []
    /// Generation progress from 0.0 to 1.0.
    public private(set) var progress: Double = 0.0
    /// True while background worker is actively demuxing/decoding frames.
    public private(set) var isGenerating: Bool = false

    @ObservationIgnored
    private let diskCache: ThumbnailDiskCache
    @ObservationIgnored
    private var currentGenerator: ThumbnailGenerator?
    @ObservationIgnored
    private var currentTask: Task<Void, Never>?
    @ObservationIgnored
    private var currentPath: String?

    public init(diskCache: ThumbnailDiskCache = ThumbnailDiskCache()) {
        self.diskCache = diskCache
    }

    /// Clears any cached thumbnails and cancels any active background generation.
    public func reset() {
        currentTask?.cancel()
        currentTask = nil
        currentGenerator?.cancel()
        currentGenerator = nil
        currentPath = nil
        thumbnails.removeAll()
        progress = 0.0
        isGenerating = false
    }

    /// Prepares thumbnails asynchronously, offloading disk cache reads and writes to background utility priority.
    @discardableResult
    public func prepareThumbnailsAsync(
        for path: String,
        duration: Double,
        headers: [String: String] = [:],
        networkPolicy: NetworkThumbnailPolicy = .localNetworkOnly
    ) async -> [ThumbnailItem] {
        guard duration > 0 else {
            reset()
            return []
        }

        if currentPath == path && (!thumbnails.isEmpty || isGenerating) {
            return thumbnails
        }

        currentGenerator?.cancel()
        currentGenerator = nil
        thumbnails.removeAll()
        progress = 0.0
        isGenerating = false
        self.currentPath = path

        AppLog.info(
            .engine,
            "ThumbnailManager: Preparing thumbnails for '\(path)' (duration: \(String(format: "%.1f", duration))s)")

        let diskCache = self.diskCache

        // Check on-disk cache in background
        let cachedItems: [ThumbnailItem]? = await Task.detached(priority: .utility) { [diskCache] in
            guard let key = diskCache.cacheKey(for: path) else { return nil }
            return diskCache.loadThumbnails(for: key)
        }.value

        guard currentPath == path, !Task.isCancelled else { return [] }

        if let cachedItems, !cachedItems.isEmpty {
            let sorted = cachedItems.sorted { $0.time < $1.time }
            self.thumbnails = sorted
            self.progress = 1.0
            self.isGenerating = false
            AppLog.info(.engine, "ThumbnailManager: Loaded \(sorted.count) cached thumbnails for '\(path)'")
            return sorted
        }

        // Check network policy if path is a remote stream
        if MediaDemuxer.isNetworkURL(path) {
            let shouldGenerate: Bool
            switch networkPolicy {
            case .always:
                shouldGenerate = true
            case .never:
                shouldGenerate = false
            case .localNetworkOnly:
                shouldGenerate = MediaDemuxer.isLocalNetworkURL(path)
            }

            if !shouldGenerate {
                AppLog.debug(
                    .engine,
                    "ThumbnailManager: Skipping network stream thumbnail generation for '\(path)' (policy: \(networkPolicy.rawValue))"
                )
                return []
            } else {
                AppLog.info(
                    .engine,
                    "ThumbnailManager: Generating thumbnails for network stream (policy: \(networkPolicy.rawValue), isLAN: \(MediaDemuxer.isLocalNetworkURL(path)))"
                )
            }
        }

        // Launch low-priority background generation
        AppLog.info(.engine, "ThumbnailManager: Starting background thumbnail generation for '\(path)'")
        let generator = ThumbnailGenerator(path: path, duration: duration, headers: headers)
        self.currentGenerator = generator
        self.isGenerating = true
        self.progress = 0.0

        let result = await generator.generateThumbnails { [weak self, path, duration] partial in
            Task { @MainActor [weak self] in
                guard let self, self.currentPath == path, !Task.isCancelled else { return }
                self.thumbnails = partial.sorted { $0.time < $1.time }
                if duration > 0, let last = self.thumbnails.last {
                    self.progress = min(1.0, max(0.0, last.time / duration))
                }
            }
        }

        guard !Task.isCancelled, !generator.isCancelled, currentPath == path else {
            AppLog.debug(.engine, "ThumbnailManager: Generation cancelled or superseded for '\(path)'")
            return []
        }

        // Save to disk cache asynchronously in background
        if !result.isEmpty {
            Task.detached(priority: .background) { [diskCache] in
                if let cacheKey = diskCache.cacheKey(for: path) {
                    diskCache.saveThumbnails(result, for: cacheKey)
                }
            }
        }

        let sorted = result.sorted { $0.time < $1.time }
        self.thumbnails = sorted
        self.progress = 1.0
        self.isGenerating = false
        AppLog.info(.engine, "ThumbnailManager: Successfully generated \(sorted.count) thumbnails for '\(path)'")
        return sorted
    }

    /// Loads cached thumbnails or initiates background generation without blocking the caller.
    public func prepareThumbnails(
        for path: String,
        duration: Double,
        headers: [String: String] = [:],
        networkPolicy: NetworkThumbnailPolicy = .localNetworkOnly
    ) {
        if currentPath == path && (!thumbnails.isEmpty || isGenerating) {
            return
        }
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.prepareThumbnailsAsync(
                for: path,
                duration: duration,
                headers: headers,
                networkPolicy: networkPolicy
            )
        }
    }

    /// Finds the closest thumbnail for a given timestamp using binary search.
    public func thumbnail(at seconds: Double) -> ThumbnailItem? {
        guard !thumbnails.isEmpty else { return nil }

        var low = 0
        var high = thumbnails.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let item = thumbnails[mid]
            if item.time < seconds {
                low = mid + 1
            } else if item.time > seconds {
                high = mid - 1
            } else {
                return item
            }
        }

        // Clamp between low and high
        if low >= thumbnails.count {
            return thumbnails.last
        }
        if high < 0 {
            return thumbnails.first
        }

        let leftDiff = abs(thumbnails[high].time - seconds)
        let rightDiff = abs(thumbnails[low].time - seconds)
        return leftDiff <= rightDiff ? thumbnails[high] : thumbnails[low]
    }
}
