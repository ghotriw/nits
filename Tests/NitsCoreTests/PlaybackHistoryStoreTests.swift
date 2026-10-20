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
        let path = "/Users/test/Movies/feature_film.mkv"

        // Within eligible range: > 15s and < 95% of 3600s (3420s) and > 30s from end
        store.savePosition(for: path, position: 120.0, duration: 3600.0, startThreshold: 15.0, endThresholdRatio: 0.95)

        let retrieved = store.savedPosition(for: path, startThreshold: 15.0, endThresholdRatio: 0.95)
        #expect(retrieved == 120.0)
    }

    @Test("PlaybackHistoryStore discards position under startThreshold")
    func testDiscardsUnderStartThreshold() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let path = "/Users/test/Movies/short_preview.mkv"

        // Under 15s threshold -> treated as unplayed (not saved or cleared)
        store.savePosition(for: path, position: 10.0, duration: 600.0, startThreshold: 15.0, endThresholdRatio: 0.95)

        let retrieved = store.savedPosition(for: path, startThreshold: 15.0, endThresholdRatio: 0.95)
        #expect(retrieved == nil)
    }

    @Test("PlaybackHistoryStore discards position exceeding end completion threshold")
    func testDiscardsExceedingEndThreshold() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let path = "/Users/test/Movies/finished_movie.mkv"

        // 96% of 1000s duration (960s > 950s) -> considered completed, cleared
        store.savePosition(for: path, position: 960.0, duration: 1000.0, startThreshold: 15.0, endThresholdRatio: 0.95)

        let retrieved = store.savedPosition(for: path, startThreshold: 15.0, endThresholdRatio: 0.95)
        #expect(retrieved == nil)
    }

    @Test("PlaybackHistoryStore normalizes HTTP URLs by stripping query parameters")
    func testNormalizesURLQueryParameters() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)

        let sessionUrl1 = "https://media.server/stream.mkv?token=alpha123&session=456"
        let sessionUrl2 = "https://media.server/stream.mkv?token=beta789&session=999"

        store.savePosition(for: sessionUrl1, position: 500.0, duration: 2000.0)

        // Same stream resource opened with new token should restore the same position
        let retrieved = store.savedPosition(for: sessionUrl2)
        #expect(retrieved == 500.0)
    }

    @Test("PlaybackHistoryStore clearPosition and clearAll remove records")
    func testClearRecords() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let path1 = "/movies/film1.mkv"
        let path2 = "/movies/film2.mkv"

        store.savePosition(for: path1, position: 100.0, duration: 1000.0)
        store.savePosition(for: path2, position: 200.0, duration: 1000.0)

        store.clearPosition(for: path1)
        #expect(store.savedPosition(for: path1) == nil)
        #expect(store.savedPosition(for: path2) == 200.0)

        store.clearAll()
        #expect(store.savedPosition(for: path2) == nil)
    }

    @Test("PlaybackHistoryStore preserves and decodes audio and subtitle track selections")
    func testTrackSelectionPersistenceAndBackwardCompatibility() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let path = "/movies/film_with_tracks.mkv"

        // 1. Save position with tracks
        store.savePosition(
            for: path,
            position: 120.0,
            duration: 1000.0,
            preferences: PlaybackPreferences(audioTrackId: 2, subtitleTrackId: 1)
        )

        let tracks = store.savedPreferences(for: path)
        #expect(tracks?.audioTrackId == 2)
        #expect(tracks?.subtitleTrackId == 1)

        // 2. Explicitly update tracks at position 0 / start of video
        store.savePreferences(
            for: path,
            duration: 1000.0,
            PlaybackPreferences(audioTrackId: 3, subtitleTrackId: PlaybackRecord.subtitlesOff)
        )
        let updatedTracks = store.savedPreferences(for: path)
        #expect(updatedTracks?.audioTrackId == 3)
        #expect(updatedTracks?.subtitleTrackId == PlaybackRecord.subtitlesOff)
        // Position was preserved
        #expect(store.savedPosition(for: path) == 120.0)

        // 3. Backward compatibility: verify decoding legacy JSON record without track fields
        let legacyPath = "/movies/legacy_film.mkv"
        let legacyKey = store.storageKey(for: legacyPath)
        let legacyJSON = """
            {
                "position": 350.0,
                "duration": 1800.0,
                "lastUpdated": 700000000.0
            }
            """.data(using: .utf8)!
        defaults.set(legacyJSON, forKey: legacyKey)

        let legacyPos = store.savedPosition(for: legacyPath)
        #expect(legacyPos == 350.0)
        let legacyTracks = store.savedPreferences(for: legacyPath)
        #expect(legacyTracks?.audioTrackId == nil)
        #expect(legacyTracks?.subtitleTrackId == nil)
        #expect(legacyTracks?.subtitleDelay == nil)
    }

    @Test("PlaybackHistoryStore keeps the subtitle delay across saves and lets an explicit 0 override it")
    func testSubtitleDelayPersistence() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let path = "/movies/out_of_sync.mkv"

        // A delay alone keeps the record even at the start of the file.
        store.savePreferences(for: path, duration: 1000.0, PlaybackPreferences(subtitleDelay: 1.4))
        #expect(store.savedPreferences(for: path)?.subtitleDelay == 1.4)

        // `nil` keeps the saved delay.
        store.savePosition(for: path, position: 120.0, duration: 1000.0)
        #expect(store.savedPreferences(for: path)?.subtitleDelay == 1.4)
        #expect(store.savedPosition(for: path) == 120.0)

        store.savePosition(
            for: path, position: 130.0, duration: 1000.0, preferences: PlaybackPreferences(subtitleDelay: 0))
        #expect(store.savedPreferences(for: path)?.subtitleDelay == 0)
    }

    @Test("PlaybackHistoryStore keeps preferences of a finished file and resets only its position")
    func testFinishedFileKeepsPreferences() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let path = "/movies/watched.mkv"

        store.savePosition(
            for: path, position: 300.0, duration: 1000.0,
            preferences: PlaybackPreferences(subtitleTrackId: 2, subtitleDelay: -0.6))
        store.savePosition(for: path, position: 990.0, duration: 1000.0)

        #expect(store.savedPosition(for: path) == nil)
        let preferences = store.savedPreferences(for: path)
        #expect(preferences?.subtitleTrackId == 2)
        #expect(preferences?.subtitleDelay == -0.6)

        // Without preferences, a finished or barely started file leaves no record.
        let plainPath = "/movies/plain.mkv"
        store.savePosition(
            for: plainPath, position: 300.0, duration: 1000.0, preferences: PlaybackPreferences(subtitleDelay: 0))
        store.savePosition(for: plainPath, position: 990.0, duration: 1000.0)
        #expect(store.savedPreferences(for: plainPath) == nil)
    }

    @Test("PlaybackHistoryStore saves an external subtitle selection by path")
    func testExternalSubtitlePersistence() {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let path = "/movies/with_sidecar.mkv"
        let external = PlaybackPreferences(
            subtitleTrackId: PlaybackRecord.externalSubtitle,
            externalSubtitlePath: "/movies/with_sidecar.en.srt"
        )

        store.savePreferences(for: path, duration: 1000.0, external)
        #expect(store.savedPreferences(for: path) == external)

        // Switching to an embedded track replaces the selection; the stale path is ignored on restore.
        store.savePreferences(for: path, duration: 1000.0, PlaybackPreferences(subtitleTrackId: 1))
        #expect(store.savedPreferences(for: path)?.subtitleTrackId == 1)
    }

    @Test("The stream of a saved VobSub index is kept with its path, and a new path doesn't inherit it")
    func testExternalSubtitleStream() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        let path = "/movies/disc.mkv"
        store.savePreferences(
            for: path, duration: 1000.0,
            PlaybackPreferences(
                subtitleTrackId: PlaybackRecord.externalSubtitle, externalSubtitlePath: "/movies/disc.idx",
                externalSubtitleStreamIndex: 1))
        #expect(store.savedPreferences(for: path)?.externalSubtitleStreamIndex == 1)

        // A save that doesn't touch the subtitle file keeps its stream.
        store.savePreferences(for: path, duration: 1000.0, PlaybackPreferences(subtitleDelay: 0.5))
        #expect(store.savedPreferences(for: path)?.externalSubtitleStreamIndex == 1)

        store.savePreferences(
            for: path, duration: 1000.0,
            PlaybackPreferences(
                subtitleTrackId: PlaybackRecord.externalSubtitle, externalSubtitlePath: "/movies/disc.en.srt"))
        #expect(store.savedPreferences(for: path)?.externalSubtitleStreamIndex == nil)
    }
}

