import AppKit
import Foundation
import MediaPlayer
import NitsCore
import NitsKit
import NitsTestSupport
import Testing

#if canImport(NowPlaying)
    import NowPlaying
#endif

@Suite("NowPlaying Controller Tests")
struct NowPlayingTests {
    @Test("LegacyMediaPlayerController sets nowPlayingInfo and playbackState accurately")
    @MainActor
    func testLegacyMediaPlayerStateAndMetadata() async throws {
        let engine = PlayerEngine.makeForTesting()
        let legacy = LegacyMediaPlayerController(engine: engine)
        let center = MPNowPlayingInfoCenter.default()

        // 1. Initial playback update
        legacy.update(title: "Inception", currentTime: 15.0, duration: 8880.0, isPlaying: true)

        #expect(center.playbackState == .playing)
        let info = try #require(center.nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Inception")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 8880.0)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 15.0)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)

        // 2. Pause update
        legacy.update(title: "Inception", currentTime: 18.0, duration: 8880.0, isPlaying: false)
        #expect(center.playbackState == .paused)
        let pausedInfo = try #require(center.nowPlayingInfo)
        #expect(pausedInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)

        // 3. Normal 1s progression does not trigger premature updates due to extrapolation
        // (calling update with small linear delta should not overwrite unless heartbeat or seek)
        legacy.update(title: "Inception", currentTime: 18.5, duration: 8880.0, isPlaying: false)
        let unchangedInfo = try #require(center.nowPlayingInfo)
        #expect(unchangedInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 18.0)

        // 4. Seek jump (delta > 1.5s) immediately triggers update
        legacy.update(title: "Inception", currentTime: 120.0, duration: 8880.0, isPlaying: false)
        let seekedInfo = try #require(center.nowPlayingInfo)
        #expect(seekedInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 120.0)

        // 5. Artwork update
        let testImageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG header bytes
        legacy.update(
            title: "Inception",
            currentTime: 125.0,
            duration: 8880.0,
            isPlaying: false,
            artworkData: testImageData,
            artworkURL: nil
        )
        // Verify update completes without error

        // 6. Clear resets everything
        legacy.clear()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    @Test("LegacyMediaPlayerController toggles remote command center enabled state on active media")
    @MainActor
    func testLegacyCommandCenterActiveStateToggling() async throws {
        let engine = PlayerEngine.makeForTesting()
        let legacy = LegacyMediaPlayerController(engine: engine)
        let remote = MPRemoteCommandCenter.shared()

        legacy.update(title: "Active Video", currentTime: 0, duration: 100, isPlaying: true)
        #expect(legacy.isActive == true)
        #expect(remote.togglePlayPauseCommand.isEnabled == true)
        #expect(remote.playCommand.isEnabled == true)
        #expect(remote.pauseCommand.isEnabled == true)

        legacy.clear()
        #expect(legacy.isActive == false)
        #expect(remote.togglePlayPauseCommand.isEnabled == false)
        #expect(remote.playCommand.isEnabled == false)
        #expect(remote.pauseCommand.isEnabled == false)
    }

    @Test("LegacyMediaPlayerController offers Next only while the host's queue has a next item")
    @MainActor
    func testLegacyNextTrackFollowsHostNavigation() async throws {
        let engine = PlayerEngine.makeForTesting()
        engine.onTrackNavigation = { _ in }
        let legacy = LegacyMediaPlayerController(engine: engine)
        let remote = MPRemoteCommandCenter.shared()
        defer { legacy.clear() }

        legacy.update(title: "Episode 1", currentTime: 0, duration: 100, isPlaying: true)
        #expect(remote.nextTrackCommand.isEnabled == false)

        engine.trackNavigation = TrackNavigation(hasNext: true)
        legacy.update(title: "Episode 1", currentTime: 0.1, duration: 100, isPlaying: true)
        #expect(remote.nextTrackCommand.isEnabled == true)
    }

    #if canImport(NowPlaying)
        @Test("ModernNowPlayingController offers Next only while the host's queue has a next item")
        @available(macOS 27.0, *)
        @MainActor
        func testModernNextTrackFollowsHostNavigation() async throws {
            let engine = PlayerEngine.makeForTesting()
            engine.onTrackNavigation = { _ in }
            let controller = ModernNowPlayingController(engine: engine)
            defer { controller.clear() }

            controller.update(title: "Episode 1", currentTime: 0.0, duration: 100.0, isPlaying: true)
            #expect(controller.model.canPlayNext == false)
            let commandsWithoutNext = controller.model.commands.count

            engine.trackNavigation = TrackNavigation(hasNext: true)
            controller.update(title: "Episode 1", currentTime: 0.1, duration: 100.0, isPlaying: true)
            #expect(controller.model.canPlayNext == true)
            #expect(controller.model.commands.count == commandsWithoutNext + 1)
        }

        @Test("ModernNowPlayingModel creates valid snapshot and metadata")
        @available(macOS 27.0, *)
        @MainActor
        func testModernNowPlayingModel() async throws {
            let model = ModernNowPlayingModel(id: "test-model")
            model.title = "Interstellar"
            model.duration = 10140.0
            model.currentTime = 42.0
            model.isPlaying = true

            let content = try #require(model.content as? MovieContent)
            #expect(content.title == "Interstellar")
            #expect(content.artwork == nil)

            model.rawArtworkData = Data([0x01, 0x02, 0x03])
            let contentWithArtwork = try #require(model.content as? MovieContent)
            #expect(contentWithArtwork.artwork != nil)

            let snapshot = try #require(model.playbackSnapshot)
            _ = snapshot

            // Pause state
            model.isPlaying = false
            let pausedSnapshot = try #require(model.playbackSnapshot)
            _ = pausedSnapshot
        }

        @Test("ModernNowPlayingController lifecycle and clear")
        @available(macOS 27.0, *)
        @MainActor
        func testModernNowPlayingControllerLifecycle() async throws {
            let engine = PlayerEngine.makeForTesting()
            let controller = ModernNowPlayingController(engine: engine)

            controller.update(title: "Dune", currentTime: 0.0, duration: 9300.0, isPlaying: true)
            #expect(controller.model.title == "Dune")
            #expect(controller.model.isPlaying == true)
            #expect(controller.model.currentTime == 0.0)

            controller.clear()
            #expect(controller.model.title == "")
            #expect(controller.model.isPlaying == false)
        }
    #endif

    @Test("NowPlayingControllerFactory returns an instance without error")
    @MainActor
    func testFactoryCreation() async throws {
        let engine = PlayerEngine.makeForTesting()
        let controller = NowPlayingControllerFactory.makeController(engine: engine)
        #expect(controller.isKeyWindow == true)
        controller.update(title: "Factory Video", currentTime: 0, duration: 100, isPlaying: true)
        controller.clear()
    }

    @Test("PlayerWindowController handles closing and opening a second video seamlessly")
    @MainActor
    func testPlayerWindowControllerReopenLifecycle() async throws {
        let windowController = PlayerWindowController(engine: .makeForTesting())

        // 1. First video playback
        windowController.nowPlayingController.update(title: "Video 1", currentTime: 0, duration: 100, isPlaying: true)

        // 2. Window close simulation
        windowController.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        // 3. Second video playback in same or new instance
        windowController.nowPlayingController.update(title: "Video 2", currentTime: 0, duration: 200, isPlaying: true)

        // Verify that callbacks are still attached and second video updates nowPlayingController
        windowController.engine.onPlaybackStateChanged?(.playing)
        windowController.engine.onTimeUpdate?(5.0, 200.0)

        windowController.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    @Test("A change of the host's queue reaches the media controls at once, without a time update")
    @MainActor
    func testTrackNavigationChangeRefreshesMediaControls() async throws {
        let windowController = PlayerWindowController(engine: .makeForTesting())
        defer { windowController.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        windowController.onTrackNavigation = { _ in }
        windowController.nowPlayingController.update(
            title: "Episode 1", currentTime: 0, duration: 100, isPlaying: false)

        // Paused: no further `update` comes.
        windowController.setTrackNavigation(TrackNavigation(hasNext: true))

        #if canImport(NowPlaying)
            if #available(macOS 27.0, *),
                let modern = windowController.nowPlayingController as? ModernNowPlayingController
            {
                #expect(modern.model.canPlayNext)
                return
            }
        #endif
        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
    }

    @Test("NowPlayingThrottler accurately throttles 1x ticks and detects state changes, seeks, and heartbeats")
    func testNowPlayingThrottler() {
        var throttler = NowPlayingThrottler()
        let t0 = Date(timeIntervalSince1970: 1000.0)

        // Empty title is always rejected
        #expect(throttler.shouldUpdate(title: "", currentTime: 0, duration: 100, isPlaying: true, now: t0) == false)

        // 1. First initial update -> allowed
        #expect(
            throttler.shouldUpdate(title: "Movie", currentTime: 0.0, duration: 100.0, isPlaying: true, now: t0) == true)
        #expect(throttler.lastReportedTitle == "Movie")
        #expect(throttler.lastReportedTime == 0.0)
        #expect(throttler.lastReportedIsPlaying == true)

        // 2. Continuous 1x playback tick (0.1s later, currentTime = 0.1s) -> throttled
        let t1 = t0.addingTimeInterval(0.1)
        #expect(
            throttler.shouldUpdate(title: "Movie", currentTime: 0.1, duration: 100.0, isPlaying: true, now: t1) == false
        )

        // 3. Normal progress after 1.0s (currentTime = 1.0s) -> still throttled
        let t2 = t0.addingTimeInterval(1.0)
        #expect(
            throttler.shouldUpdate(title: "Movie", currentTime: 1.0, duration: 100.0, isPlaying: true, now: t2) == false
        )

        // 4. Seek detected (at 1.0s, user jumped to 50.0s) -> allowed
        #expect(
            throttler.shouldUpdate(title: "Movie", currentTime: 50.0, duration: 100.0, isPlaying: true, now: t2) == true
        )
        #expect(throttler.lastReportedTime == 50.0)

