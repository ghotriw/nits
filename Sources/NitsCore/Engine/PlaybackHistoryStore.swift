import CryptoKit
import Foundation
import os

/// Represents a persistent playback progress record for a media resource.
public struct PlaybackRecord: Codable, Sendable, Equatable {
    public let position: Double
    public let duration: Double
    public let lastUpdated: Date
    /// Selected audio track id (`nil` if unknown / not recorded).
    public let audioTrackId: Int?
    /// Selected subtitle track id. `nil` means no recorded preference; `PlaybackRecord.subtitlesOff` means disabled,
    /// `PlaybackRecord.externalSubtitle` the file at `externalSubtitlePath`.
    public let subtitleTrackId: Int?
    /// Subtitle delay in seconds (`nil` if never set).
    public let subtitleDelay: Double?
    /// Path of the selected external subtitle file, when `subtitleTrackId` is `externalSubtitle`.
    public let externalSubtitlePath: String?

    /// Sentinel value for `subtitleTrackId` meaning the user explicitly disabled subtitles.
    public static let subtitlesOff = -1
    /// Sentinel value for `subtitleTrackId` meaning the external subtitle file at `externalSubtitlePath`.
    public static let externalSubtitle = -2

    public init(
        position: Double,
        duration: Double,
        lastUpdated: Date = Date(),
        preferences: PlaybackPreferences = PlaybackPreferences()
    ) {
        self.position = position
        self.duration = duration
        self.lastUpdated = lastUpdated
        self.audioTrackId = preferences.audioTrackId
        self.subtitleTrackId = preferences.subtitleTrackId
        self.subtitleDelay = preferences.subtitleDelay
        self.externalSubtitlePath = preferences.externalSubtitlePath
    }

    public var preferences: PlaybackPreferences {
        PlaybackPreferences(
            audioTrackId: audioTrackId,
            subtitleTrackId: subtitleTrackId,
            subtitleDelay: subtitleDelay,
            externalSubtitlePath: externalSubtitlePath
        )
    }
}

/// Per-file preferences restored on load, independent of the resume position. When saving, a `nil` field keeps the
/// previously saved value.
public struct PlaybackPreferences: Sendable, Equatable {
    public var audioTrackId: Int?
    /// See `PlaybackRecord.subtitleTrackId`.
    public var subtitleTrackId: Int?
    public var subtitleDelay: Double?
    public var externalSubtitlePath: String?

    public init(
        audioTrackId: Int? = nil,
        subtitleTrackId: Int? = nil,
        subtitleDelay: Double? = nil,
        externalSubtitlePath: String? = nil
    ) {
        self.audioTrackId = audioTrackId
        self.subtitleTrackId = subtitleTrackId
        self.subtitleDelay = subtitleDelay
        self.externalSubtitlePath = externalSubtitlePath
    }

    /// These preferences with the fields left `nil` taken from `saved`.
    func merged(over saved: PlaybackPreferences?) -> PlaybackPreferences {
        PlaybackPreferences(
            audioTrackId: audioTrackId ?? saved?.audioTrackId,
            subtitleTrackId: subtitleTrackId ?? saved?.subtitleTrackId,
            subtitleDelay: subtitleDelay ?? saved?.subtitleDelay,
            externalSubtitlePath: externalSubtitlePath ?? saved?.externalSubtitlePath
        )
    }

    /// Whether there is a preference worth keeping without a resume position.
    var isEmpty: Bool {
        audioTrackId == nil && subtitleTrackId == nil && (subtitleDelay ?? 0) == 0
    }
}

/// Thread-safe storage manager for recording and restoring media playback positions (Watch Later / Resume Playback).
public final class PlaybackHistoryStore: Sendable {
    public static let shared = PlaybackHistoryStore()

