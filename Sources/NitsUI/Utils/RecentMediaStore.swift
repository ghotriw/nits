import AppKit
import Foundation
import NitsCore
import Observation

/// Represents an item in the recent media list.
public struct RecentMediaItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { historyKey }

    /// Standardized file path (for local files) or URL string (for network streams).
    public let urlString: String

    /// Identifier matching `PlaybackHistoryStore` storage key generation.
    public let historyKey: String

    /// User-facing display title.
    public var title: String

    /// Total media duration in seconds.
    public var duration: Double

    /// Date when this media was last opened.
    public var lastPlayed: Date

    /// Whether this is a remote network stream (`http`/`https`) rather than a local file.
    public var isNetwork: Bool

    /// Optional HTTP request headers for remote network streams (e.g. Authorization, User-Agent).
    public var headers: [String: String]?

    public init(
        urlString: String,
        historyKey: String,
        title: String,
        duration: Double = 0,
        lastPlayed: Date = Date(),
        isNetwork: Bool,
        headers: [String: String]? = nil
    ) {
        self.urlString = urlString
        self.historyKey = historyKey
        self.title = title
        self.duration = duration
        self.lastPlayed = lastPlayed
        self.isNetwork = isNetwork
        self.headers = headers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.urlString = try container.decode(String.self, forKey: .urlString)
        self.historyKey = try container.decode(String.self, forKey: .historyKey)
        self.title = try container.decode(String.self, forKey: .title)
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        self.lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed) ?? Date()
        self.isNetwork = try container.decodeIfPresent(Bool.self, forKey: .isNetwork) ?? false
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
    }

    /// URL representing this media resource.
    public var url: URL? {
        if isNetwork {
            return URL(string: urlString)
        } else {
            return URL(fileURLWithPath: urlString)
        }
    }

    /// Secondary subtitle text for the UI (e.g. host for URLs, or filename if title differs).
    public var displaySubtitle: String? {
        if isNetwork {
            return url?.host ?? urlString
        }
        let fileName = URL(fileURLWithPath: urlString).lastPathComponent
        if title != fileName && !fileName.isEmpty {
            return fileName
        }
        let parentDir = URL(fileURLWithPath: urlString).deletingLastPathComponent().lastPathComponent
        return parentDir.isEmpty ? nil : parentDir
    }
}

/// Persistent store managing recently opened media items.
/// Observed by SwiftUI views (`WelcomeView`, `Open Recent` menu).
@Observable
@MainActor
public final class RecentMediaStore: Sendable {
    public typealias RecentDocumentsSyncHandler = @MainActor @Sendable ([URL]) -> Void

    public static let shared = RecentMediaStore(
        onRecentDocumentsChanged: { urls in
            NSDocumentController.shared.clearRecentDocuments(nil)
            for url in urls.reversed() where url.isFileURL {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
        }
    )
    public static let userDefaultsKey = "Nits.RecentMedia.v1"

    public let maxItemsLimit: Int

    @ObservationIgnored
    private let userDefaults: UserDefaults

    @ObservationIgnored
    private let historyStore: PlaybackHistoryStore

    @ObservationIgnored
    private let onRecentDocumentsChanged: RecentDocumentsSyncHandler?

    @ObservationIgnored
    nonisolated(unsafe) private var historyObserver: (any NSObjectProtocol)?

    /// All stored recent media items, ordered by last played date descending.
    public private(set) var items: [RecentMediaItem] = []

    /// Revision counter incremented when playback progress is saved or history is updated,
    /// triggering view updates for resume timestamps.
    public private(set) var progressRevision: Int = 0

    public init(
        userDefaults: UserDefaults = .standard,
        historyStore: PlaybackHistoryStore = .shared,
        maxItemsLimit: Int = 20,
        onRecentDocumentsChanged: RecentDocumentsSyncHandler? = nil
    ) {
        self.userDefaults = userDefaults
        self.historyStore = historyStore
        self.maxItemsLimit = maxItemsLimit
        self.onRecentDocumentsChanged = onRecentDocumentsChanged
        self.items = Self.loadItems(from: userDefaults)

        self.historyObserver = NotificationCenter.default.addObserver(
            forName: PlaybackHistoryStore.didChangeNotification,
            object: historyStore,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notifyProgressUpdated()
            }
        }
    }

