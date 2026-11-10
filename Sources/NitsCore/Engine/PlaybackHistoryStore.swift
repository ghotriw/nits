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

/// Thread-safe storage of playback positions and per-media preferences (Watch Later / Resume Playback), kept in memory
/// and saved as one JSON file, `~/Library/Application Support/<bundle id>/PlaybackHistory.json`.
///
/// The file is read and written on a queue of the store's own (`ioQueue`), never the cooperative pool: read once the
/// store is made (a call that comes first waits for it), and written a moment after a change, so the periodic saves of
/// a playing media come to one write. Call `flush()` before the process exits, after saving the last position
/// (in the app, each `PlayerSession` does both when it quits, and `AppDelegate` writes what sessions already gone left).
/// A write that fails is tried again after the same delay until it succeeds.
public final class PlaybackHistoryStore: Sendable {
    public static let shared = PlaybackHistoryStore(
        fileURL: PlaybackHistoryStore.defaultFileURL,
        exclusionPolicy: PlayerConfiguration.loadHistoryExclusionPolicy()
    )
    public static let didChangeNotification = Notification.Name("Nits.PlaybackHistoryStore.didChange")

    public static var defaultFileURL: URL {
        AppDirectories.applicationSupport.appendingPathComponent("PlaybackHistory.json")
    }

    private struct State: Sendable {
        var exclusionPolicy: HistoryExclusionPolicy
        /// By `storageKey(for:)`; empty until `isLoaded`.
        var records: [String: PlaybackRecord] = [:]
        var isLoaded = false
        /// Counts changes, so a save writes only what is newer than the file.
        var generation = 0
        var isSaveScheduled = false
    }

    private let fileURL: URL?
    private let saveDelay: Duration
    private let lock: OSAllocatedUnfairLock<State>
    /// Reads and writes the file, one at a time.
    private let ioQueue = DispatchQueue(label: "com.nits.history.io", qos: .utility)
    /// The generation the file holds; only `ioQueue` touches it, as the two below.
    nonisolated(unsafe) private var writtenGeneration = 0
    /// False after a file that could not be read and was left in place: saving would write over it.
    nonisolated(unsafe) private var isFileWritable = true
    /// A write failed and has not succeeded since (told once).
    nonisolated(unsafe) private var isRetryingSave = false
    /// A retry of a failed write is queued: one at a time, however many saves fail meanwhile.
    nonisolated(unsafe) private var isRetryScheduled = false
    public let maxRecordsLimit = 10_000

    /// Policy governing which folders and domains are excluded from reading and writing playback history.
    public var exclusionPolicy: HistoryExclusionPolicy {
        get { lock.withLock { $0.exclusionPolicy } }
        set { lock.withLock { $0.exclusionPolicy = newValue } }
    }