@Suite("PlaybackHistoryStore Picture Geometry")
struct PlaybackHistoryGeometryTests {
    private let path = "/Users/test/Movies/letterboxed.mkv"
    private let wide = RationalAspectRatio(numerator: 239, denominator: 100)

    @Test("Aspect override and crop are kept without a resume position and can be cleared")
    func testSavesAndClearsGeometry() {
        let store = PlaybackHistoryStore(userDefaults: InMemoryUserDefaults())
        store.savePosition(
            for: path, position: 0, duration: 3600,
            preferences: PlaybackPreferences(videoAspectRatio: PlaybackPreferences.noGeometryOverride, videoCrop: wide))
        #expect(store.savedPreferences(for: path)?.videoCrop == wide)
        #expect(store.savedPreferences(for: path)?.videoAspectRatio?.isValid == false)

        // `nil` keeps the saved crop.
        store.savePreferences(for: path, duration: 3600, PlaybackPreferences(subtitleDelay: 0.5))
        #expect(store.savedPreferences(for: path)?.videoCrop == wide)

        // Cleared with nothing else to keep: the record goes away.
        store.savePosition(
            for: path, position: 0, duration: 3600,
            preferences: PlaybackPreferences(
                subtitleDelay: 0, videoAspectRatio: PlaybackPreferences.noGeometryOverride,
                videoCrop: PlaybackPreferences.noGeometryOverride))
        #expect(store.savedPreferences(for: path) == nil)
    }

    @Test("Records saved before picture geometry existed still decode")
    func testDecodesRecordsWithoutGeometry() throws {
        let defaults = InMemoryUserDefaults()
        let store = PlaybackHistoryStore(userDefaults: defaults)
        let legacy = #"{"position":120,"duration":3600,"lastUpdated":0,"subtitleDelay":0.2}"#
        defaults.set(Data(legacy.utf8), forKey: store.storageKey(for: path))
        let preferences = try #require(store.savedPreferences(for: path))
        #expect(preferences.subtitleDelay == 0.2)
        #expect(preferences.videoAspectRatio == nil && preferences.videoCrop == nil)
    }
}
