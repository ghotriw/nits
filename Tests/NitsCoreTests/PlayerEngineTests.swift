import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

@Suite("PlayerEngine Tests", .serialized)
struct PlayerEngineTests {
    @Test("Engine initializes with expected defaults from configuration")
    @MainActor
    func testEngineInitializationDefaults() {
        let config = PlayerConfiguration(
            enableToneMapping: true,
            defaultRenderMode: .auto,
            targetNits: 250.0,
            sharpness: 0.7,
            initialVolume: 0.8,
            seekStepSeconds: 10.0,
            exactSeekOnSinglePress: false
        )
        let engine = PlayerEngine.makeForTesting(configuration: config)

        #expect(engine.isLoaded == false)
        #expect(engine.isPlaying == false)
        #expect(engine.currentTime == 0.0)
        #expect(engine.duration == 0.0)
        #expect(engine.volume == 0.8)
        #expect(engine.isMuted == false)
        #expect(engine.metalTargetNits == 250.0)
        #expect(engine.metalSharpness == 0.7)
        #expect(engine.isToneMappingPermitted == true)
        #expect(engine.renderMode == .auto)
        #expect(engine.displayLayer.videoGravity == .resizeAspect)
        #expect(engine.seekStepSeconds == 10.0)
        #expect(engine.exactSeekOnSinglePress == false)
    }

    @Test("Active render mode dynamically computes based on display HDR and permission")
    @MainActor
    func testRenderModeResolution() {
        let engine = PlayerEngine.makeForTesting()

        // Default: isHDRDisplay = true, auto -> .system
        engine.isHDRDisplay = true
        engine.isHDRContent = true
        engine.renderMode = .auto
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)

        // On SDR display with HDR content, auto -> .metalToneMap
        engine.isHDRDisplay = false
        #expect(engine.activeRenderMode == .metalToneMap)
        #expect(engine.isMetalLayerVisible == true)

