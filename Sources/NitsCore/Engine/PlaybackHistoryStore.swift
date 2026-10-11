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
    /// Selected subtitle track id. `nil` means no recorded preference; `PlaybackRecord.subtitlesOff` means disabled.
    public let subtitleTrackId: Int?

    /// Sentinel value for `subtitleTrackId` meaning the user explicitly disabled subtitles.
    public static let subtitlesOff = -1

    public init(
        position: Double,
        duration: Double,
        lastUpdated: Date = Date(),
        audioTrackId: Int? = nil,
        subtitleTrackId: Int? = nil
    ) {
        self.position = position
        self.duration = duration
        self.lastUpdated = lastUpdated
        self.audioTrackId = audioTrackId
        self.subtitleTrackId = subtitleTrackId
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

    /// Saves the current playback position for a media resource, respecting start and end thresholds.
    /// If an existing record exists, it preserves previously selected audio/subtitle tracks unless explicitly passed.
    public func savePosition(
        for path: String,
        position: Double,
        duration: Double,
        startThreshold: Double = 15.0,
        endThresholdRatio: Double = 0.95,
        audioTrackId: Int? = nil,
        subtitleTrackId: Int? = nil
    ) {
        guard duration > 0 else { return }

        // If watched past end threshold (e.g. credits at 95% or last 30s for media > 60s), mark as finished (clear)
        let endThresholdSeconds = duration * endThresholdRatio
        let isPastCompletion = position >= endThresholdSeconds || (duration > 60.0 && (duration - position) <= 30.0)
        if isPastCompletion {
            clearPosition(for: path)
            return
        }

        let key = storageKey(for: path)

        lock.withLock {
            let existingRecord: PlaybackRecord? = {
                guard let data = userDefaults.data(forKey: key),
                    let rec = try? JSONDecoder().decode(PlaybackRecord.self, from: data)
                else { return nil }
                return rec
            }()

            // If watched for less than start threshold, treat playback position as 0 / unwatched,
            // but preserve any selected audio/subtitle track preferences if available.
            let effectivePosition: Double = position < startThreshold ? 0.0 : position
            let effectiveAudio = audioTrackId ?? existingRecord?.audioTrackId
            let effectiveSubtitle = subtitleTrackId ?? existingRecord?.subtitleTrackId

            // If position is under threshold and no tracks are configured, clear record completely.
            if effectivePosition == 0.0 && effectiveAudio == nil && effectiveSubtitle == nil {
                userDefaults.removeObject(forKey: key)
                return
            }

            let record = PlaybackRecord(
                position: effectivePosition,
                duration: duration,
                lastUpdated: Date(),
                audioTrackId: effectiveAudio,
                subtitleTrackId: effectiveSubtitle
            )

            if let encoded = try? JSONEncoder().encode(record) {
                userDefaults.set(encoded, forKey: key)
            }
            pruneExcessRecordsIfNeeded()
        }
    }

    /// Explicitly updates or saves user track selection preferences for a media resource
    /// regardless of current playback position.
    public func saveTrackSelection(
        for path: String,
        duration: Double,
        audioTrackId: Int?,
        subtitleTrackId: Int?
    ) {
        let key = storageKey(for: path)

        lock.withLock {
            let existingRecord: PlaybackRecord? = {
                guard let data = userDefaults.data(forKey: key),
                    let rec = try? JSONDecoder().decode(PlaybackRecord.self, from: data)
                else { return nil }
                return rec
            }()

            let position = existingRecord?.position ?? 0.0
            let effectiveDuration = duration > 0 ? duration : (existingRecord?.duration ?? 0.0)

            let record = PlaybackRecord(
                position: position,
                duration: effectiveDuration,
                lastUpdated: Date(),
                audioTrackId: audioTrackId ?? existingRecord?.audioTrackId,
                subtitleTrackId: subtitleTrackId ?? existingRecord?.subtitleTrackId
            )

            if let encoded = try? JSONEncoder().encode(record) {
                userDefaults.set(encoded, forKey: key)
            }
            pruneExcessRecordsIfNeeded()
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

    /// Retrieves the saved audio / subtitle track selection for a media resource if present.
    /// Does not require playback position to be past `startThreshold`.
    public func savedTrackSelection(
        for path: String
    ) -> (audioTrackId: Int?, subtitleTrackId: Int?)? {
        let key = storageKey(for: path)
        return lock.withLock {
            guard let data = userDefaults.data(forKey: key),
                let record = try? JSONDecoder().decode(PlaybackRecord.self, from: data)
            else { return nil }
            return (record.audioTrackId, record.subtitleTrackId)
        }
    }

    private func savedRecord(
        for path: String,
        startThreshold: Double,
        endThresholdRatio: Double
    ) -> PlaybackRecord? {
        let key = storageKey(for: path)

        return lock.withLock {
            guard let data = userDefaults.data(forKey: key),
                let record = try? JSONDecoder().decode(PlaybackRecord.self, from: data)
            else {
                return nil
            }

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
