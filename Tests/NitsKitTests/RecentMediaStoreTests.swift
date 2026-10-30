import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore
@testable import NitsUI

@Suite("RecentMediaStore Tests")
struct RecentMediaStoreTests {

    @Test("RecentMediaStore records and orders items by most recent first")
    @MainActor
    func testRecordAndOrder() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore, maxItemsLimit: 5)

        let tempDir = FileManager.default.temporaryDirectory
        let url1 = tempDir.appendingPathComponent("film1.mkv")
        let url2 = tempDir.appendingPathComponent("film2.mkv")
        let streamURL = URL(string: "https://example.com/live/stream.m3u8")!

        store.record(url: url1, title: "Film 1", duration: 120.0)
        store.record(url: url2, title: "Film 2", duration: 240.0)
        store.record(url: streamURL, title: "Stream Live", duration: 0.0)

        #expect(store.items.count == 3)
        #expect(store.items[0].title == "Stream Live")
        #expect(store.items[0].isNetwork == true)
        #expect(store.items[1].title == "Film 2")
        #expect(store.items[2].title == "Film 1")

        // Re-recording Film 1 moves it to index 0
        store.record(url: url1, title: "Film 1 Reopened", duration: 120.0)
        #expect(store.items.count == 3)
        #expect(store.items[0].title == "Film 1 Reopened")
        let expectedPath = MediaURL.normalizeMediaPath(url1.path(percentEncoded: false))
        #expect(store.items[0].urlString == expectedPath)
        #expect(store.items[1].title == "Stream Live")
    }

    @Test("RecentMediaStore enforces maxItemsLimit")
    @MainActor
    func testMaxItemsLimit() {
        let defaults = InMemoryUserDefaults()
        let store = RecentMediaStore(
            userDefaults: defaults, historyStore: PlaybackHistoryStore(userDefaults: defaults), maxItemsLimit: 3)

        let tempDir = FileManager.default.temporaryDirectory
        for i in 1...5 {
            let url = tempDir.appendingPathComponent("video\(i).mp4")
            store.record(url: url, title: "Video \(i)", duration: Double(i * 60))
        }

        #expect(store.items.count == 3)
        #expect(store.items[0].title == "Video 5")
        #expect(store.items[1].title == "Video 4")
        #expect(store.items[2].title == "Video 3")
    }

    @Test("RecentMediaStore removes item and clears all")
    @MainActor
    func testRemoveAndClearAll() {
        let defaults = InMemoryUserDefaults()
        let store = RecentMediaStore(userDefaults: defaults, historyStore: PlaybackHistoryStore(userDefaults: defaults))

        let tempDir = FileManager.default.temporaryDirectory
        let url1 = tempDir.appendingPathComponent("a.mkv")
        let url2 = tempDir.appendingPathComponent("b.mkv")

        store.record(url: url1, title: "A")
        store.record(url: url2, title: "B")
        #expect(store.items.count == 2)

        store.remove(id: store.items[0].historyKey)
        #expect(store.items.count == 1)
        #expect(store.items[0].title == "A")

        store.clearAll()
        #expect(store.items.isEmpty)
    }

    @Test("RecentMediaStore persists items across instances")
    @MainActor
    func testPersistence() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("persistent.mkv")
        do {
            let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)
            store.record(url: url, title: "Persistent Movie", duration: 7200.0)
        }

        let reloaded = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].title == "Persistent Movie")
        #expect(reloaded.items[0].duration == 7200.0)
    }

    @Test("RecentMediaStore returns resume info from PlaybackHistoryStore")
    @MainActor
    func testResumeInfoIntegration() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)

        let streamURL = URL(string: "https://example.com/video.mp4")!
        store.record(url: streamURL, title: "Online Stream", duration: 1000.0)

        let item = store.items[0]

        // No history yet
        #expect(store.resumeInfo(for: item) == nil)

        // Save position in historyStore
        historyStore.savePosition(
            for: MediaHistoryIdentity(historyKey: item.historyKey), position: 250.0, duration: 1000.0)
        let info = store.resumeInfo(for: item)
        #expect(info != nil)
        #expect(info?.position == 250.0)
        #expect(info?.duration == 1000.0)

        // If resumePlayback is disabled, resumeInfo is nil
        #expect(store.resumeInfo(for: item, resumePlayback: false) == nil)
    }

    @Test("RecentMediaStore records HTTP headers and updates duration")
    @MainActor
    func testHeadersAndDurationUpdate() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)

        let streamURL = URL(string: "https://example.com/auth-stream.m3u8")!
        let headers = [
            "Authorization": "Bearer token123",
            "Cookie": "session=xyz",
            "User-Agent": "CustomAgent/1.0",
            "Referer": "https://example.com",
        ]
        store.record(url: streamURL, title: "Auth Stream", duration: 0.0, headers: headers)

        #expect(store.items.count == 1)
        // Sensitive credentials (Authorization, Cookie) must be stripped for security
        let expectedPersistedHeaders = [
            "User-Agent": "CustomAgent/1.0",
            "Referer": "https://example.com",
        ]
        #expect(store.items[0].headers == expectedPersistedHeaders)
        #expect(store.items[0].duration == 0.0)

        // Updating duration
        store.updateDuration(1800.0, forHistoryKey: store.items[0].historyKey)
        #expect(store.items[0].duration == 1800.0)

        // Resume info with duration == 0 returns duration 0 (not position)
        let zeroDurationURL = URL(string: "https://example.com/live.m3u8")!
        store.record(url: zeroDurationURL, title: "Live", duration: 0.0)
        let zeroItem = store.items[0]
        let zeroIdentity = MediaHistoryIdentity(historyKey: zeroItem.historyKey)
        historyStore.savePosition(for: zeroIdentity, position: 100.0, duration: 0.0)
        // With duration == 0, savePosition ignores position <= 0 or duration <= 0 per PlaybackHistoryStore invariants.
        // Even if an existing position is present:
        historyStore.savePosition(for: zeroIdentity, position: 100.0, duration: 1000.0)
        let info = store.resumeInfo(for: zeroItem, resumePlayback: true, startThreshold: 15.0)
        #expect(info?.position == 100.0)
        #expect(info?.duration == 0.0)
    }

    @Test("RecentMediaStore automatically increments progressRevision on PlaybackHistoryStore change")
    @MainActor
    func testHistoryStoreNotificationUpdatesProgressRevision() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)

        let initialRev = store.progressRevision
        historyStore.savePosition(
            for: MediaHistoryIdentity(historyKey: "test-key"), position: 50.0, duration: 200.0)

        // Observer dispatches on main queue
        #expect(store.progressRevision > initialRev)

        let revAfterSave = store.progressRevision
        historyStore.clearAll()
        #expect(store.progressRevision > revAfterSave)
    }

    @Test("PlayerConfiguration persists rememberRecentMedia")
    func testPlayerConfigurationRecentMedia() {
        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(config.rememberRecentMedia == true)

        config.rememberRecentMedia = false
        config.saveToUserDefaults(userDefaults: defaults)

        let reloaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(reloaded.rememberRecentMedia == false)
    }

    @Test(
        "RecentMediaStore correctly looks up resume position saved via raw path or resolver history key (no double hashing)"
    )
    @MainActor
    func testResumeInfoMatchesRawPathAndResolverKey() throws {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)

        // 1. Local file scenario: simulate player recording raw normalized path
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let localPath = MediaURL.normalizeMediaPath(tempFile.path)
        // Progress saved during playback via engine.saveCurrentPlaybackProgress() uses raw key:
        historyStore.savePosition(for: MediaHistoryIdentity(historyKey: localPath), position: 120.0, duration: 600.0)

        // PlayerWindowController records item with historyKey: localPath
        store.record(
            url: tempFile,
            title: "Local Movie",
            historyKey: localPath,
            duration: 600.0
        )

        let localItem = store.items[0]
        #expect(localItem.historyKey == localPath)
        let localResume = store.resumeInfo(for: localItem, resumePlayback: true, startThreshold: 15.0)
        #expect(localResume != nil)
        #expect(localResume?.position == 120.0)
        #expect(localResume?.duration == 600.0)

        // 2. Duration update using raw key
        store.updateDuration(650.0, forHistoryKey: localPath)
        #expect(store.items[0].duration == 650.0)

        // 3. Media resolver scenario (e.g. YouTube resolved stream):
        // historyKey comes from ResolvedMedia.historyKey, distinct from URL
        let webURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let resolverKey = "youtube:dQw4w9WgXcQ"
        historyStore.savePosition(
            for: MediaHistoryIdentity(historyKey: resolverKey), position: 88.0, duration: 212.0)

        store.record(
            url: webURL,
            title: "Never Gonna Give You Up",
            historyKey: resolverKey,
            duration: 212.0
        )

        let resolverItem = store.items[0]
        #expect(resolverItem.historyKey == resolverKey)
        let resolverResume = store.resumeInfo(for: resolverItem, resumePlayback: true, startThreshold: 15.0)
        #expect(resolverResume != nil)
        #expect(resolverResume?.position == 88.0)
        #expect(resolverResume?.duration == 212.0)

        // 4. Playlist scenario: historyKey is raw playlist path, duration is 0
        let playlistURL = FileManager.default.temporaryDirectory.appendingPathComponent("playlist.m3u")
        let playlistPath = MediaURL.normalizeMediaPath(playlistURL.path(percentEncoded: false))
        store.record(
            url: playlistURL,
            title: "My Playlist",
            historyKey: playlistPath,
            duration: 0.0
        )
        let playlistItem = store.items[0]
        #expect(playlistItem.historyKey == playlistPath)
        #expect(playlistItem.duration == 0.0)
    }

    @Test("RecentMediaStore respects exclusion policy for paths and domains")
    @MainActor
    func testExclusionPolicy() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)

        let tempDir = FileManager.default.temporaryDirectory
        let excludedDir = tempDir.appendingPathComponent("SecretFolder")
        let excludedFile = excludedDir.appendingPathComponent("video.mp4")
        let allowedFile = tempDir.appendingPathComponent("allowed.mp4")

        let policy = HistoryExclusionPolicy(
            excludedPaths: [excludedDir.path],
            excludedDomains: ["private.stream", "bad.com"]
        )

        // Record with explicit exclusion policy
        store.record(url: excludedFile, title: "Secret", exclusionPolicy: policy)
        #expect(store.items.isEmpty)

        store.record(url: URL(string: "https://private.stream/live.m3u8")!, title: "Stream", exclusionPolicy: policy)
        #expect(store.items.isEmpty)

        // Test CDN sourcePath exclusion: allowed page URL, but resolved stream sourcePath domain is excluded
        let allowedPageURL = URL(string: "https://allowed-portal.com/watch?v=123")!
        let excludedCDNStream = "https://private.stream/cdn/hls/live.m3u8"
        #expect(
            store.record(
                url: allowedPageURL,
                title: "Portal Video",
                sourcePath: excludedCDNStream,
                exclusionPolicy: policy
            ) == false
        )
        #expect(store.items.isEmpty)

        store.record(url: allowedFile, title: "Allowed", exclusionPolicy: policy)
        #expect(store.items.count == 1)
        #expect(store.items[0].title == "Allowed")
    }

    @Test("RecentMediaStore purge removes items and saved positions matching policy")
    @MainActor
    func testPurgeExclusions() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)

        let tempDir = FileManager.default.temporaryDirectory
        let folderA = tempDir.appendingPathComponent("FolderA")
        let fileA = folderA.appendingPathComponent("clipA.mp4")
        let fileB = tempDir.appendingPathComponent("clipB.mp4")
        let domainURL = URL(string: "https://untracked.org/stream.m3u8")!

        store.record(url: fileA, title: "Clip A", duration: 100)
        store.record(url: fileB, title: "Clip B", duration: 200)
        let resolverKey = "custom-resolver-stream:abc123xyz"
        store.record(url: domainURL, title: "Stream", historyKey: resolverKey, duration: 300)

        let identityA = MediaHistoryIdentity(historyKey: fileA.path)
        let identityB = MediaHistoryIdentity(historyKey: fileB.path)
        let resolverIdentity = MediaHistoryIdentity(historyKey: resolverKey)
        historyStore.savePosition(for: identityA, position: 50, duration: 100)
        historyStore.savePosition(for: identityB, position: 75, duration: 200)
        historyStore.savePosition(for: resolverIdentity, position: 150, duration: 300)

        #expect(store.items.count == 3)
        #expect(historyStore.hasSavedPositions == true)

        let policy = HistoryExclusionPolicy(
            excludedPaths: [folderA.path],
            excludedDomains: ["untracked.org"]
        )

        store.purge(matching: policy)

        #expect(store.items.count == 1)
        #expect(store.items[0].title == "Clip B")

        // FolderA position and resolverKey position should be cleared, fileB position kept
        #expect(historyStore.savedPosition(for: identityA) == nil)
        #expect(historyStore.savedPosition(for: resolverIdentity) == nil)
        #expect(historyStore.savedPosition(for: identityB) == 75)
    }

    @Test("Purge cleans up resolver keys not present in Recents using mediaPath")
    func testPurgeResolverKeyWithoutRecents() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)

        let resolverKey = "youtube:testVideo123"
        let webURL = "https://www.youtube.com/watch?v=testVideo123"
        let resolverIdentity = MediaHistoryIdentity(historyKey: resolverKey, path: webURL)

        // Save position with path (as PlayerEngine does)
        historyStore.savePosition(
            for: resolverIdentity,
            position: 120,
            duration: 500
        )

        #expect(historyStore.savedPosition(for: resolverIdentity) == 120)

        // Policy excludes youtube.com
        let policy = HistoryExclusionPolicy(excludedDomains: ["youtube.com"])

        // Purge directly on historyStore with empty knownKeysAndPaths (simulating eviction from Recents)
        historyStore.purge(matching: policy)

        #expect(historyStore.savedPosition(for: resolverIdentity) == nil)
    }

    @Test("RecentMediaStore.record returns false when excluded and true when recorded")
    @MainActor
    func testRecordReturnValues() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        let store = RecentMediaStore(userDefaults: defaults, historyStore: historyStore)

        let policy = HistoryExclusionPolicy(
            excludedPaths: ["/Private/Folder"],
            excludedDomains: ["excluded.com"]
        )

        let fileURL = URL(fileURLWithPath: "/Private/Folder/video.mp4")
        let allowedURL = URL(fileURLWithPath: "/Public/video.mp4")

        #expect(store.record(url: fileURL, title: "Secret", exclusionPolicy: policy) == false)
        #expect(store.record(url: allowedURL, title: "Allowed", exclusionPolicy: policy) == true)
    }

    @Test("RecentMediaStore skips corrupted JSON elements while preserving valid ones")
    @MainActor
    func testLossyDecodingPreservesValidItems() {
        let defaults = InMemoryUserDefaults()
        let json = """
            [
                {"urlString": "/movies/valid1.mkv", "historyKey": "/movies/valid1.mkv", "title": "Valid 1", "duration": 120},
                {"corrupted": true},
                {"urlString": "/movies/valid2.mkv", "historyKey": "/movies/valid2.mkv", "title": "Valid 2", "duration": 240}
            ]
            """.data(using: .utf8)!
        defaults.set(json, forKey: RecentMediaStore.userDefaultsKey)

        let store = RecentMediaStore(userDefaults: defaults, historyStore: PlaybackHistoryStore(userDefaults: defaults))
        #expect(store.items.count == 2)
        #expect(store.items[0].title == "Valid 1")
        #expect(store.items[1].title == "Valid 2")
    }

    @Test("RecentMediaStore invokes onRecentDocumentsChanged on record, remove, purge and clearAll")
    @MainActor
    func testRecentDocumentsSyncHandler() {
        let defaults = InMemoryUserDefaults()
        let historyStore = PlaybackHistoryStore(userDefaults: defaults)
        var receivedURLs: [[URL]] = []

        let store = RecentMediaStore(
            userDefaults: defaults,
            historyStore: historyStore,
            onRecentDocumentsChanged: { urls in
                receivedURLs.append(urls)
            }
        )

        let file1 = URL(fileURLWithPath: "/tmp/movie1.mp4")
        let file2 = URL(fileURLWithPath: "/tmp/movie2.mp4")
        let streamURL = URL(string: "https://example.com/stream.m3u8")!

        store.record(url: file1, title: "Movie 1")
        #expect(receivedURLs.count == 1)
        #expect(receivedURLs.last == [file1])

        store.record(url: file2, title: "Movie 2")
        #expect(receivedURLs.count == 2)
        #expect(receivedURLs.last == [file2, file1])

        // Network stream is recorded in items, but not passed to local file recents sync
        store.record(url: streamURL, title: "Stream")
        #expect(receivedURLs.count == 3)
        #expect(receivedURLs.last == [file2, file1])

        store.remove(id: file1.path)
        #expect(receivedURLs.count == 4)
        #expect(receivedURLs.last == [file2])

        store.clearAll()
        #expect(receivedURLs.count == 5)
        #expect(receivedURLs.last == [])
    }
}
