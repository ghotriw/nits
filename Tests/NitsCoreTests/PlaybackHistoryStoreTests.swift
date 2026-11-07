import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("PlaybackHistoryStore & Resume Tests")
struct PlaybackHistoryStoreTests {

    @Test("PlaybackHistoryStore saves and retrieves eligible playback positions")
    func testSaveAndRetrieveEligiblePosition() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let media = MediaHistoryIdentity(historyKey: "/Users/test/Movies/feature_film.mkv")

        // Within eligible range: > 15s and < 95% of 3600s (3420s) and > 30s from end
        store.savePosition(for: media, position: 120.0, duration: 3600.0, startThreshold: 15.0, endThresholdRatio: 0.95)

        let retrieved = store.savedPosition(for: media, startThreshold: 15.0, endThresholdRatio: 0.95)
        #expect(retrieved == 120.0)
    }

    @Test(
        "A live stream's history keeps its position in the stream's time, at its edge too, and says it was at the edge")
    func testLiveHistoryPositions() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        let media = MediaHistoryIdentity(historyKey: "youtube:live")
        // Ten days into a stream that is 20 days old (1 728 000 s), its window's end the stream's time now.
        let streamAge = 1_728_000.0
        store.savePosition(for: media, position: 864_000, duration: streamAge, isLive: true, wasAtLiveEdge: false)
        let left = store.savedLivePosition(for: media)
        #expect(left?.position == 864_000)
        #expect(left?.wasAtEdge == false)

        // At the edge: not "finished", as a recording near its end would be: kept, and marked.
        store.savePosition(for: media, position: streamAge - 4, duration: streamAge, isLive: true, wasAtLiveEdge: true)
        let atEdge = store.savedLivePosition(for: media)
        #expect(atEdge?.position == streamAge - 4)
        #expect(atEdge?.wasAtEdge == true)
        // The recording of it that follows the stream is judged as any: a position at its end starts over, one before
        // it resumes.
        #expect(store.savedPosition(for: media) == nil)
        store.savePosition(for: media, position: 864_000, duration: streamAge, isLive: true, wasAtLiveEdge: false)
        #expect(store.savedPosition(for: media) == 864_000)
        // A recording's own save at its end (not live) is finished, and a live one of nothing is not saved.
        store.savePosition(for: media, position: streamAge - 4, duration: streamAge)
        #expect(store.savedPosition(for: media) == nil)
        #expect(store.savedLivePosition(for: media) == nil, "a finished recording has no position to resume")
    }

    @Test("A live position survives a save of preferences, and an old record without the mark is not at the edge")
    func testLiveHistoryPositionKeepsItsMark() throws {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let media = MediaHistoryIdentity(historyKey: "youtube:live2")
        store.savePosition(for: media, position: 5000, duration: 9000, isLive: true, wasAtLiveEdge: true)
        store.savePreferences(for: media, duration: 9100, PlaybackPreferences(audioDelay: 0.25))
        let kept = store.savedLivePosition(for: media)
        #expect(kept?.position == 5000)
        #expect(kept?.wasAtEdge == true)
        #expect(store.savedPreferences(for: media)?.audioDelay == 0.25)

        // A record from before the mark existed, as it was written.
        let old = MediaHistoryIdentity(historyKey: "youtube:old")
        store.savePosition(for: old, position: 700, duration: 3600)
        #expect(store.savedLivePosition(for: old)?.wasAtEdge == false)
    }

    @Test(
        "The end of a media is a share of it but no more than ten minutes: a long stream is not finished an hour from its end"
    )
    func testCompletionTailIsCapped() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        let twentyHours = 72_000.0
        let stream = MediaHistoryIdentity(historyKey: "youtube:long")
        // 5% of twenty hours is an hour; the tail counts ten minutes of it.
        store.savePosition(for: stream, position: twentyHours - 2_880, duration: twentyHours)
        #expect(store.savedPosition(for: stream) == twentyHours - 2_880, "forty-eight minutes from the end resumes")
        store.savePosition(for: stream, position: twentyHours - 540, duration: twentyHours)
        #expect(store.savedPosition(for: stream) == nil, "nine minutes from the end starts over")

        // A film's 5% is under ten minutes, so it is as it was: a share of it, and its last 30 s.
        let film = MediaHistoryIdentity(historyKey: "/Users/test/Movies/film.mkv")
        let twoHours = 7_200.0
        store.savePosition(for: film, position: twoHours - 400, duration: twoHours)
        #expect(store.savedPosition(for: film) == twoHours - 400, "6 min 40 s from the end of a film: 5% is 6 min")
        store.savePosition(for: film, position: twoHours - 300, duration: twoHours)
        #expect(store.savedPosition(for: film) == nil)
        // A short one: the share is under 30 s, the last 30 s count.
        let clip = MediaHistoryIdentity(historyKey: "/Users/test/Movies/clip.mkv")
        store.savePosition(for: clip, position: 180 - 29, duration: 180)
        #expect(store.savedPosition(for: clip) == nil)
        store.savePosition(for: clip, position: 90, duration: 180)
        #expect(store.savedPosition(for: clip) == 90)
    }

    @Test("PlaybackHistoryStore discards position under startThreshold")
    func testDiscardsUnderStartThreshold() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let media = MediaHistoryIdentity(historyKey: "/Users/test/Movies/short_preview.mkv")

        // Under 15s threshold -> treated as unplayed (not saved or cleared)
        store.savePosition(for: media, position: 10.0, duration: 600.0, startThreshold: 15.0, endThresholdRatio: 0.95)

        let retrieved = store.savedPosition(for: media, startThreshold: 15.0, endThresholdRatio: 0.95)
        #expect(retrieved == nil)
    }

    @Test("PlaybackHistoryStore discards position exceeding end completion threshold")
    func testDiscardsExceedingEndThreshold() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let media = MediaHistoryIdentity(historyKey: "/Users/test/Movies/finished_movie.mkv")

        // 96% of 1000s duration (960s > 950s) -> considered completed, cleared
        store.savePosition(for: media, position: 960.0, duration: 1000.0, startThreshold: 15.0, endThresholdRatio: 0.95)

        let retrieved = store.savedPosition(for: media, startThreshold: 15.0, endThresholdRatio: 0.95)
        #expect(retrieved == nil)
    }

    @Test("PlaybackHistoryStore normalizes HTTP URLs by stripping query parameters")
    func testNormalizesURLQueryParameters() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)

        let sessionUrl1 = MediaHistoryIdentity(historyKey: "https://media.server/stream.mkv?token=alpha123&session=456")
        let sessionUrl2 = MediaHistoryIdentity(historyKey: "https://media.server/stream.mkv?token=beta789&session=999")

        store.savePosition(for: sessionUrl1, position: 500.0, duration: 2000.0)

        // Same stream resource opened with new token should restore the same position
        let retrieved = store.savedPosition(for: sessionUrl2)
        #expect(retrieved == 500.0)
    }

    @Test("A resolved page's name for its media keys a record of its own")
    func testKeepsNamesOfOtherSchemes() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        #expect(store.storageKey(for: "youtube:dQw4w9WgXcQ") != store.storageKey(for: "youtube:jNQXAC9IVRw"))
        // Not a path under the working directory, as before: its record would move with it.
        #expect(
            store.storageKey(for: "youtube:dQw4w9WgXcQ")
                != store.storageKey(for: FileManager.default.currentDirectoryPath + "/youtube:dQw4w9WgXcQ"))
        // Local paths stay standardized.
        #expect(store.storageKey(for: "/Users/test/./a.mkv") == store.storageKey(for: "/Users/test/a.mkv"))
    }

    @Test("PlaybackHistoryStore clearPosition and clearAll reset positions while keeping per-file preferences")
    func testClearRecords() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let path1 = "/movies/film1.mkv"
        let media1 = MediaHistoryIdentity(historyKey: path1)
        let media2 = MediaHistoryIdentity(historyKey: "/movies/film2.mkv")

        #expect(!store.hasSavedPositions)

        store.savePosition(for: media1, position: 100.0, duration: 1000.0)
        store.savePosition(
            for: media2,
            position: 200.0,
            duration: 1000.0,
            preferences: PlaybackPreferences(audioTrackId: 2, subtitleTrackId: 1)
        )
        #expect(store.hasSavedPositions)

        store.clearPosition(for: path1)
        #expect(store.savedPosition(for: media1) == nil)
        #expect(store.savedPosition(for: media2) == 200.0)
        #expect(store.hasSavedPositions)

        store.clearAll()
        #expect(store.savedPosition(for: media2) == nil)
        #expect(!store.hasSavedPositions)
        #expect(store.savedPreferences(for: media2)?.audioTrackId == 2)
        #expect(store.savedPreferences(for: media2)?.subtitleTrackId == 1)
    }

    @Test("PlaybackHistoryStore preserves and decodes audio and subtitle track selections")
    func testTrackSelectionPersistenceAndBackwardCompatibility() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let media = MediaHistoryIdentity(historyKey: "/movies/film_with_tracks.mkv")

        // 1. Save position with tracks
        store.savePosition(
            for: media,
            position: 120.0,
            duration: 1000.0,
            preferences: PlaybackPreferences(audioTrackId: 2, subtitleTrackId: 1)
        )

        let tracks = store.savedPreferences(for: media)
        #expect(tracks?.audioTrackId == 2)
        #expect(tracks?.subtitleTrackId == 1)

        // 2. Explicitly update tracks at position 0 / start of video
        store.savePreferences(
            for: media,
            duration: 1000.0,
            PlaybackPreferences(audioTrackId: 3, subtitleTrackId: PlaybackRecord.subtitlesOff)
        )
        let updatedTracks = store.savedPreferences(for: media)
        #expect(updatedTracks?.audioTrackId == 3)
        #expect(updatedTracks?.subtitleTrackId == PlaybackRecord.subtitlesOff)
        // Position was preserved
        #expect(store.savedPosition(for: media) == 120.0)

        // 3. Backward compatibility: verify decoding legacy JSON record without track fields
        let legacyPath = "/movies/legacy_film.mkv"
        let legacyMedia = MediaHistoryIdentity(historyKey: legacyPath)
        let legacyKey = store.storageKey(for: legacyPath)
        let legacyJSON = """
            {
                "position": 350.0,
                "duration": 1800.0,
                "lastUpdated": 700000000.0
            }
            """.data(using: .utf8)!
        defaults.set(legacyJSON, forKey: legacyKey)

        let legacyPos = store.savedPosition(for: legacyMedia)
        #expect(legacyPos == 350.0)
        let legacyTracks = store.savedPreferences(for: legacyMedia)
        #expect(legacyTracks?.audioTrackId == nil)
        #expect(legacyTracks?.subtitleTrackId == nil)
        #expect(legacyTracks?.subtitleDelays == nil)
    }

    @Test("PlaybackHistoryStore keeps the subtitle delay across saves and lets an explicit 0 override it")
    func testSubtitleDelayPersistence() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let media = MediaHistoryIdentity(historyKey: "/movies/out_of_sync.mkv")

        // A delay alone keeps the record even at the start of the file.
        store.savePreferences(for: media, duration: 1000.0, PlaybackPreferences(subtitleDelays: ["s1": 1.4]))
        #expect(store.savedPreferences(for: media)?.subtitleDelays == ["s1": 1.4])

        // `nil` keeps the saved delay.
        store.savePosition(for: media, position: 120.0, duration: 1000.0)
        #expect(store.savedPreferences(for: media)?.subtitleDelays == ["s1": 1.4])
        #expect(store.savedPosition(for: media) == 120.0)

        store.savePosition(
            for: media, position: 130.0, duration: 1000.0, preferences: PlaybackPreferences(subtitleDelays: ["s1": 0]))
        #expect(store.savedPreferences(for: media)?.subtitleDelays == ["s1": 0])
    }

    @Test("PlaybackHistoryStore keeps preferences of a finished file and resets only its position")
    func testFinishedFileKeepsPreferences() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let media = MediaHistoryIdentity(historyKey: "/movies/watched.mkv")

        store.savePosition(
            for: media, position: 300.0, duration: 1000.0,
            preferences: PlaybackPreferences(subtitleTrackId: 2, subtitleDelays: ["s1": -0.6]))
        store.savePosition(for: media, position: 990.0, duration: 1000.0)

        #expect(store.savedPosition(for: media) == nil)
        let preferences = store.savedPreferences(for: media)
        #expect(preferences?.subtitleTrackId == 2)
        #expect(preferences?.subtitleDelays == ["s1": -0.6])

        // Without preferences, a finished or barely started file leaves no record.
        let plainMedia = MediaHistoryIdentity(historyKey: "/movies/plain.mkv")
        store.savePosition(
            for: plainMedia, position: 300.0, duration: 1000.0,
            preferences: PlaybackPreferences(subtitleDelays: ["s1": 0]))
        store.savePosition(for: plainMedia, position: 990.0, duration: 1000.0)
        #expect(store.savedPreferences(for: plainMedia) == nil)
    }

    @Test("PlaybackHistoryStore saves an external subtitle selection by path")
    func testExternalSubtitlePersistence() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let media = MediaHistoryIdentity(historyKey: "/movies/with_sidecar.mkv")
        let external = PlaybackPreferences(
            subtitleTrackId: PlaybackRecord.externalSubtitle,
            externalSubtitlePath: "/movies/with_sidecar.en.srt"
        )

        store.savePreferences(for: media, duration: 1000.0, external)
        #expect(store.savedPreferences(for: media) == external)

        // Switching to an embedded track replaces the selection; the stale path is ignored on restore.
        store.savePreferences(for: media, duration: 1000.0, PlaybackPreferences(subtitleTrackId: 1))
        #expect(store.savedPreferences(for: media)?.subtitleTrackId == 1)
    }

    @Test("A network subtitle file is saved by what it is, and choosing another track drops it")
    func testListedSubtitlePersistence() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        let media = MediaHistoryIdentity(historyKey: "https://video.example/watch?v=subs")
        let listed = ListedSubtitle(language: "uk", title: "Ukrainian (auto-generated)", isAutoGenerated: true)
        store.savePreferences(
            for: media, duration: 1000.0,
            PlaybackPreferences(subtitleTrackId: PlaybackRecord.listedSubtitle, listedSubtitle: listed))
        #expect(store.savedPreferences(for: media)?.listedSubtitle == listed)

        store.savePreferences(for: media, duration: 1000.0, PlaybackPreferences(subtitleDelays: ["s1": 0.5]))
        #expect(store.savedPreferences(for: media)?.listedSubtitle == listed)

        store.savePreferences(for: media, duration: 1000.0, PlaybackPreferences(subtitleTrackId: 1))
        #expect(store.savedPreferences(for: media)?.listedSubtitle == nil)
    }

    @Test("The stream of a saved VobSub index is kept with its path, and a new path doesn't inherit it")
    func testExternalSubtitleStream() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        let media = MediaHistoryIdentity(historyKey: "/movies/disc.mkv")
        store.savePreferences(
            for: media, duration: 1000.0,
            PlaybackPreferences(
                subtitleTrackId: PlaybackRecord.externalSubtitle, externalSubtitlePath: "/movies/disc.idx",
                externalSubtitleStreamIndex: 1))
        #expect(store.savedPreferences(for: media)?.externalSubtitleStreamIndex == 1)

        // A save that doesn't touch the subtitle file keeps its stream.
        store.savePreferences(for: media, duration: 1000.0, PlaybackPreferences(subtitleDelays: ["s1": 0.5]))
        #expect(store.savedPreferences(for: media)?.externalSubtitleStreamIndex == 1)

        store.savePreferences(
            for: media, duration: 1000.0,
            PlaybackPreferences(
                subtitleTrackId: PlaybackRecord.externalSubtitle, externalSubtitlePath: "/movies/disc.en.srt"))
        #expect(store.savedPreferences(for: media)?.externalSubtitleStreamIndex == nil)
    }

    @Test("PlaybackHistoryStore enforces exclusionPolicy directly on saves and reads")
    func testExclusionPolicyEnforcedInStore() {
        let defaults = InMemoryUserDefaults()
        let policy = HistoryExclusionPolicy(
            excludedPaths: ["/Users/test/Secret"],
            excludedDomains: ["private.example.com"]
        )
        let store = PlaybackHistoryStore(userDefaults: defaults, exclusionPolicy: policy)

        // Excluded local path is rejected on savePosition and savePreferences
        let secretFile = MediaHistoryIdentity(historyKey: "/Users/test/Secret/clip.mkv")
        store.savePosition(for: secretFile, position: 100.0, duration: 600.0)
        store.savePreferences(for: secretFile, duration: 600.0, PlaybackPreferences(audioTrackId: 2))
        #expect(store.savedPosition(for: secretFile) == nil)
        #expect(store.savedPreferences(for: secretFile) == nil)
        #expect(!store.hasSavedPositions)

        // Excluded resolver identity (via page URL in `path`) is rejected even though `historyKey` has no domain
        let resolvedIdentity = MediaHistoryIdentity(
            historyKey: "resolver:12345",
            path: "https://private.example.com/watch/12345",
            sourcePath: "https://cdn.other.org/stream.m3u8"
        )
        store.savePosition(for: resolvedIdentity, position: 120.0, duration: 500.0)
        store.savePreferences(for: resolvedIdentity, duration: 500.0, PlaybackPreferences(subtitleTrackId: 1))
        #expect(store.savedPosition(for: MediaHistoryIdentity(historyKey: "resolver:12345")) == nil)
        #expect(store.savedPreferences(for: MediaHistoryIdentity(historyKey: "resolver:12345")) == nil)

        // Allowed media is saved, then hidden once exclusionPolicy is updated to exclude it
        let laterExcluded = MediaHistoryIdentity(historyKey: "/Users/test/LaterExcluded/film.mkv")
        store.savePosition(
            for: laterExcluded,
            position: 200.0,
            duration: 1000.0,
            preferences: PlaybackPreferences(audioTrackId: 1)
        )
        #expect(store.savedPosition(for: laterExcluded) == 200.0)
        #expect(store.savedPreferences(for: laterExcluded)?.audioTrackId == 1)

        store.exclusionPolicy = HistoryExclusionPolicy(excludedPaths: ["/Users/test/LaterExcluded"])
        #expect(store.savedPosition(for: laterExcluded) == nil)
        #expect(store.savedPreferences(for: laterExcluded) == nil)
    }
}

