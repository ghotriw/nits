import Foundation
import os

/// Durations of media seen before (probed or played), persisted under
/// `~/Library/Caches/Nits/MediaDurations.json` so a reopened playlist shows its lengths at once.
///
/// Local files are keyed by path, size and modification date, so a replaced file is probed again;
/// network URLs by the URL without query or fragment (as in `PlaybackHistoryStore`).
/// Lookups stat local files and the first one loads the file: call off the main actor.
public final class MediaDurationCache: Sendable {
    public static let shared = MediaDurationCache()

    private static let maxEntries = 20_000

    private struct Entry: Codable {
        var duration: Double
        var lastUsed: Date
    }

    private struct State {
        /// `nil` until first use.
        var entries: [String: Entry]?
        var isSaveScheduled = false
    }

    private let fileURL: URL?
    private let saveDelay: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - fileURL: Where to persist; `nil` keeps the cache in memory only.
    ///   - saveDelay: How long to batch writes before saving.
    public init(fileURL: URL? = MediaDurationCache.defaultFileURL, saveDelay: Duration = .seconds(2)) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
    }

    public static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nits", isDirectory: true)
            .appendingPathComponent("MediaDurations.json")
    }

    /// The whole-file duration recorded for `url`, if any.
    public func duration(for url: URL) -> Double? {
        guard let key = Self.key(for: url) else { return nil }
        let loaded = loadIfNeeded()
        return state.withLock { state in
            if state.entries == nil {
                state.entries = loaded
            }
            guard var entry = state.entries?[key] else { return nil }
            entry.lastUsed = Date()
            state.entries?[key] = entry
            return entry.duration
        }
    }

    /// Records the whole-file duration of `url`.
    public func store(_ duration: Double, for url: URL) {
        guard duration > 0, duration.isFinite, let key = Self.key(for: url) else { return }
        let loaded = loadIfNeeded()
        let shouldScheduleSave = state.withLock { state in
            if state.entries == nil {
                state.entries = loaded
            }
            state.entries?[key] = Entry(duration: duration, lastUsed: Date())
            defer { state.isSaveScheduled = true }
            return !state.isSaveScheduled
        }
        guard shouldScheduleSave, fileURL != nil else { return }
        // Batch the writes of a probing run into one.
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: saveDelay)
            save()
        }
    }

    private static func key(for url: URL) -> String? {
        if url.isFileURL {
            let fileURL = url.standardizedFileURL
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                let size = values.fileSize, let modified = values.contentModificationDate
            else { return nil }
            return "\(fileURL.path)|\(size)|\(modified.timeIntervalSince1970)"
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        return components.string
    }

    /// Reads the file on first use, outside the lock; empty when absent or unreadable.
    private func loadIfNeeded() -> [String: Entry] {
        guard state.withLock({ $0.entries == nil }) else { return [:] }
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot: [String: Entry] = state.withLock { state in
            state.isSaveScheduled = false
            guard var entries = state.entries else { return [:] }
            if entries.count > Self.maxEntries {
                let stale = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
                    .prefix(entries.count - Self.maxEntries)
                for (key, _) in stale {
                    entries.removeValue(forKey: key)
                }
                state.entries = entries
            }
            return entries
        }
        guard !snapshot.isEmpty, let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.warning(.playlist, "Could not save media duration cache: \(error.localizedDescription)")
        }
    }
}
