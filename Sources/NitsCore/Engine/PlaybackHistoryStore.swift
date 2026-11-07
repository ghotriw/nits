import CryptoKit
import Foundation
import os

/// Represents a persistent playback progress record for a media resource.
public struct PlaybackRecord: Codable, Sendable, Equatable {
    /// Seconds into the media; of a live stream's history (`LiveHistory`) the stream's own time, which the segments
    /// carry: the window's start moves between runs, the stream's time does not, and the recording that follows the
    /// stream counts in it too.
    public let position: Double
    /// Of a live stream's history, how long the stream was when the position was saved (a lower bound: the time of the
    /// window's end), so that a recording of it can tell a position near its end.
    public let duration: Double
    /// Saved from a live stream's history at its edge (within `LiveStream.edgeTolerance`): to watch it live, not from
    /// there, when it is opened again. `nil` for media that was not live, and in older records.
    public let wasAtLiveEdge: Bool?
    public let lastUpdated: Date
    /// Selected audio track id (`nil` if unknown / not recorded); `PlaybackRecord.externalAudio` the file at
    /// `externalAudioPath`.
    public let audioTrackId: Int?
    /// Selected subtitle track id. `nil` means no recorded preference; `PlaybackRecord.subtitlesOff` means disabled,
    /// `PlaybackRecord.externalSubtitle` the file at `externalSubtitlePath`, `PlaybackRecord.listedSubtitle` the
    /// network file `listedSubtitle` tells.
    public let subtitleTrackId: Int?
    /// Subtitle delay in seconds of each subtitle track that has one, by `SubtitleTrack.persistenceKey` (`nil` if never
    /// set).
    public let subtitleDelays: [String: Double]?
    /// `SubtitleTrack.persistenceKey` of the second subtitle track; empty when there is none (`nil` if never chosen).
    public let secondarySubtitle: String?
    /// The encoding (IANA name) the user chose for each subtitle file, by `SubtitleTrack.persistenceKey` (`nil` if
    /// never).
    public let subtitleEncodings: [String: String]?
    /// Audio delay in seconds (`nil` if never set).
    public let audioDelay: Double?
    /// Playback speed chosen for this media (`nil` if never chosen).
    public let playbackRate: Double?
    /// Path of the selected external subtitle file, when `subtitleTrackId` is `externalSubtitle`.
    public let externalSubtitlePath: String?
    /// Stream of that file, which tells apart the languages of a VobSub index; `nil` in older records.
    public let externalSubtitleStreamIndex: Int?
    /// The selected network subtitle file, when `subtitleTrackId` is `listedSubtitle`.
    public let listedSubtitle: ListedSubtitle?
    /// Path of the selected external audio file, when `audioTrackId` is `externalAudio`.
    public let externalAudioPath: String?
    /// Stream of that file among its audio streams (`AudioTrack.streamIndex`), when it holds several.
    public let externalAudioStreamIndex: Int?
    /// Forced display aspect ratio; see `PlaybackPreferences.videoAspectRatio`.
    public let videoAspectRatio: RationalAspectRatio?
    /// Crop aspect ratio; see `PlaybackPreferences.videoCrop`.
    public let videoCrop: RationalAspectRatio?
    /// Standardized local path or network URL recorded for this entry; used for exclusion matching.
    public let mediaPath: String?

    /// Sentinel value for `subtitleTrackId` meaning the user explicitly disabled subtitles.
    public static let subtitlesOff = -1
    /// Sentinel value for `subtitleTrackId` meaning the external subtitle file at `externalSubtitlePath`.
    public static let externalSubtitle = -2
    /// Sentinel value for `subtitleTrackId` meaning the network subtitle file `listedSubtitle` tells.
    public static let listedSubtitle = -3
    /// Sentinel value for `audioTrackId` meaning the external audio file at `externalAudioPath`.
    public static let externalAudio = -2