    nonisolated(unsafe) private let userDefaults: UserDefaults
    private let keyPrefix = "Nits.PlaybackHistory."
    private let lock = OSAllocatedUnfairLock()
    public let maxRecordsLimit = 10_000

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Normalizes a media path or URL into a persistent storage key using SHA-256.
    public func storageKey(for path: String) -> String {
        let normalized: String
        if let url = URL(string: path), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.query = nil
                components.fragment = nil
                normalized = components.string ?? path
            } else {
                normalized = url.path
            }
        } else {
            normalized = URL(fileURLWithPath: path).standardized.path
        }

        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hexString = digest.map { String(format: "%02x", $0) }.joined()
        return keyPrefix + hexString
    }

    /// Saves the current playback position for a media resource, respecting start and end thresholds, along with
    /// `preferences` (`nil` fields keep the saved value). A position under `startThreshold` or past completion is
    /// stored as 0, so a finished file keeps its preferences; a record with neither is removed.
    public func savePosition(
        for path: String,
        position: Double,
        duration: Double,
        startThreshold: Double = 15.0,
        endThresholdRatio: Double = 0.95,
        preferences: PlaybackPreferences = PlaybackPreferences()
    ) {
        guard duration > 0 else { return }

        // Watched past the end threshold (e.g. credits at 95% or last 30s for media > 60s): finished, start over.
        let endThresholdSeconds = duration * endThresholdRatio
        let isPastCompletion = position >= endThresholdSeconds || (duration > 60.0 && (duration - position) <= 30.0)
        let effectivePosition = position < startThreshold || isPastCompletion ? 0.0 : position

        let key = storageKey(for: path)

        lock.withLock {
            let merged = preferences.merged(over: record(forKey: key)?.preferences)
            guard effectivePosition > 0 || !merged.isEmpty else {
                userDefaults.removeObject(forKey: key)
                return
            }
            store(PlaybackRecord(position: effectivePosition, duration: duration, preferences: merged), forKey: key)
        }
    }

    /// Saves `preferences` (`nil` fields keep the saved value) for a media resource, keeping its saved position.
    public func savePreferences(for path: String, duration: Double, _ preferences: PlaybackPreferences) {
        let key = storageKey(for: path)

        lock.withLock {
            let existingRecord = record(forKey: key)
            let record = PlaybackRecord(
                position: existingRecord?.position ?? 0.0,
                duration: duration > 0 ? duration : (existingRecord?.duration ?? 0.0),
                preferences: preferences.merged(over: existingRecord?.preferences)
            )
            store(record, forKey: key)
        }
    }

    /// Retrieves the saved playback position for a media resource, or `nil` if not eligible.
    public func savedPosition(
        for path: String,
        startThreshold: Double = 15.0,
        endThresholdRatio: Double = 0.95
    ) -> Double? {
        savedRecord(for: path, startThreshold: startThreshold, endThresholdRatio: endThresholdRatio)?.position
    }

    /// Retrieves the saved preferences (tracks, subtitle delay) for a media resource if present.
    /// Does not require playback position to be past `startThreshold`.
    public func savedPreferences(for path: String) -> PlaybackPreferences? {
        let key = storageKey(for: path)
        return lock.withLock { record(forKey: key)?.preferences }
    }

    /// Reads a record; the caller holds `lock`.
    private func record(forKey key: String) -> PlaybackRecord? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlaybackRecord.self, from: data)
    }

    /// Writes a record and prunes the oldest ones over the limit; the caller holds `lock`.
    private func store(_ record: PlaybackRecord, forKey key: String) {
        if let encoded = try? JSONEncoder().encode(record) {
            userDefaults.set(encoded, forKey: key)
        }
        pruneExcessRecordsIfNeeded()
    }

    private func savedRecord(
        for path: String,
        startThreshold: Double,
        endThresholdRatio: Double
    ) -> PlaybackRecord? {
        let key = storageKey(for: path)

        return lock.withLock {
            guard let record = record(forKey: key) else { return nil }

            guard record.duration > 0 else { return nil }
            guard record.position >= startThreshold else { return nil }

            let endThresholdSeconds = record.duration * endThresholdRatio
            let isPastCompletion =
                record.position >= endThresholdSeconds
                || (record.duration > 60.0 && (record.duration - record.position) <= 30.0)
            guard !isPastCompletion else {
                return nil
            }

            return record
        }
    }

    /// Removes the saved playback position for a specific media path.
    public func clearPosition(for path: String) {
        let key = storageKey(for: path)
        lock.withLock {
            userDefaults.removeObject(forKey: key)
        }
    }

    /// Clears all stored playback positions.
    public func clearAll() {
        lock.withLock {
            let dict = userDefaults.dictionaryRepresentation()
            for key in dict.keys where key.hasPrefix(keyPrefix) {
                userDefaults.removeObject(forKey: key)
            }
        }
    }

    /// Ensures the stored records count does not exceed `maxRecordsLimit` (removes oldest by `lastUpdated`).
    private func pruneExcessRecordsIfNeeded() {
        let dict = userDefaults.dictionaryRepresentation()
        let matchingKeys = dict.keys.filter { $0.hasPrefix(keyPrefix) }

        guard matchingKeys.count > maxRecordsLimit else { return }

        // Decode records with keys to sort by date
        var recordsWithKeys: [(key: String, date: Date)] = []
        for key in matchingKeys {
            if let data = dict[key] as? Data,
                let record = try? JSONDecoder().decode(PlaybackRecord.self, from: data)
            {
                recordsWithKeys.append((key: key, date: record.lastUpdated))
            } else {
                // Invalid or corrupted data, remove immediately
                userDefaults.removeObject(forKey: key)
            }
        }

        // Sort ascending (oldest first)
        recordsWithKeys.sort { $0.date < $1.date }

        let excessCount = recordsWithKeys.count - maxRecordsLimit
        if excessCount > 0 {
            for i in 0..<excessCount {
                userDefaults.removeObject(forKey: recordsWithKeys[i].key)
            }
        }
    }
}
