import Foundation
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
            audioTrackId: 2,
            subtitleTrackId: 1
        )

        let tracks = store.savedTrackSelection(for: path)
        #expect(tracks?.audioTrackId == 2)
        #expect(tracks?.subtitleTrackId == 1)

        // 2. Explicitly update tracks at position 0 / start of video
        store.saveTrackSelection(
            for: path,
            duration: 1000.0,
            audioTrackId: 3,
            subtitleTrackId: PlaybackRecord.subtitlesOff
        )
        let updatedTracks = store.savedTrackSelection(for: path)
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
        let legacyTracks = store.savedTrackSelection(for: legacyPath)
        #expect(legacyTracks?.audioTrackId == nil)
        #expect(legacyTracks?.subtitleTrackId == nil)
    }
}
