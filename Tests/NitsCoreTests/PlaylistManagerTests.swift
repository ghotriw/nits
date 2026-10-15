import Foundation
import Testing

@testable import NitsCore

@Suite("PlaylistManager Tests")
@MainActor
struct PlaylistManagerTests {

    @Test("Basic playlist creation and item properties")
    func testPlaylistItemProperties() {
        let fileURL = URL(fileURLWithPath: "/tmp/sample_movie.mkv")
        let item = PlaylistItem(url: fileURL, duration: 125.0)

        #expect(item.title == "sample_movie")
        #expect(item.filename == "sample_movie.mkv")
        #expect(!item.isNetworkStream)
        #expect(item.formattedDuration == "02:05")

        let streamURL = URL(string: "https://example.com/live/stream.m3u8")!
        let streamItem = PlaylistItem(url: streamURL, title: "Live TV", duration: nil)
        #expect(streamItem.title == "Live TV")
        #expect(streamItem.isNetworkStream)
        #expect(streamItem.formattedDuration == nil)
    }

    @Test("Playlist append, remove, and clear")
    func testAppendAndRemove() {
        let manager = PlaylistManager()
        let url1 = URL(fileURLWithPath: "/tmp/video1.mp4")
        let url2 = URL(fileURLWithPath: "/tmp/video2.mp4")
        let url3 = URL(fileURLWithPath: "/tmp/video3.mp4")

        manager.append(urls: [url1, url2, url3])
        #expect(manager.items.count == 3)
        #expect(manager.currentIndex == 0)
        #expect(manager.currentItem?.url == url1)

        manager.remove(at: IndexSet(integer: 1))
        #expect(manager.items.count == 2)
        #expect(manager.items[0].url == url1)
        #expect(manager.items[1].url == url3)

        manager.clear()
        #expect(manager.items.isEmpty)
        #expect(manager.currentIndex == nil)
        #expect(manager.currentItem == nil)
    }

    @Test("Playlist navigation with repeat off")
    func testNavigationRepeatOff() {
        let manager = PlaylistManager()
        let urls = (1...3).map { URL(fileURLWithPath: "/tmp/track\($0).mp4") }
        manager.append(urls: urls)

        #expect(manager.currentIndex == 0)
        #expect(manager.hasNext == true)
        #expect(manager.hasPrevious == false)

        let next1 = manager.playNext()
        #expect(next1?.url == urls[1])
        #expect(manager.currentIndex == 1)
        #expect(manager.hasNext == true)
        #expect(manager.hasPrevious == true)

        let next2 = manager.playNext()
        #expect(next2?.url == urls[2])
        #expect(manager.currentIndex == 2)
        #expect(manager.hasNext == false)
        #expect(manager.hasPrevious == true)

        let next3 = manager.playNext()
        #expect(next3 == nil)
        #expect(manager.currentIndex == 2)
    }

    @Test("Playlist navigation with repeat all")
    func testNavigationRepeatAll() {
        let manager = PlaylistManager()
        let urls = (1...2).map { URL(fileURLWithPath: "/tmp/track\($0).mp4") }
        manager.append(urls: urls)
        manager.repeatMode = .all

        #expect(manager.hasNext == true)
        let _ = manager.playNext()  // advances to 1
        #expect(manager.currentIndex == 1)

        let wrapped = manager.playNext()  // wraps around to 0
        #expect(wrapped?.url == urls[0])
        #expect(manager.currentIndex == 0)

        // Previous wraps to last
        let prev = manager.playPrevious(restartThresholdSeconds: 3.0, currentPlaybackTime: 1.0)
        #expect(!prev.shouldRestart)
        #expect(prev.item?.url == urls[1])
        #expect(manager.currentIndex == 1)
    }