    /// - Parameters:
    ///   - fileURL: Where to persist; `nil` keeps the history in memory only.
    ///   - saveDelay: How long to batch changes before writing them, and to wait before trying a failed write again.
    public init(
        fileURL: URL?,
        exclusionPolicy: HistoryExclusionPolicy = HistoryExclusionPolicy(),
        saveDelay: Duration = .seconds(2)
    ) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        self.lock = OSAllocatedUnfairLock(initialState: State(exclusionPolicy: exclusionPolicy))
        if fileURL != nil {
            ioQueue.async { [self] in
                loadOnQueue()
            }
        }
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
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `position` of a media of `duration` is its end, to start over from rather than resume: within what is left
    /// by `endThresholdRatio` (at 95%, the last 5%) but no more than `maximumUnwatchedTail` seconds (of a stream of twenty
    /// hours 5% is an hour, and a position forty minutes from its end is not one to start over from), or, for a media over a minute,
    /// within its last 30 s.
    static func isPastCompletion(
        position: Double, duration: Double, endThresholdRatio: Double, maximumUnwatchedTail: Double
    ) -> Bool {
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
        startThreshold: Double = PlayerConfiguration.defaultResumeStartThreshold,
        endThresholdRatio: Double = PlayerConfiguration.defaultResumeEndThresholdRatio,
        maximumUnwatchedTail: Double = PlayerConfiguration.defaultResumeMaximumUnwatchedTail,
        isLive: Bool = false,
        wasAtLiveEdge: Bool? = nil,
        preferences: PlaybackPreferences = PlaybackPreferences()
    ) {
        guard duration > 0 else { return }

        // Watched past the end threshold (e.g. credits at 95% or last 30s for media > 60s): finished, start over.
        let isPastCompletion =
            !isLive
            && Self.isPastCompletion(
                position: position, duration: duration, endThresholdRatio: endThresholdRatio,
                maximumUnwatchedTail: maximumUnwatchedTail)
        let effectivePosition = position < startThreshold || isPastCompletion ? 0.0 : position

        let key = storageKey(for: media.historyKey)

        let didMutate = withLoadedState { state -> Bool in
            let existingRecord = state.records[key]
            let resolvedPath = media.path ?? media.sourcePath ?? existingRecord?.mediaPath ?? media.historyKey
            guard !Self.isExcluded(media, recordMediaPath: resolvedPath, policy: state.exclusionPolicy) else {
                return false
            }
            let merged = preferences.merged(over: existingRecord?.preferences)
            guard effectivePosition > 0 || !merged.isEmpty else {
                guard existingRecord != nil else { return false }
                state.records[key] = nil
                state.generation += 1
                return true
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
                in: &state
            )
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

        let didMutate = withLoadedState { state -> Bool in
            let existingRecord = state.records[key]
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
            store(record, forKey: key, in: &state)
            return true
        }
        if didMutate {
            notifyChanged()
        }
    }

    /// Retrieves the saved playback position for a media resource identified by `media`, or `nil` if not eligible or excluded.
    public func savedPosition(
        for media: MediaHistoryIdentity,
        startThreshold: Double = PlayerConfiguration.defaultResumeStartThreshold,
        endThresholdRatio: Double = PlayerConfiguration.defaultResumeEndThresholdRatio,
        maximumUnwatchedTail: Double = PlayerConfiguration.defaultResumeMaximumUnwatchedTail
    ) -> Double? {
        guard let record = record(for: media), record.duration > 0, record.position >= startThreshold,
            !Self.isPastCompletion(
                position: record.position, duration: record.duration, endThresholdRatio: endThresholdRatio,
                maximumUnwatchedTail: maximumUnwatchedTail)
        else { return nil }
        return record.position
    }

    /// The saved position of a live stream's history, in the stream's time, and whether it was saved at the edge; `nil`
    /// when there is none, or the media is excluded. Not judged by a duration or by how far it is: a stream on the air has
    /// no end to be past, and the window it falls in is for the engine to tell.
    public func savedLivePosition(for media: MediaHistoryIdentity) -> (position: Double, wasAtEdge: Bool)? {
        guard let record = record(for: media), record.position > 0 else { return nil }
        return (record.position, record.wasAtLiveEdge ?? false)
    }

    /// Retrieves the saved preferences (tracks, subtitle delay) for a media resource identified by `media` if present and not excluded.
    /// Does not require playback position to be past `startThreshold`.
    public func savedPreferences(for media: MediaHistoryIdentity) -> PlaybackPreferences? {
        record(for: media)?.preferences
    }

    /// Whether any stored record currently has a non-zero playback position.
    public var hasSavedPositions: Bool {
        withLoadedState { state in
            state.records.values.contains { $0.position > 0 }
        }
    }

    /// Removes the saved playback position for a specific media path, keeping per-file preferences if any.
    public func clearPosition(for path: String) {
        let key = storageKey(for: path)
        withLoadedState { state in
            clearPosition(forKey: key, in: &state)
        }
        notifyChanged()
    }

    /// Clears all stored playback positions, keeping per-file preferences if any.
    public func clearAll() {
        withLoadedState { state in
            for key in Array(state.records.keys) {
                clearPosition(forKey: key, in: &state)
            }
        }
        notifyChanged()
    }

    /// Purges all stored playback positions and preferences that match the given exclusion policy,
    /// as well as records for any explicit keys and paths provided.
    public func purge(
        matching policy: HistoryExclusionPolicy,
        knownKeysAndPaths: [(key: String, path: String)] = []
    ) {
        withLoadedState { state in
            let before = state.records.count
            state.records = state.records.filter { _, record in
                guard let mediaPath = record.mediaPath else { return true }
                return !policy.isExcluded(pathOrURL: mediaPath)
            }
            var didRemove = state.records.count != before
            for (key, path) in knownKeysAndPaths
            where policy.isExcluded(pathOrURL: path) || policy.isExcluded(pathOrURL: key) {
                if state.records.removeValue(forKey: storageKey(for: key)) != nil { didRemove = true }
                if state.records.removeValue(forKey: storageKey(for: path)) != nil { didRemove = true }
            }
            if didRemove {
                state.generation += 1
            }
        }
        notifyChanged()
    }

    /// Writes the history now if it changed since the last write; for the process's last moments, when a delayed save
    /// would not run.
    public func flush() {
        guard fileURL != nil else { return }
        ioQueue.sync { saveOnQueue() }
    }

    // MARK: - Storage

    /// The record of `media`, unless excluded (by `media` or the path the record keeps).
    private func record(for media: MediaHistoryIdentity) -> PlaybackRecord? {
        let key = storageKey(for: media.historyKey)
        return withLoadedState { state in
            guard let record = state.records[key],
                !Self.isExcluded(media, recordMediaPath: record.mediaPath, policy: state.exclusionPolicy)
            else { return nil }
            return record
        }
    }

    /// Writes a record and removes the oldest ones over the limit.
    private func store(_ record: PlaybackRecord, forKey key: String, in state: inout State) {
        state.generation += 1
        let isNew = state.records.updateValue(record, forKey: key) == nil
        guard isNew else { return }
        while state.records.count > maxRecordsLimit,
            let oldest = state.records.min(by: { $0.value.lastUpdated < $1.value.lastUpdated })?.key
        {
            state.records[oldest] = nil
        }
    }

    /// Resets the position of `key` to 0 when the record has preferences worth keeping, or removes the record.
    private func clearPosition(forKey key: String, in state: inout State) {
        guard let existing = state.records[key] else { return }
        if existing.preferences.isEmpty {
            state.records[key] = nil
            state.generation += 1
        } else if existing.position != 0 {
            state.generation += 1
            state.records[key] = PlaybackRecord(
                position: 0.0,
                duration: existing.duration,
                lastUpdated: existing.lastUpdated,
                preferences: existing.preferences,
                mediaPath: existing.mediaPath
            )
        }
    }

    /// Runs `body` on the state with the file read, and schedules a save if it changed the records, which a change
    /// tells by moving `generation`.
    @discardableResult
    private func withLoadedState<T>(_ body: (inout State) -> T) -> T {
        loadIfNeeded()
        let (result, shouldScheduleSave) = lock.withLockUnchecked { state -> (T, Bool) in
            let generation = state.generation
            let result = body(&state)
            guard state.generation != generation, fileURL != nil, !state.isSaveScheduled else { return (result, false) }
            state.isSaveScheduled = true
            return (result, true)
        }
        if shouldScheduleSave {
            ioQueue.asyncAfter(deadline: .now() + saveDelaySeconds) { [self] in
                saveOnQueue()
            }
        }
        return result
    }

    private var saveDelaySeconds: TimeInterval {
        let (seconds, attoseconds) = saveDelay.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }

    /// Reads the file before the first use. The read `init` queued is ahead of this one on `ioQueue`, so a call that
    /// comes while it goes on waits for it, and this one finds the history read.
    private func loadIfNeeded() {
        guard !lock.withLock({ $0.isLoaded }) else { return }
        ioQueue.sync { loadOnQueue() }
    }

    private func loadOnQueue() {
        guard !lock.withLock({ $0.isLoaded }) else { return }
        let records = readFileOnQueue()
        lock.withLock { state in
            state.records = records
            state.isLoaded = true
        }
    }

    /// The records in the file; none when there is no file. A record that does not decode is dropped, not the
    /// history. A file that does not decode is moved aside (`<name>.unreadable-<time>.json`); one that does not read,
    /// or cannot be moved, is left as it is and not written over (`isFileWritable`): the history of this run stays in
    /// memory.
    private func readFileOnQueue() -> [String: PlaybackRecord] {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            isFileWritable = false
            AppLog.warning(.engine, "Could not read playback history, leaving it alone: \(error.localizedDescription)")
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: StoredRecord].self, from: data).compactMapValues(\.record)
        } catch {
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                .appendingPathExtension(fileURL.pathExtension)
            do {
                try FileManager.default.moveItem(at: fileURL, to: aside)
                AppLog.warning(
                    .engine,
                    "Could not decode playback history, moved it to \(aside.lastPathComponent): \(error.localizedDescription)"
                )
            } catch let moveError {
                isFileWritable = false
                AppLog.warning(
                    .engine,
                    "Could not decode playback history nor move it aside, leaving it alone: \(moveError.localizedDescription)"
                )
            }
            return [:]
        }
    }

    private struct StoredRecord: Decodable {
        let record: PlaybackRecord?

        init(from decoder: any Decoder) throws {
            record = try? PlaybackRecord(from: decoder)
        }
    }

    /// Writes the history if it changed since the file was written; on `ioQueue`.
    private func saveOnQueue() {
        guard let fileURL else { return }
        let snapshot = lock.withLock { state -> (generation: Int, records: [String: PlaybackRecord])? in
            state.isSaveScheduled = false
            guard state.isLoaded else { return nil }
            return (state.generation, state.records)
        }
        guard let snapshot, isFileWritable, writtenGeneration < snapshot.generation,
            let data = try? JSONEncoder().encode(snapshot.records)
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            writtenGeneration = snapshot.generation
            isRetryingSave = false
        } catch {
            // Tried again until it is written (a full disk), not left for the next change, which may not come before
            // the process ends; told once. The retry holds the store weakly: one that is gone stops trying.
            if !isRetryingSave {
                AppLog.warning(.engine, "Could not save playback history: \(error.localizedDescription)")
            }
            isRetryingSave = true
            guard !isRetryScheduled else { return }
            isRetryScheduled = true
            ioQueue.asyncAfter(deadline: .now() + saveDelaySeconds) { [weak self] in
                guard let self else { return }
                isRetryScheduled = false
                saveOnQueue()
            }
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