    public init(
        position: Double,
        duration: Double,
        lastUpdated: Date = Date(),
        preferences: PlaybackPreferences = PlaybackPreferences(),
        mediaPath: String? = nil,
        wasAtLiveEdge: Bool? = nil
    ) {
        self.position = position
        self.duration = duration
        self.wasAtLiveEdge = wasAtLiveEdge
        self.lastUpdated = lastUpdated
        self.audioTrackId = preferences.audioTrackId
        self.subtitleTrackId = preferences.subtitleTrackId
        self.subtitleDelays = preferences.subtitleDelays
        self.secondarySubtitle = preferences.secondarySubtitle
        self.subtitleEncodings = preferences.subtitleEncodings
        self.audioDelay = preferences.audioDelay
        self.playbackRate = preferences.playbackRate
        self.externalSubtitlePath = preferences.externalSubtitlePath
        self.externalSubtitleStreamIndex = preferences.externalSubtitleStreamIndex
        self.listedSubtitle = preferences.listedSubtitle
        self.externalAudioPath = preferences.externalAudioPath
        self.externalAudioStreamIndex = preferences.externalAudioStreamIndex
        self.videoAspectRatio = preferences.videoAspectRatio
        self.videoCrop = preferences.videoCrop
        self.mediaPath = mediaPath
    }

    public var preferences: PlaybackPreferences {
        PlaybackPreferences(
            audioTrackId: audioTrackId,
            subtitleTrackId: subtitleTrackId,
            subtitleDelays: subtitleDelays,
            secondarySubtitle: secondarySubtitle,
            subtitleEncodings: subtitleEncodings,
            audioDelay: audioDelay,
            playbackRate: playbackRate,
            externalSubtitlePath: externalSubtitlePath,
            externalSubtitleStreamIndex: externalSubtitleStreamIndex,
            listedSubtitle: listedSubtitle,
            externalAudioPath: externalAudioPath,
            externalAudioStreamIndex: externalAudioStreamIndex,
            videoAspectRatio: videoAspectRatio,
            videoCrop: videoCrop
        )
    }
}

/// A network subtitle file of the media (a page's, or a request's `subtitleFiles`), told by what it is: its URL may
/// not last (a signed one) and its track id comes from the order the files are listed in, which a page may change.
public struct ListedSubtitle: Codable, Sendable, Equatable {
    public var language: String
    public var title: String
    public var isAutoGenerated: Bool

    public init(language: String, title: String, isAutoGenerated: Bool) {
        self.language = language
        self.title = title
        self.isAutoGenerated = isAutoGenerated
    }
}

/// Per-file preferences restored on load, independent of the resume position. When saving, a `nil` field keeps the
/// previously saved value.
public struct PlaybackPreferences: Sendable, Equatable {
    public var audioTrackId: Int?
    /// See `PlaybackRecord.subtitleTrackId`.
    public var subtitleTrackId: Int?
    /// By `SubtitleTrack.persistenceKey`: one delay per track, as tracks of a file are timed apart.
    public var subtitleDelays: [String: Double]?
    /// See `PlaybackRecord.secondarySubtitle`.
    public var secondarySubtitle: String?
    /// See `PlaybackRecord.subtitleEncodings`.
    public var subtitleEncodings: [String: String]?
    public var audioDelay: Double?
    /// Saved only when chosen for this media: a speed kept from the previous one (`carriesPlaybackRate`) is `nil`.
    public var playbackRate: Double?
    public var externalSubtitlePath: String?
    /// See `PlaybackRecord.externalSubtitleStreamIndex`.
    public var externalSubtitleStreamIndex: Int?
    /// See `PlaybackRecord.listedSubtitle`.
    public var listedSubtitle: ListedSubtitle?
    /// See `PlaybackRecord.externalAudioPath`.
    public var externalAudioPath: String?
    /// See `PlaybackRecord.externalAudioStreamIndex`.
    public var externalAudioStreamIndex: Int?
    /// Display aspect ratio forced on the picture (`VideoGeometrySettings.aspectRatio`); `noGeometryOverride` when the
    /// stream's own is used.
    public var videoAspectRatio: RationalAspectRatio?
    /// Crop of the picture (`VideoGeometrySettings.crop`); `noGeometryOverride` when it is not cropped.
    public var videoCrop: RationalAspectRatio?