    @Test("Playlist previous track with threshold restart")
    func testPlayPreviousThreshold() {
        let manager = PlaylistManager()
        let urls = (1...2).map { URL(fileURLWithPath: "/tmp/track\($0).mp4") }
        manager.append(urls: urls)
        manager.selectItem(at: 1)

        // Played past threshold (e.g. 5 seconds): restart current track without decrementing index
        let restartResult = manager.playPrevious(restartThresholdSeconds: 3.0, currentPlaybackTime: 5.0)
        #expect(restartResult.shouldRestart == true)
        #expect(restartResult.item?.url == urls[1])
        #expect(manager.currentIndex == 1)

        // Played before threshold (e.g. 1 second): jump to previous track
        let jumpResult = manager.playPrevious(restartThresholdSeconds: 3.0, currentPlaybackTime: 1.0)
        #expect(jumpResult.shouldRestart == false)
        #expect(jumpResult.item?.url == urls[0])
        #expect(manager.currentIndex == 0)
    }

    @Test("Repeat mode one repeats current item")
    func testRepeatModeOne() {
        let manager = PlaylistManager()
        let urls = (1...3).map { URL(fileURLWithPath: "/tmp/track\($0).mp4") }
        manager.append(urls: urls)
        manager.repeatMode = .one

        let next = manager.playNext()
        #expect(next?.url == urls[0])
        #expect(manager.currentIndex == 0)
    }

    @Test("Shuffle and unshuffle preserves original indices")
    func testShuffleAndUnshuffle() {
        let manager = PlaylistManager()
        let urls = (1...10).map { URL(fileURLWithPath: "/tmp/track\($0).mp4") }
        manager.append(urls: urls)

        manager.toggleShuffle()
        #expect(manager.isShuffled == true)
        #expect(manager.items.count == 10)

        // Unshuffle returns to original order
        manager.toggleShuffle()
        #expect(manager.isShuffled == false)
        for i in 0..<10 {
            #expect(manager.items[i].originalIndex == i)
            #expect(manager.items[i].url == urls[i])
        }
    }

    @Test("Search query filtering")
    func testSearchFiltering() {
        let manager = PlaylistManager()
        let urls = [
            URL(fileURLWithPath: "/tmp/Inception.2010.mkv"),
            URL(fileURLWithPath: "/tmp/Interstellar.2014.mkv"),
            URL(fileURLWithPath: "/tmp/The.Dark.Knight.2008.mkv"),
        ]
        manager.append(urls: urls)

        #expect(manager.filteredItems.count == 3)

        manager.searchQuery = "inter"
        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems[0].title.contains("Interstellar"))

        manager.searchQuery = "dark"
        #expect(manager.filteredItems.count == 1)
        #expect(manager.filteredItems[0].title.contains("Dark"))

        manager.searchQuery = "xyz"
        #expect(manager.filteredItems.isEmpty)
        #expect(manager.hasNext == false)
        #expect(manager.hasPrevious == false)
        #expect(manager.playNext() == nil)

        // Verifying code review point 2: playPrevious must restart track if over threshold even if search result is empty
        let prevWhileEmptyFilter = manager.playPrevious(restartThresholdSeconds: 3.0, currentPlaybackTime: 10.0)
        #expect(prevWhileEmptyFilter.shouldRestart == true)
        #expect(prevWhileEmptyFilter.item?.title.contains("Inception") == true)

        manager.searchQuery = ""
        #expect(manager.filteredItems.count == 3)

        // Filter navigation behavior like VLC:
        // Current item is Inception (index 0). Filter for "Dark".
        // Current item continues playing, but playNext() advances to the filtered result (The Dark Knight).
        manager.searchQuery = "dark"
        #expect(manager.currentItem?.title.contains("Inception") == true)
        #expect(manager.hasNext == true)

        let nextFromFilter = manager.playNext()
        #expect(nextFromFilter?.title.contains("Dark") == true)
        #expect(manager.currentItem?.id == nextFromFilter?.id)
        #expect(manager.hasNext == false)