@Suite("PlaybackHistoryStore Picture Geometry")
struct PlaybackHistoryGeometryTests {
    private let path = "/Users/test/Movies/letterboxed.mkv"
    private var media: MediaHistoryIdentity { MediaHistoryIdentity(historyKey: path) }
    private let wide = RationalAspectRatio(numerator: 239, denominator: 100)

    @Test("Aspect override and crop are kept without a resume position and can be cleared")
    func testSavesAndClearsGeometry() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        store.savePosition(
            for: media, position: 0, duration: 3600,
            preferences: PlaybackPreferences(videoAspectRatio: PlaybackPreferences.noGeometryOverride, videoCrop: wide))
        #expect(store.savedPreferences(for: media)?.videoCrop == wide)
        #expect(store.savedPreferences(for: media)?.videoAspectRatio?.isValid == false)

        // `nil` keeps the saved crop.
        store.savePreferences(for: media, duration: 3600, PlaybackPreferences(subtitleDelays: ["s1": 0.5]))
        #expect(store.savedPreferences(for: media)?.videoCrop == wide)

        // Cleared with nothing else to keep: the record goes away.
        store.savePosition(
            for: media, position: 0, duration: 3600,
            preferences: PlaybackPreferences(
                subtitleDelays: ["s1": 0], videoAspectRatio: PlaybackPreferences.noGeometryOverride,
                videoCrop: PlaybackPreferences.noGeometryOverride))
        #expect(store.savedPreferences(for: media) == nil)
    }

    @Test("A chosen speed, 1× included, is kept without a resume position, and a save without one keeps it")
    func testSavesPlaybackRate() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        store.savePreferences(for: media, duration: 3600, PlaybackPreferences(playbackRate: 1.5))
        #expect(store.savedPreferences(for: media)?.playbackRate == 1.5)

        store.savePreferences(for: media, duration: 3600, PlaybackPreferences(subtitleDelays: ["s1": 0.5]))
        #expect(store.savedPreferences(for: media)?.playbackRate == 1.5)

        // A chosen 1× is kept with nothing else to keep, on either path.
        store.savePosition(
            for: media, position: 0, duration: 3600,
            preferences: PlaybackPreferences(subtitleDelays: ["s1": 0], playbackRate: 1))
        #expect(store.savedPreferences(for: media)?.playbackRate == 1)
    }

    @Test("Records saved before picture geometry existed still decode")
    func testDecodesRecordsWithoutGeometry() throws {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let legacy = #"{"position":120,"duration":3600,"lastUpdated":0,"subtitleDelays":{"s1":0.2}}"#
        defaults.set(Data(legacy.utf8), forKey: store.storageKey(for: path))
        let preferences = try #require(store.savedPreferences(for: media))
        #expect(preferences.subtitleDelays == ["s1": 0.2])
        #expect(preferences.videoAspectRatio == nil && preferences.videoCrop == nil)
    }
}