    /// Saved for "no override", which `nil` can't say: it keeps the saved value.
    public static let noGeometryOverride = RationalAspectRatio(numerator: 0, denominator: 0)

    public init(
        audioTrackId: Int? = nil,
        subtitleTrackId: Int? = nil,
        subtitleDelays: [String: Double]? = nil,
        secondarySubtitle: String? = nil,
        subtitleEncodings: [String: String]? = nil,
        audioDelay: Double? = nil,
        playbackRate: Double? = nil,
        externalSubtitlePath: String? = nil,
        externalSubtitleStreamIndex: Int? = nil,
        listedSubtitle: ListedSubtitle? = nil,
        externalAudioPath: String? = nil,
        externalAudioStreamIndex: Int? = nil,
        videoAspectRatio: RationalAspectRatio? = nil,
        videoCrop: RationalAspectRatio? = nil
    ) {
        self.audioTrackId = audioTrackId
        self.subtitleTrackId = subtitleTrackId
        self.subtitleDelays = subtitleDelays
        self.secondarySubtitle = secondarySubtitle
        self.subtitleEncodings = subtitleEncodings
        self.audioDelay = audioDelay
        self.playbackRate = playbackRate
        self.externalSubtitlePath = externalSubtitlePath
        self.externalSubtitleStreamIndex = externalSubtitleStreamIndex
        self.listedSubtitle = listedSubtitle
        self.externalAudioPath = externalAudioPath
        self.externalAudioStreamIndex = externalAudioStreamIndex
        self.videoAspectRatio = videoAspectRatio
        self.videoCrop = videoCrop
    }

    /// These preferences with the fields left `nil` taken from `saved`. A file's path and stream go with the choice of
    /// it: choosing another track drops them.
    func merged(over saved: PlaybackPreferences?) -> PlaybackPreferences {
        let keepsSubtitleFile = subtitleTrackId == nil || subtitleTrackId == PlaybackRecord.externalSubtitle
        let keepsListedSubtitle = subtitleTrackId == nil || subtitleTrackId == PlaybackRecord.listedSubtitle
        let keepsAudioFile = audioTrackId == nil || audioTrackId == PlaybackRecord.externalAudio
        return PlaybackPreferences(
            audioTrackId: audioTrackId ?? saved?.audioTrackId,
            subtitleTrackId: subtitleTrackId ?? saved?.subtitleTrackId,
            subtitleDelays: subtitleDelays ?? saved?.subtitleDelays,
            secondarySubtitle: secondarySubtitle ?? saved?.secondarySubtitle,
            subtitleEncodings: subtitleEncodings ?? saved?.subtitleEncodings,
            audioDelay: audioDelay ?? saved?.audioDelay,
            playbackRate: playbackRate ?? saved?.playbackRate,
            externalSubtitlePath: keepsSubtitleFile ? externalSubtitlePath ?? saved?.externalSubtitlePath : nil,
            // Belongs to the path: a new path with no stream of its own doesn't take the old one's.
            externalSubtitleStreamIndex: !keepsSubtitleFile
                ? nil
                : externalSubtitlePath != nil
                    ? externalSubtitleStreamIndex : (externalSubtitleStreamIndex ?? saved?.externalSubtitleStreamIndex),
            listedSubtitle: keepsListedSubtitle ? listedSubtitle ?? saved?.listedSubtitle : nil,
            externalAudioPath: keepsAudioFile ? externalAudioPath ?? saved?.externalAudioPath : nil,
            externalAudioStreamIndex: !keepsAudioFile
                ? nil
                : externalAudioPath != nil
                    ? externalAudioStreamIndex : (externalAudioStreamIndex ?? saved?.externalAudioStreamIndex),
            videoAspectRatio: videoAspectRatio ?? saved?.videoAspectRatio,
            videoCrop: videoCrop ?? saved?.videoCrop
        )
    }