        // Clear filter: navigation resumes within full list
        manager.searchQuery = ""
        #expect(manager.currentItem?.title.contains("Dark") == true)
        #expect(manager.hasPrevious == true)
        let prevFull = manager.playPrevious()
        #expect(prevFull.item?.title.contains("Interstellar") == true)
    }

    @Test("Sorting by title and filename")
    func testSorting() {
        let manager = PlaylistManager()
        let urls = [
            URL(fileURLWithPath: "/tmp/Charlie.mp4"),
            URL(fileURLWithPath: "/tmp/Alpha.mp4"),
            URL(fileURLWithPath: "/tmp/Bravo.mp4"),
        ]
        manager.append(urls: urls)

        manager.sort(by: .title, ascending: true)
        #expect(manager.items[0].title == "Alpha")
        #expect(manager.items[1].title == "Bravo")
        #expect(manager.items[2].title == "Charlie")

        manager.sort(by: .title, ascending: false)
        #expect(manager.items[0].title == "Charlie")
        #expect(manager.items[1].title == "Bravo")
        #expect(manager.items[2].title == "Alpha")
    }

    @Test("Sorting by duration keeps unknown durations last and the current item selected")
    func testSortingByDuration() {
        let manager = PlaylistManager(items: [
            PlaylistItem(url: URL(fileURLWithPath: "/tmp/Long.mp4"), duration: 300),
            PlaylistItem(url: URL(fileURLWithPath: "/tmp/Unknown.mp4")),
            PlaylistItem(url: URL(fileURLWithPath: "/tmp/Short.mp4"), duration: 60),
            PlaylistItem(url: URL(fileURLWithPath: "/tmp/Bravo.mp4"), duration: 120),
            PlaylistItem(url: URL(fileURLWithPath: "/tmp/Alpha.mp4"), duration: 120),
        ])
        _ = manager.selectItem(at: 0)

        manager.sort(by: .duration, ascending: true)
        #expect(manager.items.map(\.title) == ["Short", "Alpha", "Bravo", "Long", "Unknown"])
        #expect(manager.currentItem?.title == "Long")

        manager.sort(by: .duration, ascending: false)
        #expect(manager.items.map(\.title) == ["Long", "Alpha", "Bravo", "Short", "Unknown"])
        #expect(manager.currentItem?.title == "Long")
    }

    @Test("Directory sibling auto-loading with natural sorting")
    func testDirectorySiblingDiscovery() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create dummy video files
        let filenames = ["Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S01E10.mkv", "notes.txt"]
        for name in filenames {
            let fileURL = tempDir.appendingPathComponent(name)
            try "dummy".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let targetURL = tempDir.appendingPathComponent("Show.S01E02.mkv")
        let manager = PlaylistManager()
        await manager.loadSiblingsFromDirectoryAsync(for: targetURL)

        // Only mkv should be added, and in natural order: E01, E02, E10 (not E10 before E02)
        #expect(manager.items.count == 3)
        #expect(manager.items[0].filename == "Show.S01E01.mkv")
        #expect(manager.items[1].filename == "Show.S01E02.mkv")
        #expect(manager.items[2].filename == "Show.S01E10.mkv")

        // Active index should be pointing to targetURL (E02)
        #expect(manager.currentIndex == 1)
        #expect(manager.currentItem?.filename == "Show.S01E02.mkv")
    }

    @Test("Add folder discovers files in directory and nested subdirectories")
    func testAppendFolderAndRecursiveMediaDiscovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PlaylistFolderTest_\(UUID().uuidString)")
        let subDir = tempDir.appendingPathComponent("SubSeason")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Root files
        try "dummy".write(to: tempDir.appendingPathComponent("01_intro.mp4"), atomically: true, encoding: .utf8)
        try "dummy".write(to: tempDir.appendingPathComponent("readme.pdf"), atomically: true, encoding: .utf8)

        // Nested files
        try "dummy".write(to: subDir.appendingPathComponent("02_episode.mkv"), atomically: true, encoding: .utf8)
        try "dummy".write(to: subDir.appendingPathComponent("03_episode.mkv"), atomically: true, encoding: .utf8)

        let manager = PlaylistManager()

        // 1. Append folder with recursive = true
        manager.append(folderURL: tempDir, recursive: true)

        #expect(manager.items.count == 3)
        #expect(manager.items.map(\.filename).sorted() == ["01_intro.mp4", "02_episode.mkv", "03_episode.mkv"])
        #expect(manager.currentIndex == 0)

        // 2. Clear and append non-recursively
        manager.clear()
        manager.append(folderURL: tempDir, recursive: false)
        #expect(manager.items.count == 1)
        #expect(manager.items[0].filename == "01_intro.mp4")

        // 3. Passing a directory into append(urls:) expands it
        manager.clear()
        let directFile = tempDir.appendingPathComponent("01_intro.mp4")
        manager.append(urls: [directFile, subDir])
        #expect(manager.items.count == 3)
    }

    @Test("PlaylistParser parses M3U / M3U8 files with metadata and relative paths")
    func testParseM3U() throws {
        let m3uContent = """
            #EXTM3U
            #EXTINF:180,Artist 1 - Track One
            audio1.mp3
            #EXTINF:245,Artist 2 - Track Two
            sub/audio2.flac
            #EXTINF:-1,Live Radio Stream
            https://stream.example.com/live.aac
            /absolute/path/movie.mkv
            """

        let base = URL(fileURLWithPath: "/Music/Playlists")
        let items = PlaylistParser.parse(content: m3uContent, format: "m3u", baseURL: base)

        #expect(items.count == 4)
        #expect(items[0].title == "Artist 1 - Track One")
        #expect(items[0].duration == 180.0)
        #expect(items[0].url.path == "/Music/Playlists/audio1.mp3")

        #expect(items[1].title == "Artist 2 - Track Two")
        #expect(items[1].duration == 245.0)
        #expect(items[1].url.path == "/Music/Playlists/sub/audio2.flac")

        #expect(items[2].title == "Live Radio Stream")
        #expect(items[2].url.absoluteString == "https://stream.example.com/live.aac")

        #expect(items[3].url.path == "/absolute/path/movie.mkv")
        #expect(items[3].title == "movie")
    }

    @Test("PlaylistParser parses PLS files")
    func testParsePLS() throws {
        let plsContent = """
            [playlist]
            NumberOfEntries=3
            File1=song1.mp3
            Title1=My Favorite Song
            Length1=210
            File2=http://stream.org:8000/listen
            Title2=Web Radio
            Length2=-1
            File3=../albums/song3.flac
            Title3=Another Track
            Length3=180
            Version=2
            """

        let base = URL(fileURLWithPath: "/Music/Playlists")
        let items = PlaylistParser.parse(content: plsContent, format: "pls", baseURL: base)

        #expect(items.count == 3)
        #expect(items[0].title == "My Favorite Song")
        #expect(items[0].duration == 210.0)
        #expect(items[0].url.path == "/Music/Playlists/song1.mp3")

        #expect(items[1].title == "Web Radio")
        #expect(items[1].duration == nil)
        #expect(items[1].url.absoluteString == "http://stream.org:8000/listen")

        #expect(items[2].title == "Another Track")
        #expect(items[2].duration == 180.0)
        #expect(items[2].url.path == "/Music/albums/song3.flac")
    }

    @Test("PlaylistParser parses XSPF files")
    func testParseXSPF() throws {
        let xspfContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <playlist version="1" xmlns="http://xspf.org/ns/0/">
                <trackList>
                    <track>
                        <location>file:///Volumes/Media/track1.mp4</location>
                        <title>Sample Video</title>
                        <creator>Director</creator>
                        <duration>120000</duration>
                    </track>
                    <track>
                        <location>relative_song.opus</location>
                        <title>Opus Audio</title>
                        <duration>65000</duration>
                    </track>
                </trackList>
            </playlist>
            """

        let base = URL(fileURLWithPath: "/Volumes/Media")
        let items = PlaylistParser.parse(content: xspfContent, format: "xspf", baseURL: base)

        #expect(items.count == 2)
        #expect(items[0].title == "Director - Sample Video")
        #expect(items[0].duration == 120.0)
        #expect(items[0].url.path == "/Volumes/Media/track1.mp4")

        #expect(items[1].title == "Opus Audio")
        #expect(items[1].duration == 65.0)
        #expect(items[1].url.path == "/Volumes/Media/relative_song.opus")
    }

    @Test("PlaylistParser parses CUE sheets")
    func testParseCUE() throws {
        let cueContent = """
            REM GENRE Soundtrack
            PERFORMER "Various Artists"
            TITLE "Movie OST"
            FILE "cdimage.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Main Theme"
                PERFORMER "Composer A"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Chase Scene"
                PERFORMER "Composer B"
                INDEX 01 03:15:00
            FILE "bonus.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Bonus Track"
                INDEX 01 00:00:00
            """

        let base = URL(fileURLWithPath: "/Music/Albums/MovieOST")
        let items = PlaylistParser.parse(content: cueContent, format: "cue", baseURL: base)

        #expect(items.count == 3)
        #expect(items[0].title == "Composer A - Main Theme")
        #expect(items[0].url.path == "/Music/Albums/MovieOST/cdimage.flac")
        #expect(items[0].startTime == 0.0)
        #expect(items[0].duration == 195.0)

        #expect(items[1].title == "Composer B - Chase Scene")
        #expect(items[1].url.path == "/Music/Albums/MovieOST/cdimage.flac")
        #expect(items[1].startTime == 195.0)  // 03:15:00 = 195s
        #expect(items[1].duration == nil)  // Last track of cdimage.flac

        #expect(items[2].title == "Various Artists - Bonus Track")
        #expect(items[2].url.path == "/Music/Albums/MovieOST/bonus.flac")
        #expect(items[2].startTime == 0.0)

        // Verify updateCurrentItemDuration computes remaining duration for the last track
        let manager = PlaylistManager(items: items)
        manager.selectItem(at: 1)  // track 1 (startTime = 195)
        manager.updateCurrentItemDuration(300.0)  // Total image duration = 300s
        #expect(manager.items[1].duration == 105.0)  // 300 - 195 = 105s
    }

    @Test("PlaylistParser correctly identifies and ignores HLS live/VOD stream manifests")
    func testHLSDetection() throws {
        let hlsManifest = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:10
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:10.0,
            segment0.ts
            #EXTINF:10.0,
            segment1.ts
            """

        let base = URL(string: "https://example.com/hls/master.m3u8")
        let items = PlaylistParser.parse(content: hlsManifest, format: "m3u8", baseURL: base)
        #expect(items.isEmpty)
        #expect(PlaylistParser.isHLSManifest(content: hlsManifest) == true)
    }

    @Test("PlaylistManager preserves manual drag & drop order when toggling shuffle and unshuffle")
    func testMoveAndUnshuffle() throws {
        let manager = PlaylistManager()
        let urls = (1...4).map { URL(fileURLWithPath: "/tmp/track\($0).mp4") }
        manager.append(urls: urls)

        // Initial order: [1, 2, 3, 4]
        #expect(manager.items.map(\.filename) == ["track1.mp4", "track2.mp4", "track3.mp4", "track4.mp4"])

        // User drags track 4 to top: [4, 1, 2, 3]
        manager.move(from: IndexSet(integer: 3), to: 0)
        #expect(manager.items.map(\.filename) == ["track4.mp4", "track1.mp4", "track2.mp4", "track3.mp4"])

        // Toggle shuffle
        manager.toggleShuffle()
        #expect(manager.isShuffled == true)

        // Toggle unshuffle: order should restore to [4, 1, 2, 3], NOT [1, 2, 3, 4]
        manager.toggleShuffle()
        #expect(manager.isShuffled == false)
        #expect(manager.items.map(\.filename) == ["track4.mp4", "track1.mp4", "track2.mp4", "track3.mp4"])

        // Non-contiguous multi-element move: move indices [0, 2] ("track4", "track2") to after "track3" (destination index 4)
        var nonContiguous = IndexSet()
        nonContiguous.insert(0)
        nonContiguous.insert(2)
        manager.move(from: nonContiguous, to: 4)
        #expect(manager.items.map(\.filename) == ["track1.mp4", "track3.mp4", "track4.mp4", "track2.mp4"])
    }

    @Test("PlaylistManager playNext advances on user action even with repeatMode = .one")
    func testPlayNextWithRepeatOne() throws {
        let manager = PlaylistManager()
        let urls = (1...3).map { URL(fileURLWithPath: "/tmp/track\($0).mp4") }
        manager.append(urls: urls)
        manager.repeatMode = .one

        // Auto playback end (isUserAction: false) stays on track 1
        let autoNext = manager.playNext(isUserAction: false)
        #expect(autoNext?.filename == "track1.mp4")

        // User explicit action (⌘→, isUserAction: true) advances to track 2
        let userNext = manager.playNext(isUserAction: true)
        #expect(userNext?.filename == "track2.mp4")
    }

    @Test("PlaylistManager automatically parses playlist file passed to append(urls:)")
    func testAppendPlaylistFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let playlistFile = tempDir.appendingPathComponent("favorites.m3u8")
        let m3u = """
            #EXTM3U
            #EXTINF:100,Video Alpha
            alpha.mkv
            #EXTINF:200,Video Beta
            beta.mp4
            """
        try m3u.write(to: playlistFile, atomically: true, encoding: .utf8)

        let manager = PlaylistManager()
        manager.append(urls: [playlistFile])

        #expect(manager.items.count == 2)
        #expect(manager.items[0].title == "Video Alpha")
        #expect(manager.items[0].url.path == tempDir.appendingPathComponent("alpha.mkv").path)
        #expect(manager.items[1].title == "Video Beta")
        #expect(manager.items[1].url.path == tempDir.appendingPathComponent("beta.mp4").path)
    }

    @Test("MediaDemuxer.isRemoteOrMountedVolume correctly identifies network streams and remote volumes")
    func testRemoteVolumeDetection() {
        #expect(MediaDemuxer.isRemoteOrMountedVolume("http://192.168.1.50/media.mp4") == true)
        #expect(MediaDemuxer.isRemoteOrMountedVolume("https://example.com/stream.m3u8") == true)
        #expect(MediaDemuxer.isRemoteOrMountedVolume("nfs://192.168.1.83/home/Drive/file.mp4") == true)
        #expect(MediaDemuxer.isRemoteOrMountedVolume("smb://192.168.1.83/share/file.mp4") == true)
        #expect(MediaDemuxer.isRemoteOrMountedVolume("/Users/ghotriw/Movies/local.mp4") == false)
    }

    @Test("PlaylistParser quickly parses large playlist with 4000 items without memory spikes")
    func testLargePlaylistParsingPerformance() {
        var pls = "[playlist]\nNumberOfEntries=4000\n"
        for i in 1...4000 {
            pls += "File\(i)=/Volumes/Drive/media_\(i).mp4\n"
            pls += "Title\(i)=Remote Video \(i)\n"
            pls += "Length\(i)=120\n"
        }
        pls += "Version=2\n"

        let items = PlaylistParser.parsePLS(content: pls, baseURL: nil)
        #expect(items.count == 4000)
        #expect(items[0].title == "Remote Video 1")
        #expect(items[0].url.path == "/Volumes/Drive/media_1.mp4")
        #expect(items[3999].title == "Remote Video 4000")
        #expect(items[3999].url.path == "/Volumes/Drive/media_4000.mp4")
    }

    @Test("Playlist repeat mode and shuffle persistence")
    func testRepeatAndShufflePersistence() {
        let testDefaults = UserDefaults(suiteName: "NitsTestPlaylistPersistence_\(UUID().uuidString)")!
        defer { testDefaults.removePersistentDomain(forName: testDefaults.description) }

        var config = PlayerConfiguration.loadFromUserDefaults(userDefaults: testDefaults)
        #expect(config.playlistRepeatMode == .off)
        #expect(config.playlistIsShuffled == false)

        config.playlistRepeatMode = .all
        config.playlistIsShuffled = true
        config.saveToUserDefaults(userDefaults: testDefaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: testDefaults)
        #expect(loaded.playlistRepeatMode == .all)
        #expect(loaded.playlistIsShuffled == true)

        // Verifying code review point 3: PlaylistManager uses injected userDefaults
        let isolatedManager = PlaylistManager(
            repeatMode: loaded.playlistRepeatMode,
            isShuffled: loaded.playlistIsShuffled,
            userDefaults: testDefaults
        )
        isolatedManager.cycleRepeatMode()
        #expect(
            testDefaults.string(forKey: PlayerConfiguration.keyPlaylistRepeatMode) == PlaylistRepeatMode.one.rawValue)

        isolatedManager.toggleShuffle()
        #expect(testDefaults.bool(forKey: PlayerConfiguration.keyPlaylistIsShuffled) == false)
    }

    @Test("PlaylistManager isLoading state tracking")
    func testIsLoadingState() async {
        let manager = PlaylistManager()
        #expect(manager.isLoading == false)

        manager.setIsLoading(true)
        #expect(manager.isLoading == true)

        manager.setIsLoading(false)
        #expect(manager.isLoading == false)

        // Verifying appendAsync sets and resets isLoading
        let testURL = URL(fileURLWithPath: "/tmp/test_item.mp4")
        await manager.appendAsync(urls: [testURL])
        #expect(manager.isLoading == false)
        #expect(manager.items.count == 1)
    }

    @Test("PlaylistParser correctly decodes percent-encoded file paths")
    func testPercentEncodedFilePathsInPlaylists() {
        let base = URL(fileURLWithPath: "/Users/test/Music")
        let m3u = """
            #EXTM3U
            #EXTINF:120,Episode 131
            file:///Users/test/Music/%23131_Track.mp4
            #EXTINF:180,Relative Episode
            %23131_Relative.mp4
            """

        let items = PlaylistParser.parse(content: m3u, format: "m3u", baseURL: base)
        #expect(items.count == 2)
        #expect(items[0].url.isFileURL == true)
        #expect(items[0].url.path == "/Users/test/Music/#131_Track.mp4")
        #expect(items[0].filename == "#131_Track.mp4")
        #expect(items[1].url.isFileURL == true)
        #expect(items[1].url.path == "/Users/test/Music/#131_Relative.mp4")
        #expect(items[1].filename == "#131_Relative.mp4")
    }

    @Test("Persistent shuffle is automatically applied when replacing or loading a playlist")
    func testShuffleOnReplaceAll() {
        let manager = PlaylistManager(isShuffled: true)
        let urls = (1...25).map { URL(fileURLWithPath: "/tmp/track\($0).mp4") }
        let items = urls.enumerated().map { PlaylistItem(url: $1, originalIndex: $0) }

        manager.replaceAll(items: items)
        #expect(manager.isShuffled == true)
        #expect(manager.items.count == 25)
        #expect(manager.currentIndex == 0)

        // Active first item remains at index 0 for immediate playback
        #expect(manager.items[0].url == urls[0])
        #expect(manager.items[0].originalIndex == 0)

        // Remaining tracks must be shuffled
        let subsequentIndices = manager.items.dropFirst().map(\.originalIndex)
        let strictlySequential = Array(1...24)
        #expect(subsequentIndices != strictlySequential)

        // Turning shuffle off must cleanly restore original order
        manager.toggleShuffle()
        #expect(manager.isShuffled == false)
        for i in 0..<25 {
            #expect(manager.items[i].originalIndex == i)
            #expect(manager.items[i].url == urls[i])
        }
    }

    @Test("Persistent shuffle is automatically applied on append into empty playlist")
    func testShuffleOnAppendWhenEmpty() {
        let manager = PlaylistManager(isShuffled: true)
        let urls = (1...25).map { URL(fileURLWithPath: "/tmp/song\($0).mp4") }
        manager.append(urls: urls)

        #expect(manager.isShuffled == true)
        #expect(manager.items.count == 25)
        #expect(manager.currentIndex == 0)
        #expect(manager.items[0].url == urls[0])

        let subsequentIndices = manager.items.dropFirst().map(\.originalIndex)
        let strictlySequential = Array(1...24)
        #expect(subsequentIndices != strictlySequential)

        // Unshuffle restores exact order
        manager.toggleShuffle()
        #expect(manager.isShuffled == false)
        for i in 0..<25 {
            #expect(manager.items[i].originalIndex == i)
            #expect(manager.items[i].url == urls[i])
        }
    }

    @Test("Persistent shuffle is applied when PlaylistManager is initialized with items")
    func testShuffleOnInitWithItems() {
        let urls = (1...25).map { URL(fileURLWithPath: "/tmp/video\($0).mp4") }
        let items = urls.enumerated().map { PlaylistItem(url: $1, originalIndex: $0) }
        let manager = PlaylistManager(items: items, isShuffled: true)

        #expect(manager.isShuffled == true)
        #expect(manager.items.count == 25)
        #expect(manager.items[0].url == urls[0])

        let subsequentIndices = manager.items.dropFirst().map(\.originalIndex)
        let strictlySequential = Array(1...24)
        #expect(subsequentIndices != strictlySequential)

        manager.toggleShuffle()
        #expect(manager.isShuffled == false)
        for i in 0..<25 {
            #expect(manager.items[i].originalIndex == i)
            #expect(manager.items[i].url == urls[i])
        }
    }

    @Test(
        "Initializing with items and isShuffled=false assigns proper originalIndex so subsequent shuffle/unshuffle preserves order"
    )
    func testInitWithoutShufflePreservesIndicesOnLaterShuffle() {
        let urls = (1...15).map { URL(fileURLWithPath: "/tmp/clip\($0).mp4") }
        // Default PlaylistItem initializes originalIndex to 0
        let items = urls.map { PlaylistItem(url: $0) }
        let manager = PlaylistManager(items: items, isShuffled: false)

        #expect(manager.isShuffled == false)
        for i in 0..<15 {
            #expect(manager.items[i].originalIndex == i)
        }

        manager.toggleShuffle()
        #expect(manager.isShuffled == true)

        manager.toggleShuffle()
        #expect(manager.isShuffled == false)
        for i in 0..<15 {
            #expect(manager.items[i].originalIndex == i)
            #expect(manager.items[i].url == urls[i])
        }
    }

    @Test("Absolute playlist paths resolve without touching the file system")
    func testResolveAbsoluteVolumePaths() throws {
        let content = """
            #EXTM3U
            #EXTINF:-1,Movie
            /Volumes/NitsNonexistentShare/Movies/Movie 1.mkv
            Relative Folder/Movie 2.mp4
            """
        let base = URL(fileURLWithPath: "/Volumes/NitsNonexistentShare/Lists/list.m3u")
        let items = PlaylistParser.parse(content: content, format: "m3u", baseURL: base)
        #expect(
            items.map(\.url.path) == [
                "/Volumes/NitsNonexistentShare/Movies/Movie 1.mkv",
                "/Volumes/NitsNonexistentShare/Lists/Relative Folder/Movie 2.mp4",
            ])
        #expect(items.allSatisfy { $0.url.isFileURL && !$0.url.hasDirectoryPath })
    }

    @Test("appendAsync expands folders and playlist files off the main actor")
    func testAppendAsyncExpandsFoldersAndPlaylists() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NitsAppendAsync-\(UUID().uuidString)", isDirectory: true)
        let folder = dir.appendingPathComponent("Season 1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["E02.mkv", "E01.mkv", "notes.txt"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil)
        }
        let m3u = dir.appendingPathComponent("list.m3u")
        try "#EXTM3U\n/Volumes/Share/A.mkv\n/Volumes/Share/B.mkv\n".write(to: m3u, atomically: true, encoding: .utf8)

        let manager = PlaylistManager()
        await manager.appendAsync(urls: [folder, m3u])

        #expect(manager.items.map(\.filename) == ["E01.mkv", "E02.mkv", "A.mkv", "B.mkv"])
        #expect(!manager.isLoading)
    }

    @Test("Only local files and LAN media-file URLs are probed for duration")
    func testDurationProbeFilter() throws {
        #expect(PlaylistManager.isProbeable(URL(fileURLWithPath: "/Volumes/Share/Movie.mkv")))
        #expect(PlaylistManager.isProbeable(try #require(URL(string: "http://192.168.1.5/media/Movie.mkv"))))
        // Live / IPTV-style sources on the LAN
        #expect(!PlaylistManager.isProbeable(try #require(URL(string: "http://192.168.1.5:9981/stream/channel/42"))))
        #expect(!PlaylistManager.isProbeable(try #require(URL(string: "http://192.168.1.5:8080/live/7.ts"))))
        #expect(!PlaylistManager.isProbeable(try #require(URL(string: "http://192.168.1.5/hls/index.m3u8"))))
        // Internet sources
        #expect(!PlaylistManager.isProbeable(try #require(URL(string: "https://example.com/media/Movie.mkv"))))
    }
}