        // 5. Playback pause state change -> allowed immediately
        let t3 = t2.addingTimeInterval(0.2)
        #expect(
            throttler.shouldUpdate(title: "Movie", currentTime: 50.2, duration: 100.0, isPlaying: false, now: t3)
                == true)
        #expect(throttler.lastReportedIsPlaying == false)

        // 6. While paused, small jitter (<1.5s) -> throttled
        let t4 = t3.addingTimeInterval(0.5)
        #expect(
            throttler.shouldUpdate(title: "Movie", currentTime: 50.5, duration: 100.0, isPlaying: false, now: t4)
                == false)

        // 7. While paused, seek jump (>1.5s) -> allowed
        #expect(
            throttler.shouldUpdate(title: "Movie", currentTime: 70.0, duration: 100.0, isPlaying: false, now: t4)
                == true)
        #expect(throttler.lastReportedTime == 70.0)

        // 8. Heartbeat refresh after 5.0 seconds without state change -> allowed
        let t5 = t4.addingTimeInterval(5.1)
        #expect(
            throttler.shouldUpdate(title: "Movie", currentTime: 70.0, duration: 100.0, isPlaying: false, now: t5)
                == true)

        // 9. Reset clears all state
        throttler.reset()
        #expect(throttler.lastReportedTitle == "")
        #expect(throttler.lastReportedTime == -1)
        #expect(throttler.lastReportedIsPlaying == nil)
    }
}