    /// Whether there is a preference worth keeping without a resume position.
    var isEmpty: Bool {
        audioTrackId == nil && subtitleTrackId == nil && (subtitleDelays ?? [:]).values.allSatisfy { $0 == 0 }
            && (secondarySubtitle ?? "").isEmpty && (subtitleEncodings ?? [:]).isEmpty
            && (audioDelay ?? 0) == 0
            // A chosen 1× is kept: without it a media would start at the previous one's speed (`carriesPlaybackRate`).
            && playbackRate == nil && videoAspectRatio?.isValid != true && videoCrop?.isValid != true
    }
}

/// Identifies a media resource for history storage and exclusion checks: its storage key (`historyKey`),
/// the requested path or URL (`path`), and the stream URL opened by the demuxer (`sourcePath`).
public struct MediaHistoryIdentity: Sendable, Equatable {
    public let historyKey: String
    public let path: String?
    public let sourcePath: String?

    public init(historyKey: String, path: String? = nil, sourcePath: String? = nil) {
        self.historyKey = historyKey
        self.path = path
        self.sourcePath = sourcePath
    }

    /// Path stored in the record for later exclusion purges.
    public var resolvedMediaPath: String {
        path ?? sourcePath ?? historyKey
    }
}

/// Thread-safe storage manager for recording and restoring media playback positions (Watch Later / Resume Playback).
public final class PlaybackHistoryStore: Sendable {
    public static let shared = PlaybackHistoryStore(
        exclusionPolicy: PlayerConfiguration.loadHistoryExclusionPolicy()
    )
    public static let didChangeNotification = Notification.Name("Nits.PlaybackHistoryStore.didChange")

    private struct State: Sendable {
        var exclusionPolicy: HistoryExclusionPolicy
        var cachedHasSavedPositions: Bool?
        var cachedRecordsCount: Int?
    }

    nonisolated(unsafe) private let userDefaults: UserDefaults
    private let keyPrefix = "Nits.PlaybackHistory."
    private let lock: OSAllocatedUnfairLock<State>
    public let maxRecordsLimit = 10_000

    /// Policy governing which folders and domains are excluded from reading and writing playback history.
    public var exclusionPolicy: HistoryExclusionPolicy {
        get { lock.withLock { $0.exclusionPolicy } }
        set { lock.withLock { $0.exclusionPolicy = newValue } }
    }

    public init(
        userDefaults: UserDefaults = .standard,
        exclusionPolicy: HistoryExclusionPolicy = HistoryExclusionPolicy()
    ) {
        self.userDefaults = userDefaults
        self.lock = OSAllocatedUnfairLock(initialState: State(exclusionPolicy: exclusionPolicy))
    }

    /// Checks whether `media` matches the store's current `exclusionPolicy`.
    public func isExcluded(_ media: MediaHistoryIdentity) -> Bool {
        lock.withLock { state in
            Self.isExcluded(media, recordMediaPath: nil, policy: state.exclusionPolicy)
        }
    }

