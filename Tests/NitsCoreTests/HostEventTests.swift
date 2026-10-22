import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

/// Events and state a host without access to observation (through `PlayerEngineProtocol`) relies on.
@Suite("Host events", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct HostEventTests {
    @Test("A load reports its tracks once, a track switch again, and a selection that changes nothing not at all")
    func reportsTrackChanges() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        var reports: [(audio: [Int], selectedAudio: Int)] = []
        engine.onTracksChanged = {
            reports.append((engine.audioTracks.map(\.id), engine.selectedAudioTrackId))
        }

        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        try #require(reports.count == 1, "Reports after the load: \(reports)")
        #expect(reports[0].audio == engine.audioTracks.map(\.id))
        #expect(reports[0].selectedAudio == engine.selectedAudioTrackId)
        try #require(engine.audioTracks.count >= 2, "The preset has two audio tracks")

        let other = try #require(engine.audioTracks.first { $0.id != engine.selectedAudioTrackId })
        engine.selectAudioTrack(id: other.id)
        #expect(reports.count == 2)
        #expect(reports.last?.selectedAudio == other.id)

        engine.subtitles.select(trackId: engine.subtitles.selectedTrackId)
        engine.selectAudioTrack(id: other.id)
        engine.selectAudioTrack(id: -42)
        #expect(reports.count == 2, "Re-selecting a selected track or an unknown one reported a change")
        #expect(engine.selectedAudioTrackId == other.id)
    }

    @Test("Loading media with the same tracks as the previous one still reports them")
    func reportsTracksOfEveryLoad() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        var reports = 0
        engine.onTracksChanged = { reports += 1 }

        // No tracks at all: the same as the engine's state before the first load.
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        #expect(reports == 1)

        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        #expect(reports == 2)
    }

    @Test("Stopping clears the tracks and reports it once")
    func stopClearsTracks() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        var reports = 0
        engine.onTracksChanged = { reports += 1 }

        engine.stop()
        #expect(reports == 1)
        #expect(engine.audioTracks.isEmpty && engine.subtitles.tracks.isEmpty)
        #expect(engine.selectedAudioTrackId == -1 && engine.subtitles.selectedTrackId == nil)
    }

    @Test("A load that fails keeps nothing of the previous media and reports its tracks gone once")
    func failedLoadClearsPreviousMedia() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        try #require(!engine.audioTracks.isEmpty && engine.videoWidth > 0)
        engine.setAudioDelay(0.2)
        engine.subtitles.setDelay(2.5)
        engine.setVideoAspectRatio(RationalAspectRatio(numerator: 4, denominator: 3))
        var reports = 0
        engine.onTracksChanged = { reports += 1 }

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        engine.load(path: missing.path)
        guard case .failed = engine.playbackState else {
            Issue.record("Loading a missing file left the engine \(engine.playbackState)")
            return
        }
        #expect(reports == 1)
        #expect(engine.audioTracks.isEmpty && engine.subtitles.tracks.isEmpty && engine.variants.isEmpty)
        #expect(engine.selectedAudioTrackId == -1 && engine.subtitles.selectedTrackId == nil)
        #expect(engine.videoWidth == 0 && engine.videoHeight == 0 && engine.videoCodecName.isEmpty)
        #expect(!engine.hasVideo && engine.duration == 0 && engine.chapters.isEmpty)
        #expect(engine.audioDelay == 0 && engine.subtitles.delay == 0)
        #expect(engine.videoGeometry.aspectRatio == nil)
    }

    @Test("A load that fails after HDR media leaves no HDR content to tone-map")
    func failedLoadClearsHDR() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hevc10BitHDR) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await waitUntil { engine.isLoaded })
        try #require(engine.isHDRContent)

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        engine.load(path: missing.path)
        #expect(!engine.isHDRContent)
    }

    @Test("Stopping a load still running in the background reports the previous media's tracks gone once")
    func stopDuringLoadReportsClearedTracks() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        var reports = 0
        engine.onTracksChanged = { reports += 1 }

        // Runs up to its first suspension: the reset, then the demuxer opening off the main actor.
        let load = Task { await engine.loadAsync(MediaLoadRequest(path: path)) }
        for _ in 0..<100 where !engine.isLoading { await Task.yield() }
        try #require(engine.isLoading && engine.audioTracks.isEmpty, "The load hasn't reset the engine yet")
        #expect(reports == 0, "A load reports the cleared tracks with the new ones")

        engine.stop()
        #expect(reports == 1, "stop() reports at once")
        await load.value
        #expect(reports == 1, "The stopped load reported again")
        #expect(engine.playbackState == .idle && engine.audioTracks.isEmpty)
    }

    @Test("A load cancelled by its task reports the previous media's tracks gone once")
    func cancelledLoadReportsClearedTracks() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        var reports = 0
        engine.onTracksChanged = { reports += 1 }

        let load = Task { await engine.loadAsync(MediaLoadRequest(path: path)) }
        load.cancel()
        await load.value
        #expect(engine.playbackState == .idle)
        #expect(reports == 1)
        #expect(engine.audioTracks.isEmpty && engine.selectedAudioTrackId == -1)
    }

    @Test("Audio-only media loaded after a video keeps none of the video's properties")
    func audioOnlyLoadClearsVideoProperties() async throws {
        guard let video = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264),
            let audio = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC)
        else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: video)
        try #require(await engine.waitForPlayback())
        try #require(!engine.videoCodecName.isEmpty)

        engine.load(path: audio)
        try #require(await engine.waitForPlayback())
        #expect(!engine.hasVideo)
        #expect(engine.videoWidth == 0 && engine.videoHeight == 0)
        #expect(engine.videoCodecName.isEmpty && engine.videoColorPrimaries.isEmpty)
    }

    @Test("Packet ends saturate on corrupt timestamps instead of overflowing")
    func packetEndSaturates() {
        #expect(MediaDemuxer.packetEnd(pts: 100, duration: 20) == 120)
        #expect(MediaDemuxer.packetEnd(pts: 100, duration: -5) == 100)
        #expect(MediaDemuxer.packetEnd(pts: Int64.max - 1, duration: 20) == Int64.max)
    }

    @Test("Adding a subtitle file reports the new track once, already selected")
    func reportsAddedSubtitleFileOnce() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let subtitleURL = directory.appendingPathComponent("added.srt")
        try "1\n00:00:00,000 --> 00:00:05,000\nHello\n".write(to: subtitleURL, atomically: true, encoding: .utf8)

        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        var reports: [Int?] = []
        engine.onTracksChanged = { reports.append(engine.subtitles.selectedTrackId) }

        engine.subtitles.addExternal(url: subtitleURL)
        let added = try #require(engine.subtitles.tracks.first { $0.externalURL != nil })
        #expect(reports == [added.id])
    }

    @Test("A burst of seeks reports seeking once when it starts and once when playback resumes")
    func reportsSeekingWhilePlaying() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        var changes: [Bool] = []
        engine.onSeekingChanged = { changes.append($0) }

        engine.seek(to: 3.0)
        engine.seek(to: 4.0)
        engine.seek(to: 2.0)
        #expect(changes == [true])
        #expect(
            await engine.waitUntil(timeout: .seconds(5)) { !changes.isEmpty && changes.last == false },
            "Changes: \(changes)")
        #expect(changes == [true, false])
        #expect(engine.isPlaying)
    }

    @Test("Pausing while a playing seek waits to resume settles the seek, and play() resumes from its target")
    func pauseDuringSeekSettle() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        var changes: [Bool] = []
        engine.onSeekingChanged = { changes.append($0) }

        engine.seek(to: 3.0)
        try #require(await engine.waitUntil(timeout: .seconds(5)) { !engine.isSeeking }, "The seek did not decode")
        try #require(engine.pendingSeekTime != nil, "The seek resumed before the pause")
        engine.pause()
        #expect(changes == [true, false])
        #expect(engine.pendingSeekTime == nil)

        engine.play()
        #expect(
            await engine.waitUntil(timeout: .seconds(5)) { engine.isPlaying && engine.currentTime > 3.2 },
            "At \(engine.currentTime)s, playing \(engine.isPlaying)")
    }

    @Test("A paused seek reports seeking until its frame settles")
    func reportsSeekingWhilePaused() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        engine.pause()
        var changes: [Bool] = []
        engine.onSeekingChanged = { changes.append($0) }

        engine.seek(to: 3.0)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { changes == [true, false] }, "Changes: \(changes)")
        #expect(!engine.isSeeking && engine.pendingSeekTime == nil)
    }

    @Test("The buffered position runs ahead of playback and reaches the duration once the file is read to its end")
    func bufferedTimeRunsAhead() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.playlist.setRepeatMode(.off)
        #expect(engine.bufferedTime == 0)

        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        let buffered = engine.bufferedTime
        // Read ahead (`NITS_READ_AHEAD_LOCAL`), the whole 30-second file is read at once.
        #expect(
            buffered > engine.currentTime && (buffered < engine.duration || PlayerEngine.readsAheadLocalFiles),
            "Buffered to \(buffered)s at \(engine.currentTime)s of \(engine.duration)s")

        engine.seek(to: engine.duration - 2.0)
        #expect(
            await engine.waitUntil(timeout: .seconds(5)) { engine.bufferedTime == engine.duration },
            "Buffered to \(engine.bufferedTime)s of \(engine.duration)s")
    }
}