    deinit {
        if let observer = historyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func syncRecentDocuments() {
        let urls = items.compactMap(\.url).filter(\.isFileURL)
        onRecentDocumentsChanged?(urls)
    }

    /// Records or updates an explicitly opened media item.
    /// Returns `true` if the item was recorded, or `false` if it was excluded by policy.
    @discardableResult
    public func record(
        url: URL,
        title: String,
        historyKey: String? = nil,
        sourcePath: String? = nil,
        duration: Double = 0,
        headers: [String: String]? = nil,
        lastPlayed: Date = Date(),
        exclusionPolicy: HistoryExclusionPolicy? = nil
    ) -> Bool {
        let isNetwork = MediaURL.isNetworkURL(url.absoluteString)
        let rawPath = isNetwork ? url.absoluteString : url.standardizedFileURL.path(percentEncoded: false)
        let mediaPath = MediaURL.normalizeMediaPath(rawPath)
        let key = historyKey ?? mediaPath
        let identity = MediaHistoryIdentity(historyKey: key, path: mediaPath, sourcePath: sourcePath)

        let policy = exclusionPolicy ?? historyStore.exclusionPolicy
        if policy.isExcluded(url: url) || policy.isExcluded(media: identity) {
            return false
        }

        let resolvedTitle: String
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            resolvedTitle = trimmedTitle
        } else {
            resolvedTitle = isNetwork ? (url.host ?? mediaPath) : url.lastPathComponent
        }

        // Remove existing item with matching history key or path
        items.removeAll { $0.historyKey == key || $0.urlString == mediaPath }

        let item = RecentMediaItem(
            urlString: mediaPath,
            historyKey: key,
            title: resolvedTitle,
            duration: duration,
            lastPlayed: lastPlayed,
            isNetwork: isNetwork,
            headers: Self.sanitizedHeaders(headers)
        )

        items.insert(item, at: 0)
        if items.count > maxItemsLimit {
            items = Array(items.prefix(maxItemsLimit))
        }

        save()
        syncRecentDocuments()
        return true
    }

    /// Sanitizes HTTP headers for persistence, stripping sensitive credentials such as Authorization and Cookie headers.
    private static func sanitizedHeaders(_ headers: [String: String]?) -> [String: String]? {
        guard let headers, !headers.isEmpty else { return nil }
        let sensitiveKeys: Set<String> = [
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
        ]
        let filtered = headers.filter { key, _ in
            !sensitiveKeys.contains(key.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return filtered.isEmpty ? nil : filtered
    }

    /// Updates total duration for an existing recent media item if it was 0 or changed.
    public func updateDuration(_ duration: Double, forHistoryKey historyKey: String) {
        guard duration > 0 else { return }
        guard let index = items.firstIndex(where: { $0.historyKey == historyKey }) else { return }
        if items[index].duration != duration {
            items[index].duration = duration
            save()
        }
    }

    /// Removes an item by its history key ID.
    public func remove(id: String) {
        let countBefore = items.count
        items.removeAll { $0.historyKey == id }
        if items.count < countBefore {
            save()
            syncRecentDocuments()
        }
    }

    /// Clears all stored recent items.
    public func clearAll() {
        items.removeAll()
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
        progressRevision += 1
        syncRecentDocuments()
    }

    /// Purges all recent items and their saved positions matching the given exclusion policy.
    public func purge(matching policy: HistoryExclusionPolicy) {
        var removedKeysAndPaths: [(key: String, path: String)] = []
        items.removeAll { item in
            let isExcluded =
                (item.url.map { policy.isExcluded(url: $0) } ?? false)
                || policy.isExcluded(pathOrURL: item.urlString)
                || policy.isExcluded(pathOrURL: item.historyKey)
            if isExcluded {
                removedKeysAndPaths.append((key: item.historyKey, path: item.urlString))
                return true
            }
            return false
        }
        if !removedKeysAndPaths.isEmpty {
            save()
            syncRecentDocuments()
        }
        historyStore.purge(matching: policy, knownKeysAndPaths: removedKeysAndPaths)
    }

    /// Notifies observers that playback progress or positions have been updated in `PlaybackHistoryStore`.
    public func notifyProgressUpdated() {
        progressRevision += 1
    }

    /// Checks if the item has an active saved resume position in `PlaybackHistoryStore`.
    /// Returns `(position, duration)` if eligible, or `nil` if completed or not started.
    public func resumeInfo(
        for item: RecentMediaItem,
        resumePlayback: Bool = true,
        startThreshold: Double = 15.0,
        endThresholdRatio: Double = 0.95
    ) -> (position: Double, duration: Double)? {
        guard resumePlayback else { return nil }

        guard
            let position = historyStore.savedPosition(
                for: MediaHistoryIdentity(historyKey: item.historyKey, path: item.urlString),
                startThreshold: startThreshold,
                endThresholdRatio: endThresholdRatio
            ), position > 0
        else {
            return nil
        }

        let effectiveDuration = item.duration > 0 ? item.duration : 0
        return (position: position, duration: effectiveDuration)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(items) {
            userDefaults.set(encoded, forKey: Self.userDefaultsKey)
        }
        progressRevision += 1
    }

    private struct LossyDecodable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws {
            self.value = try? T(from: decoder)
        }
    }

    private static func loadItems(from userDefaults: UserDefaults) -> [RecentMediaItem] {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
            let wrappers = try? JSONDecoder().decode([LossyDecodable<RecentMediaItem>].self, from: data)
        else { return [] }
        return wrappers.compactMap(\.value)
    }
}
