import Foundation
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

        engine.selectSubtitleTrack(id: engine.selectedSubtitleTrackId)
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
        #expect(engine.audioTracks.isEmpty && engine.subtitleTracks.isEmpty)
        #expect(engine.selectedAudioTrackId == -1 && engine.selectedSubtitleTrackId == nil)
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
        engine.onTracksChanged = { reports.append(engine.selectedSubtitleTrackId) }

        engine.loadExternalSubtitle(url: subtitleURL)
        let added = try #require(engine.subtitleTracks.first { $0.externalURL != nil })
        #expect(reports == [added.id])
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
        #expect(
            buffered > engine.currentTime && buffered < engine.duration,
            "Buffered to \(buffered)s at \(engine.currentTime)s of \(engine.duration)s")

        engine.seek(to: engine.duration - 2.0)
        #expect(
            await engine.waitUntil(timeout: .seconds(5)) { engine.bufferedTime == engine.duration },
            "Buffered to \(engine.bufferedTime)s of \(engine.duration)s")
    }
}