    private static func isExcluded(
        _ media: MediaHistoryIdentity,
        recordMediaPath: String?,
        policy: HistoryExclusionPolicy
    ) -> Bool {
        if policy.isExcluded(media: media) { return true }
        if let recordMediaPath, policy.isExcluded(pathOrURL: recordMediaPath) { return true }
        return false
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
        } else if !path.hasPrefix("/"), let scheme = URL(string: path)?.scheme, scheme.lowercased() != "file" {
            // A name of its own (a resolved page's media, `youtube:dQw4w9WgXcQ`) or another protocol's URL: as is.
            normalized = path
        } else {
            normalized = URL(fileURLWithPath: path).standardized.path
        }

        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hexString = digest.map { String(format: "%02x", $0) }.joined()
        return keyPrefix + hexString
    }

    /// The most of a media's end that counts as watched, in seconds, whatever the share it is of its length: the threshold
    /// is a share of the duration (`endThresholdRatio`, 5% of what is left at 95%), but of a stream of twenty hours that is
    /// an hour of it, and a position forty minutes from its end is not one to start over from.
    public static let maximumUnwatchedTail = 600.0

    /// Whether `position` of a media of `duration` is its end, to start over from rather than resume: within what is left
    /// by `endThresholdRatio` (at 95%, the last 5%) but no more than `maximumUnwatchedTail`, or, for a media over a minute,
    /// within its last 30 s.
    static func isPastCompletion(position: Double, duration: Double, endThresholdRatio: Double) -> Bool {
        let remaining = duration - position
        let tail = min(duration * (1 - endThresholdRatio), maximumUnwatchedTail)
        return remaining <= tail || (duration > 60.0 && remaining <= 30.0)
    }

    /// Saves the current playback position for a media resource identified by `media`, respecting start and end
    /// thresholds, along with `preferences` (`nil` fields keep the saved value), unless excluded by `exclusionPolicy`.
    /// A position under `startThreshold` or past completion is stored as 0, so a finished file keeps its preferences;
    /// a record with neither is removed.
    ///
    /// A live stream's history on the air (`isLive`) has no end to have watched to: its position is not past completion
    /// at its edge, which `wasAtLiveEdge` says instead.
    public func savePosition(
        for media: MediaHistoryIdentity,
        position: Double,
        duration: Double,
        startThreshold: Double = 15.0,
        endThresholdRatio: Double = 0.95,
        isLive: Bool = false,
        wasAtLiveEdge: Bool? = nil,
        preferences: PlaybackPreferences = PlaybackPreferences()
    ) {
        guard duration > 0 else { return }

        // Watched past the end threshold (e.g. credits at 95% or last 30s for media > 60s): finished, start over.
        let isPastCompletion =
            !isLive
            && Self.isPastCompletion(position: position, duration: duration, endThresholdRatio: endThresholdRatio)
        let effectivePosition = position < startThreshold || isPastCompletion ? 0.0 : position

        let key = storageKey(for: media.historyKey)

        let didMutate = lock.withLock { state -> Bool in
            let existingRecord = record(forKey: key)
            let resolvedPath = media.path ?? media.sourcePath ?? existingRecord?.mediaPath ?? media.historyKey
            guard !Self.isExcluded(media, recordMediaPath: resolvedPath, policy: state.exclusionPolicy) else {
                return false
            }
            let merged = preferences.merged(over: existingRecord?.preferences)
            guard effectivePosition > 0 || !merged.isEmpty else {
                if existingRecord != nil {
                    userDefaults.removeObject(forKey: key)
                    if let count = state.cachedRecordsCount {
                        state.cachedRecordsCount = max(0, count - 1)
                    }
                    if (existingRecord?.position ?? 0) > 0 {
                        state.cachedHasSavedPositions = nil
                    }
                    return true
                }
                return false
            }
            store(
                PlaybackRecord(
                    position: effectivePosition,
                    duration: duration,
                    preferences: merged,
                    mediaPath: resolvedPath,
                    wasAtLiveEdge: isLive && effectivePosition > 0 ? wasAtLiveEdge : nil
                ),
                forKey: key,
                isNewRecord: existingRecord == nil,
                state: &state
            )
            if effectivePosition > 0 {
                state.cachedHasSavedPositions = true
            } else if (existingRecord?.position ?? 0) > 0 {
                state.cachedHasSavedPositions = nil
            }
            return true
        }
        if didMutate {
            notifyChanged()
        }
    }

    /// Saves `preferences` (`nil` fields keep the saved value) for a media resource identified by `media`,
    /// keeping its saved position, unless excluded by `exclusionPolicy`.
    public func savePreferences(
        for media: MediaHistoryIdentity,
        duration: Double,
        _ preferences: PlaybackPreferences
    ) {
        let key = storageKey(for: media.historyKey)

        let didMutate = lock.withLock { state -> Bool in
            let existingRecord = record(forKey: key)
            let resolvedPath = media.path ?? media.sourcePath ?? existingRecord?.mediaPath ?? media.historyKey
            guard !Self.isExcluded(media, recordMediaPath: resolvedPath, policy: state.exclusionPolicy) else {
                return false
            }
            let record = PlaybackRecord(
                position: existingRecord?.position ?? 0.0,
                duration: duration > 0 ? duration : (existingRecord?.duration ?? 0.0),
                preferences: preferences.merged(over: existingRecord?.preferences),
                mediaPath: resolvedPath,
                wasAtLiveEdge: existingRecord?.wasAtLiveEdge
            )
            store(record, forKey: key, isNewRecord: existingRecord == nil, state: &state)
            return true
        }
        if didMutate {
            notifyChanged()
        }
    }

    /// Retrieves the saved playback position for a media resource identified by `media`, or `nil` if not eligible or excluded.
    public func savedPosition(
        for media: MediaHistoryIdentity,
        startThreshold: Double = 15.0,
        endThresholdRatio: Double = 0.95
    ) -> Double? {
        savedRecord(for: media, startThreshold: startThreshold, endThresholdRatio: endThresholdRatio)?.position
    }

    /// The saved position of a live stream's history, in the stream's time, and whether it was saved at the edge; `nil`
    /// when there is none, or the media is excluded. Not judged by a duration or by how far it is: a stream on the air has
    /// no end to be past, and the window it falls in is for the engine to tell.
    public func savedLivePosition(for media: MediaHistoryIdentity) -> (position: Double, wasAtEdge: Bool)? {
        let key = storageKey(for: media.historyKey)
        return lock.withLock { state in
            guard let record = record(forKey: key), record.position > 0,
                !Self.isExcluded(media, recordMediaPath: record.mediaPath, policy: state.exclusionPolicy)
            else { return nil }
            return (record.position, record.wasAtLiveEdge ?? false)
        }
    }

    /// Retrieves the saved preferences (tracks, subtitle delay) for a media resource identified by `media` if present and not excluded.
    /// Does not require playback position to be past `startThreshold`.
    public func savedPreferences(for media: MediaHistoryIdentity) -> PlaybackPreferences? {
        let key = storageKey(for: media.historyKey)
        return lock.withLock { state in
            guard let existing = record(forKey: key) else { return nil }
            guard !Self.isExcluded(media, recordMediaPath: existing.mediaPath, policy: state.exclusionPolicy) else {
                return nil
            }
            return existing.preferences
        }
    }

    /// Reads a record; the caller holds `lock`.
    private func record(forKey key: String) -> PlaybackRecord? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlaybackRecord.self, from: data)
    }

    /// Writes a record and prunes the oldest ones over the limit; the caller holds `lock`.
    private func store(_ record: PlaybackRecord, forKey key: String, isNewRecord: Bool, state: inout State) {
        if let encoded = try? JSONEncoder().encode(record) {
            userDefaults.set(encoded, forKey: key)
        }
        if isNewRecord {
            if let count = state.cachedRecordsCount {
                state.cachedRecordsCount = count + 1
            }
            pruneExcessRecordsIfNeeded(state: &state)
        }
    }

    private func savedRecord(
        for media: MediaHistoryIdentity,
        startThreshold: Double,
        endThresholdRatio: Double
    ) -> PlaybackRecord? {
        let key = storageKey(for: media.historyKey)

        return lock.withLock { state in
            guard let record = record(forKey: key) else { return nil }
            guard !Self.isExcluded(media, recordMediaPath: record.mediaPath, policy: state.exclusionPolicy) else {
                return nil
            }

            guard record.duration > 0 else { return nil }
            guard record.position >= startThreshold else { return nil }

            guard
                !Self.isPastCompletion(
                    position: record.position, duration: record.duration, endThresholdRatio: endThresholdRatio)
            else {
                return nil
            }

            return record
        }
    }

    /// Whether any stored record currently has a non-zero playback position.
    public var hasSavedPositions: Bool {
        lock.withLock { state in
            if let cached = state.cachedHasSavedPositions {
                return cached
            }
            let dict = userDefaults.dictionaryRepresentation()
            for key in dict.keys where key.hasPrefix(keyPrefix) {
                if let existing = record(forKey: key), existing.position > 0 {
                    state.cachedHasSavedPositions = true
                    return true
                }
            }
            state.cachedHasSavedPositions = false
            return false
        }
    }

    /// Removes the saved playback position for a specific media path, keeping per-file preferences if any.
    public func clearPosition(for path: String) {
        let key = storageKey(for: path)
        lock.withLock { state in
            clearPositionLocked(forKey: key, state: &state)
            state.cachedHasSavedPositions = nil
        }
        notifyChanged()
    }

    /// Clears all stored playback positions, keeping per-file preferences if any.
    public func clearAll() {
        lock.withLock { state in
            let dict = userDefaults.dictionaryRepresentation()
            for key in dict.keys where key.hasPrefix(keyPrefix) {
                clearPositionLocked(forKey: key, state: &state)
            }
            state.cachedHasSavedPositions = false
        }
        notifyChanged()
    }

    /// Resets the position of `key` to 0 when the record has preferences worth keeping, or removes the record;
    /// the caller holds `lock`.
    private func clearPositionLocked(forKey key: String, state: inout State) {
        if let existing = record(forKey: key), !existing.preferences.isEmpty {
            if existing.position != 0,
                let encoded = try? JSONEncoder().encode(
                    PlaybackRecord(
                        position: 0.0,
                        duration: existing.duration,
                        lastUpdated: existing.lastUpdated,
                        preferences: existing.preferences,
                        mediaPath: existing.mediaPath
                    )
                )
            {
                userDefaults.set(encoded, forKey: key)
            }
        } else {
            userDefaults.removeObject(forKey: key)
            state.cachedRecordsCount = nil
        }
    }

    /// Purges all stored playback positions and preferences that match the given exclusion policy,
    /// as well as records for any explicit keys and paths provided.
    public func purge(
        matching policy: HistoryExclusionPolicy,
        knownKeysAndPaths: [(key: String, path: String)] = []
    ) {
        lock.withLock { state in
            let dict = userDefaults.dictionaryRepresentation()
            for key in dict.keys where key.hasPrefix(keyPrefix) {
                if let record = record(forKey: key), let mediaPath = record.mediaPath,
                    policy.isExcluded(pathOrURL: mediaPath)
                {
                    userDefaults.removeObject(forKey: key)
                }
            }
            for (key, path) in knownKeysAndPaths {
                if policy.isExcluded(pathOrURL: path) || policy.isExcluded(pathOrURL: key) {
                    userDefaults.removeObject(forKey: storageKey(for: key))
                    userDefaults.removeObject(forKey: storageKey(for: path))
                }
            }
            state.cachedHasSavedPositions = nil
            state.cachedRecordsCount = nil
        }
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Ensures the stored records count does not exceed `maxRecordsLimit` (removes oldest by `lastUpdated`).
    private func pruneExcessRecordsIfNeeded(state: inout State) {
        if let count = state.cachedRecordsCount, count <= maxRecordsLimit {
            return
        }
        let dict = userDefaults.dictionaryRepresentation()
        let matchingKeys = dict.keys.filter { $0.hasPrefix(keyPrefix) }
        state.cachedRecordsCount = matchingKeys.count

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
            state.cachedHasSavedPositions = nil
        }
        state.cachedRecordsCount = min(recordsWithKeys.count, maxRecordsLimit)
    }
}
