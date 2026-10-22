import Foundation
import Testing

@testable import NitsCore

@Suite("Host track navigation")
@MainActor
struct HostTrackNavigationTests {
    private func makeHostEngine() -> (PlayerEngine, LockIsolated<[TrackNavigationDirection]>) {
        let engine = PlayerEngine.makeForTesting()
        let requests = LockIsolated<[TrackNavigationDirection]>([])
        engine.onTrackNavigation = { direction in requests.withValue { $0.append(direction) } }
        return (engine, requests)
    }

    @Test("Next asks the host once, then waits for its next load")
    func nextAsksHostOnce() {
        let (engine, requests) = makeHostEngine()
        #expect(!engine.canPlayNext)
        #expect(engine.playNext() == nil)

        engine.trackNavigation = TrackNavigation(hasNext: true, nextTitle: "Episode 2")
        #expect(engine.canPlayNext)
        #expect(engine.playNext() == "Episode 2")
        #expect(requests.value == [.next])

        // Repeated presses while the host loads the next item would each skip one more.
        #expect(!engine.canPlayNext)
        #expect(engine.playNext() == nil)
        #expect(requests.value == [.next])
    }

    @Test("Previous does nothing without loaded media")
    func previousNeedsLoadedMedia() {
        let (engine, requests) = makeHostEngine()
        engine.trackNavigation = TrackNavigation(hasPrevious: true)
        #expect(!engine.canPlayPrevious)
        #expect(engine.playPrevious() == nil)
        #expect(requests.value.isEmpty)
    }

    @Test("Each load replaces the host's navigation with its request's")
    func loadReplacesNavigation() {
        let (engine, _) = makeHostEngine()
        defer { engine.stop() }
        engine.trackNavigation = TrackNavigation(hasNext: true)

        let navigation = TrackNavigation(hasPrevious: true, previousTitle: "Episode 1")
        engine.load(MediaLoadRequest(path: "/nonexistent/episode2.mkv", trackNavigation: navigation))
        #expect(engine.trackNavigation == navigation)

        engine.load(MediaLoadRequest(path: "/nonexistent/episode3.mkv"))
        #expect(engine.trackNavigation == TrackNavigation())
    }

    @Test("Without the host's queue, navigation follows the playlist")
    func playlistWithoutHost() {
        let engine = PlayerEngine.makeForTesting()
        engine.trackNavigation = TrackNavigation(hasNext: true, hasPrevious: true)
        #expect(!engine.canPlayNext)
        #expect(!engine.canPlayPrevious)
        #expect(engine.playNext() == nil)
    }
}

@Suite("Host track navigation during playback", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct HostTrackNavigationPlaybackTests {
    private func makeHostEngine() -> (PlayerEngine, LockIsolated<[TrackNavigationDirection]>) {
        let engine = PlayerEngine.makeForTesting()
        let requests = LockIsolated<[TrackNavigationDirection]>([])
        engine.onTrackNavigation = { direction in requests.withValue { $0.append(direction) } }
        return (engine, requests)
    }

    @Test("Previous goes to the host's previous item in the first seconds, else restarts")
    func previousFollowsRestartThreshold() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let (engine, requests) = makeHostEngine()
        defer { engine.stop() }
        engine.load(MediaLoadRequest(path: path, trackNavigation: TrackNavigation(hasPrevious: true)))
        try #require(await engine.waitForPlayback())
        #expect(engine.canPlayPrevious)

        engine.seek(to: 10.0)
        try #require(await engine.waitForSeekToSettle())
        #expect(engine.playPrevious() == engine.mediaTitle)
        #expect(await engine.waitUntil { engine.currentTime < 3.0 })
        #expect(requests.value.isEmpty, "Played past the threshold, Previous restarts")

        try #require(await engine.waitForSeekToSettle())
        engine.playPrevious()
        #expect(requests.value == [.previous])
        // Like Next: one press, one item.
        engine.playPrevious()
        #expect(requests.value == [.previous])
        #expect(engine.canPlayPrevious, "Without a previous item Previous still restarts")
    }

    @Test("At the end the host decides what plays next, whatever the playlist's repeat mode")
    func endOfMediaIsLeftToHost() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let (engine, requests) = makeHostEngine()
        defer { engine.stop() }
        engine.playlist.setRepeatMode(.one)
        engine.load(MediaLoadRequest(path: path, trackNavigation: TrackNavigation(hasNext: true)))
        try #require(await engine.waitForPlayback())

        engine.seek(to: engine.media.duration - 1.0)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.playbackState == .completed })
        #expect(requests.value.isEmpty, "The end is reported through the state, not as a Next press")
    }
}