        // On SDR display with SDR content, auto -> .system
        engine.isHDRContent = false
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)
        engine.isHDRContent = true

        // Explicit system mode
        engine.renderMode = .system
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)

        // Explicit metalToneMap mode
        engine.renderMode = .metalToneMap
        #expect(engine.activeRenderMode == .metalToneMap)
        #expect(engine.isMetalLayerVisible == true)

        // Tone mapping disabled forces .system
        engine.isToneMappingPermitted = false
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)
    }

    @Test("Volume and mute updates properly reflect on engine state")
    @MainActor
    func testVolumeAndMute() {
        let engine = PlayerEngine.makeForTesting()

        engine.volume = 0.65
        #expect(engine.volume == 0.65)
        #expect(engine.isMuted == false)

        engine.isMuted = true
        #expect(engine.isMuted == true)

        engine.isMuted = false
        #expect(engine.isMuted == false)
    }

    @Test("Playback toggle and seek commands update internal state")
    @MainActor
    func testPlaybackControls() {
        let engine = PlayerEngine.makeForTesting()

        // Toggle when unloaded does not play
        engine.togglePlayPause()
        #expect(engine.isPlaying == false)

        // Relative seek bounds
        engine.seek(to: 5.0)
        #expect(engine.currentTime == 0.0)  // duration is 0, clamped to [0, 0]

        engine.stepFrameForward()
        #expect(engine.currentTime == 0.0)

        engine.stepFrameBackward()
        #expect(engine.currentTime == 0.0)
    }

    @Test("Engine loads reference media file if present")
    @MainActor
    func testLoadReferenceMedia() throws {
        guard let referencePath = SyntheticTestMediaFactory.ensureMedia(preset: .uhdHDRSubtitles) else { return }
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return
        }

        let engine = PlayerEngine.makeForTesting()
        engine.load(path: referencePath)

        #expect(engine.isLoaded == true)
        #expect(engine.duration > 0.0)
        #expect(engine.videoWidth > 0)
        #expect(engine.videoHeight > 0)
        #expect(engine.mediaTitle == URL(fileURLWithPath: referencePath).lastPathComponent)
        #expect(!engine.audioTracks.isEmpty)

        // Subtitles verification: synthetic uhdHDRSubtitles media contains 5 subrip tracks
        try #require(engine.subtitleTracks.count == 5)
        #expect(engine.selectedSubtitleTrackId == nil)

        // Select first track and verify track selection
        let firstSub = engine.subtitleTracks[0]
        #expect(firstSub.isForced == true)
        engine.selectSubtitleTrack(id: firstSub.id)
        #expect(engine.selectedSubtitleTrackId == firstSub.id)

        // Turn subtitles off
        engine.selectSubtitleTrack(id: nil)
        #expect(engine.selectedSubtitleTrackId == nil)
        #expect(engine.currentSubtitleText == nil)

        // Play and pause
        engine.play()
        #expect(engine.isPlaying == true)

        engine.pause()
        #expect(engine.isPlaying == false)

        // Seek
        engine.seek(to: 2.0)
        #expect(engine.currentTime == 2.0)

        engine.seekRelative(by: 1.0)
        #expect(engine.currentTime == 3.0)
        engine.stop()
    }

    @Test("Engine handles unavailable network URL gracefully with loadError and not loading")
    @MainActor
    func testLoadAsyncNetworkError() async {
        let engine = PlayerEngine.makeForTesting()
        // Invalid port / non-existent local server that will fail or reject instantly
        await engine.loadAsync(path: "http://127.0.0.1:65534/nonexistent.mkv")

        #expect(engine.isLoaded == false)
        #expect(engine.isLoading == false)
        #expect(engine.loadError != nil)
    }

    @Test("Synchronous engine.load with remote URL does not self-cancel its own loadingTask")
    @MainActor
    func testLoadNetworkURLViaSynchronousLoadWrapper() async {
        let engine = PlayerEngine.makeForTesting()
        // Calls synchronous load(_:) which wraps into loadingTask = Task { await loadAsync(...) }
        engine.load(path: "http://127.0.0.1:65534/nonexistent.mkv")

        // Wait until asynchronous loading concludes
        let deadline = ContinuousClock.now + .seconds(8)
        while engine.isLoading && ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(engine.isLoading == false)
        #expect(engine.isLoaded == false)
        // If the task cancelled itself, loadError would be nil and state would be .idle
        // With the fix, the network failure is properly encountered and reported:
        #expect(engine.loadError != nil)
        if case .failed = engine.playbackState {
            // Success
        } else {
            Issue.record("Expected playbackState to be .failed, but got \(engine.playbackState)")
        }
    }

    @Test("Engine notifies playbackState changes and time updates")
    @MainActor
    func testPlaybackStateTransitions() async {
        let engine = PlayerEngine.makeForTesting()
        #expect(engine.playbackState == .idle)

        var statesReceived: [PlaybackState] = []
        engine.onPlaybackStateChanged = { state in
            statesReceived.append(state)
        }

        // Test network error transition
        await engine.loadAsync(path: "http://127.0.0.1:65534/nonexistent.mkv")
        #expect(statesReceived.contains(.loading))
        if case .failed = engine.playbackState {
            // Success: state is failed
        } else {
            Issue.record("Expected playbackState to be .failed, but got \(engine.playbackState)")
        }

        // Stop resets to idle
        engine.stop()
        #expect(engine.playbackState == .idle)

        // Stopping active playback directly transitions to .idle without .paused
        engine.playbackState = .playing
        statesReceived.removeAll()
        engine.stop()
        #expect(engine.playbackState == .idle)
        #expect(statesReceived == [.idle])
    }

    @Test("Engine cancellation resets to idle instead of failed")
    @MainActor
    func testLoadCancellationResetsToIdle() async {
        let engine = PlayerEngine.makeForTesting()
        let loadTask = Task { @MainActor in
            await engine.loadAsync(path: "http://127.0.0.1:65534/slow.mkv")
        }
        // Cancel immediately
        loadTask.cancel()
        await loadTask.value

        #expect(engine.playbackState == .idle)
        #expect(engine.loadError == nil)
    }

    @Test("Engine play restarts from start when in completed state")
    @MainActor
    func testPlayRestartsWhenCompleted() {
        guard let referencePath = SyntheticTestMediaFactory.ensureMedia(preset: .hevc10BitHDR) else { return }
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return
        }

        let engine = PlayerEngine.makeForTesting()
        engine.load(path: referencePath)
        #expect(engine.isLoaded == true)

        engine.seek(to: 5.0)
        #expect(engine.currentTime == 5.0)

        engine.playbackState = .completed
        engine.play()  // should seek to 0.0
        #expect(engine.currentTime == 0.0)
        engine.stop()
    }

    @Test("MediaDemuxer.isNetworkURL correctly detects schemes case-insensitively")
    func testIsNetworkURL() {
        #expect(MediaURL.isNetworkURL("http://example.com/video.mp4") == true)
        #expect(MediaURL.isNetworkURL("HTTP://EXAMPLE.COM/VIDEO.MP4") == true)
        #expect(MediaURL.isNetworkURL("https://secure.stream.io/hls.m3u8") == true)
        #expect(MediaURL.isNetworkURL("Https://Secure.stream.io") == true)
        #expect(MediaURL.isNetworkURL("/Users/user/video.mkv") == false)
        #expect(MediaURL.isNetworkURL("file:///path/to/movie.mov") == false)
    }

    @Test("PlayerEngine.resolveTitle correctly prioritizes explicit title over URL and path")
    func testResolveTitle() {
        // 1. Explicit title always takes precedence
        #expect(PlayerEngine.resolveTitle(from: "http://example.com/stream", explicitTitle: "My Film") == "My Film")
        #expect(PlayerEngine.resolveTitle(from: "/path/video.mkv", explicitTitle: "Custom Title") == "Custom Title")

        // 2. Network URL fallback to lastPathComponent or host
        #expect(PlayerEngine.resolveTitle(from: "http://media.server:8096/videos/stream.mkv") == "stream.mkv")
        #expect(PlayerEngine.resolveTitle(from: "http://media.server:8096/") == "media.server")

        // 3. Local file path fallback to filename
        #expect(PlayerEngine.resolveTitle(from: "/Users/alice/Movies/Inception.2010.mkv") == "Inception.2010.mkv")
    }

    @Test("PlayerEngine load updates mediaTitle and stop clears it")
    @MainActor
    func testEngineMediaTitleLifecycle() {
        let engine = PlayerEngine.makeForTesting()
        #expect(engine.mediaTitle == "")

        // Load with explicit title
        engine.load(path: "http://127.0.0.1:65534/dummy", title: "Blade Runner")
        #expect(engine.mediaTitle == "Blade Runner")

        // Stop resets title
        engine.stop()
        #expect(engine.mediaTitle == "")

        // Load without explicit title uses path resolution
        engine.load(path: "/path/to/Interstellar.mp4")
        #expect(engine.mediaTitle == "Interstellar.mp4")
        engine.stop()
    }

    @Test("PlayerEngine correctly loads and handles audio-only files without video")
    @MainActor
    func testAudioOnlyPlayback() {
        guard let audioPath = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC) else { return }
        guard FileManager.default.fileExists(atPath: audioPath) else { return }

        let engine = PlayerEngine.makeForTesting()
        engine.load(path: audioPath)

        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == false)
        #expect(engine.duration > 0.0)
        #expect(engine.videoWidth == 0)
        #expect(engine.videoHeight == 0)
        #expect(!engine.audioTracks.isEmpty)

        // Test playback control
        engine.play()
        #expect(engine.isPlaying == true)

        engine.pause()
        #expect(engine.isPlaying == false)

        // Test seek
        engine.seek(to: 5.0)
        #expect(engine.currentTime == 5.0)

        engine.seekRelative(by: 2.0)
        #expect(engine.currentTime == 7.0)

        engine.stop()
        #expect(engine.isLoaded == false)
        #expect(engine.playbackState == .idle)
    }

    @Test("Switching from video to audio-only file clears video state")
    @MainActor
    func testVideoToAudioSwitchClearsVideoState() {
        guard let referenceVideoPath = SyntheticTestMediaFactory.ensureMedia(preset: .uhdHDRSubtitles) else { return }
        guard let audioPath = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC) else { return }
        guard
            FileManager.default.fileExists(atPath: audioPath)
        else { return }

        let engine = PlayerEngine.makeForTesting()
        // 1. Load video
        engine.load(path: referenceVideoPath)
        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == true)
        #expect(engine.videoWidth > 0)

        // 2. Load audio directly (simulates Command + O open audio file after video)
        engine.load(path: audioPath)
        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == false)
        #expect(engine.videoWidth == 0)
        #expect(engine.videoHeight == 0)

        engine.stop()
        #expect(engine.isLoaded == false)
    }

    @Test("Track resolver resolves audio tracks by id, language, and title")
    func testResolveAudioTrack() {
        let tracks = [
            MediaDemuxer.AudioTrack(
                id: 0,
                streamIndex: 1,
                title: "Original Japanese (Stereo)",
                language: "jpn",
                codecName: "aac",
                channels: 2,
                sampleRate: 48000
            ),
            MediaDemuxer.AudioTrack(
                id: 1,
                streamIndex: 2,
                title: "English Dub",
                language: "eng",
                codecName: "aac",
                channels: 6,
                sampleRate: 48000
            ),
            MediaDemuxer.AudioTrack(
                id: 2,
                streamIndex: 3,
                title: "Russian Commentary",
                language: "rus",
                codecName: "aac",
                channels: 2,
                sampleRate: 48000
            ),
        ]

        // Numerical ID
        #expect(PlayerEngine.resolveAudioTrackId("1", in: tracks) == 1)
        #expect(PlayerEngine.resolveAudioTrackId("0", in: tracks) == 0)

        // Language code
        #expect(PlayerEngine.resolveAudioTrackId("jpn", in: tracks) == 0)
        #expect(PlayerEngine.resolveAudioTrackId("eng", in: tracks) == 1)
        #expect(PlayerEngine.resolveAudioTrackId("rus", in: tracks) == 2)

        // Title fragment
        #expect(PlayerEngine.resolveAudioTrackId("Commentary", in: tracks) == 2)
        #expect(PlayerEngine.resolveAudioTrackId("Dub", in: tracks) == 1)

        // Stream index (e.g. from container / media server stream index)
        #expect(PlayerEngine.resolveAudioTrackId("stream:3", in: tracks) == 2)
        #expect(PlayerEngine.resolveAudioTrackId("s:2", in: tracks) == 1)

        // Non-existent or empty
        #expect(PlayerEngine.resolveAudioTrackId("fre", in: tracks) == nil)
        #expect(PlayerEngine.resolveAudioTrackId("99", in: tracks) == nil)
        #expect(PlayerEngine.resolveAudioTrackId("stream:99", in: tracks) == nil)
        #expect(PlayerEngine.resolveAudioTrackId("", in: tracks) == nil)
    }

    @Test("Track resolver resolves subtitle tracks by id, language, title, and off/none/disabled")
    func testResolveSubtitleTrack() {
        let tracks = [
            SubtitleTrack(id: 0, streamIndex: 3, title: "English Full", language: "eng"),
            SubtitleTrack(id: 1, streamIndex: 4, title: "Russian Forced", language: "rus", isForced: true),
            SubtitleTrack(id: 2, streamIndex: 5, title: "Japanese Signs & Songs", language: "jpn"),
        ]

        // Off / none / disabled / no
        #expect(PlayerEngine.resolveSubtitleSelection("off", in: tracks) == .disable)
        #expect(PlayerEngine.resolveSubtitleSelection("none", in: tracks) == .disable)
        #expect(PlayerEngine.resolveSubtitleSelection("disabled", in: tracks) == .disable)
        #expect(PlayerEngine.resolveSubtitleSelection("no", in: tracks) == .disable)

        // Numerical ID
        #expect(PlayerEngine.resolveSubtitleSelection("0", in: tracks) == .select(trackId: 0))
        #expect(PlayerEngine.resolveSubtitleSelection("1", in: tracks) == .select(trackId: 1))

        // Stream index (e.g. from container / media server stream index)
        #expect(PlayerEngine.resolveSubtitleSelection("stream:4", in: tracks) == .select(trackId: 1))
        #expect(PlayerEngine.resolveSubtitleSelection("s:5", in: tracks) == .select(trackId: 2))
        // Direct streamIndex fallback when number exceeds track IDs
        #expect(PlayerEngine.resolveSubtitleSelection("5", in: tracks) == .select(trackId: 2))

        // Language code
        #expect(PlayerEngine.resolveSubtitleSelection("rus", in: tracks) == .select(trackId: 1))
        #expect(PlayerEngine.resolveSubtitleSelection("jpn", in: tracks) == .select(trackId: 2))

        // Title fragment
        #expect(PlayerEngine.resolveSubtitleSelection("Signs", in: tracks) == .select(trackId: 2))

        // Short word false-positive protection (e.g. "ru" won't falsely substring-match arbitrary words if not a word)
        #expect(PlayerEngine.resolveSubtitleSelection("ger", in: tracks) == nil)
        #expect(PlayerEngine.resolveSubtitleSelection("99", in: tracks) == nil)
        #expect(PlayerEngine.resolveSubtitleSelection("stream:99", in: tracks) == nil)
        #expect(PlayerEngine.resolveSubtitleSelection("", in: tracks) == nil)
    }

    @Test("Playback rate controls change speed, clamp bounds, and reset")
    @MainActor
    func testPlaybackRateControls() {
        let engine = PlayerEngine.makeForTesting()

        #expect(engine.playbackRate == 1.0)

        engine.setPlaybackRate(1.5)
        #expect(engine.playbackRate == 1.5)

        engine.stepPlaybackRate(by: 0.1)
        #expect(abs(engine.playbackRate - 1.6) < 0.001)

        engine.stepPlaybackRate(by: -0.2)
        #expect(abs(engine.playbackRate - 1.4) < 0.001)

        // Precision for 0.75x and 1.25x presets
        engine.setPlaybackRate(0.75)
        #expect(engine.playbackRate == 0.75)

        engine.setPlaybackRate(1.25)
        #expect(engine.playbackRate == 1.25)

        // Upper clamp
        engine.setPlaybackRate(10.0)
        #expect(engine.playbackRate == 4.0)

        // Lower clamp
        engine.setPlaybackRate(0.0)
        #expect(engine.playbackRate == 0.5)

        // Reset
        engine.resetPlaybackRate()
        #expect(engine.playbackRate == 1.0)
    }

    @Test("Switching media preserves and restores saved playback position")
    @MainActor
    func testSwitchingMediaPreservesAndRestoresPlaybackPosition() async {
        guard let path1 = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264),
            let path2 = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264)
        else { return }

        let config = PlayerConfiguration(
            resumePlayback: true,
            resumeStartThreshold: 15.0,
            resumeEndThresholdRatio: 0.95
        )
        let engine = PlayerEngine.makeForTesting(configuration: config)
        let historyStore = engine.historyStore

        // 1. Load first file (60s) and seek past resume threshold (to 25.0s)
        engine.load(path: path1)
        #expect(engine.isLoaded == true)
        engine.seek(to: 25.0)
        #expect(engine.currentTime == 25.0)

        // Give settle loop a moment
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 2. Switch to second file (30s)
        engine.load(path: path2)
        #expect(engine.isLoaded == true)
        #expect(engine.currentTime == 0.0)

        // Verify history was saved for file 1
        let saved1 = historyStore.savedPosition(for: path1)
        #expect(saved1 != nil)
        #expect(abs((saved1 ?? 0.0) - 25.0) < 1.0)

        // Seek in file 2 to 18.0s
        engine.seek(to: 18.0)
        #expect(engine.currentTime == 18.0)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 3. Switch back to file 1 -> should restore to ~25.0s
        engine.load(path: path1)
        #expect(engine.isLoaded == true)
        #expect(abs(engine.currentTime - 25.0) < 1.0)

        // 4. Switch back to file 2 -> should restore to ~18.0s
        engine.load(path: path2)
        #expect(engine.isLoaded == true)
        #expect(abs(engine.currentTime - 18.0) < 1.0)

        engine.stop()
    }

    @Test("MediaLoadRequest builder and fluent methods configure request properly")
    func testMediaLoadRequestBuilder() {
        let req = MediaLoadRequest(path: "https://example.com/stream.m3u8")
            .title("Sample Stream")
            .headers(["Authorization": "Bearer token123"])
            .startTime(42.5)
            .audioTrack("eng")
            .subtitleTrack("fra")

        #expect(req.path == "https://example.com/stream.m3u8")
        #expect(req.title == "Sample Stream")
        #expect(req.headers["Authorization"] == "Bearer token123")
        #expect(req.startTime == 42.5)
        #expect(req.audioTrack == "eng")
        #expect(req.subtitleTrack == "fra")
    }

    @Test("PlayerEngineProtocol mock can be trivially implemented with minimal load methods")
    @MainActor
    func testPlayerEngineProtocolMock() {
        @MainActor
        final class MockEngine: PlayerEngineProtocol {
            var loadedRequest: MediaLoadRequest?
            var asyncLoadedRequest: MediaLoadRequest?

            func load(_ request: MediaLoadRequest) {
                loadedRequest = request
            }

            func loadAsync(_ request: MediaLoadRequest) async {
                asyncLoadedRequest = request
            }

            // Minimal stubbed properties and requirements
            var playbackState: PlaybackState = .idle
            var onTimeUpdate: ((Double, Double) -> Void)? = nil
            var onPlaybackStateChanged: ((PlaybackState) -> Void)? = nil
            var onRelativeSeekResolved: ((Double, Double) -> Void)? = nil
            var currentTime: Double = 0
            var pendingSeekTime: Double? = nil
            var isSeeking: Bool = false
            var duration: Double = 0
            var isPlaying: Bool = false
            var isLoaded: Bool = false
            var isLoading: Bool = false
            var loadError: String? = nil
            var mediaTitle: String = ""
            var artworkData: Data? = nil
            var artworkURL: URL? = nil
            var hasVideo: Bool = false
            var videoWidth: Int = 1920
            var videoHeight: Int = 1080
            var nominalFrameDuration: Double = 1.0 / 24.0
            var sampleAspectRatio: RationalAspectRatio = RationalAspectRatio(numerator: 1, denominator: 1)
            var displayAspectRatio: Double = 16.0 / 9.0
            var videoCodecName: String = "hevc"
            var videoBitDepth: Int = 10
            var videoColorPrimaries: String = "bt2020"
            var videoTransferFunction: String = "smpte2084"
            var videoDolbyVisionProfile: String? = nil
            var videoSourcePeakNits: Float = 1000.0
            var renderMode: RenderMode = .auto
            var isInterlacedContent: Bool = false
            var deinterlaceMode: DeinterlaceMode = .auto
            var isHDRDisplay: Bool = false
            var isToneMappingPermitted: Bool = true
            nonisolated var activeRenderMode: RenderMode { .metalToneMap }
            var isDisplaySleepDisabled: Bool = false
            var metalExposure: Float = 0
            var metalShadowLift: Float = 0
            var metalTargetNits: Float = 203.0
            var targetNitsScale: Float = 1.0
            var baseAdaptiveTargetNits: Float = 203.0
            var metalSharpness: Float = 0
            var volume: Float = 1.0
            var isMuted: Bool = false
            var playbackRate: Double = 1.0
            var seekStepSeconds: Double = 5.0
            var exactSeekOnSinglePress: Bool = false
            var enableOSD: Bool = true
            var showDebugHUD: Bool = false
            var droppedFramesCount: Int = 0
            var pipelineDroppedFramesCount: Int = 0
            var speedSkippedFramesCount: Int = 0
            var thumbnailManager: ThumbnailManager = ThumbnailManager()
            var audioTracks: [MediaDemuxer.AudioTrack] = []
            var selectedAudioTrackId: Int = 0
            var subtitleTracks: [SubtitleTrack] = []
            var selectedSubtitleTrackId: Int? = nil
            var chapters: [MediaChapter] = []
            var currentChapterIndex: Int? = nil
            var currentSubtitleText: String? = nil
            var currentSubtitleCue: SubtitleCue? = nil
            var currentSubtitleCues: [SubtitleCue] = []
            var subtitleFontSize: Double = 16.0
            var subtitleFontName: String = "Helvetica"
            var subtitleFontWeight: String = "Regular"
            var subtitleTextColorHex: String = "#FFFFFF"
            var subtitleBgColorHex: String = "#000000"
            var subtitleBgOpacity: Double = 0.5
            var playlist: PlaylistManager = PlaylistManager()

            init() {}

            func selectSubtitleTrack(id: Int?) {}
            func loadExternalSubtitle(url: URL) {}
            func stop() {}
            func play() {}
            func pause() {}
            func togglePlayPause() {}
            func seek(to seconds: Double, exact: Bool) {}
            func seekRelative(by seconds: Double, exact: Bool) {}
            func stepFrameForward() {}
            func stepFrameBackward() {}
            func stepVolume(by delta: Float) {}
            func toggleMute() {}
            func toggleDebugHUD() {}
            func renderCurrentFrame() {}
            func selectAudioTrack(id: Int) {}
            func seekToChapter(_ chapter: MediaChapter) {}
            func nextChapter() -> MediaChapter? { nil }
            func previousChapter() -> MediaChapter? { nil }
            func playNext() {}
            func playPrevious() {}
            func playPlaylistItem(id: UUID) {}
            func removePlaylistItem(id: UUID) {}
        }

        let mock = MockEngine()
        // Verify convenience protocol extension overload delegates to single load(request)
        mock.load(path: "test.mkv", title: "Test Title")
        #expect(mock.loadedRequest?.path == "test.mkv")
        #expect(mock.loadedRequest?.title == "Test Title")
    }

    @Test("Focused PlayerPlaybackControlling protocol can be mocked with minimal properties")
    @MainActor
    func testPlayerPlaybackControllingMock() {
        @MainActor
        final class MinimalPlaybackMock: PlayerPlaybackControlling {
            var loadedRequest: MediaLoadRequest?
            var playCalled = false
            var pauseCalled = false

            var playbackState: PlaybackState = .idle
            var onTimeUpdate: ((Double, Double) -> Void)? = nil
            var onPlaybackStateChanged: ((PlaybackState) -> Void)? = nil
            var onRelativeSeekResolved: ((Double, Double) -> Void)? = nil
            var currentTime: Double = 0
            var pendingSeekTime: Double? = nil
            var isSeeking: Bool = false
            var duration: Double = 0
            var isPlaying: Bool = false
            var isLoaded: Bool = false
            var isLoading: Bool = false
            var loadError: String? = nil
            var mediaTitle: String = ""
            var artworkData: Data? = nil
            var artworkURL: URL? = nil
            var volume: Float = 1.0
            var isMuted: Bool = false
            var playbackRate: Double = 1.0
            var seekStepSeconds: Double = 5.0
            var exactSeekOnSinglePress: Bool = false

            init() {}

            func load(_ request: MediaLoadRequest) { loadedRequest = request }
            func loadAsync(_ request: MediaLoadRequest) async { loadedRequest = request }
            func stop() {}
            func play() { playCalled = true }
            func pause() { pauseCalled = true }
            func togglePlayPause() {}
            func seek(to seconds: Double, exact: Bool) {}
            func seekRelative(by seconds: Double, exact: Bool) {}
            func stepFrameForward() {}
            func stepFrameBackward() {}
            func stepVolume(by delta: Float) {}
            func toggleMute() {}
        }

        let mock = MinimalPlaybackMock()
        mock.play()
        #expect(mock.playCalled == true)

        mock.load(path: "audio.flac")
        #expect(mock.loadedRequest?.path == "audio.flac")
    }
}
