import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("Player session core")
@MainActor
struct PlayerSessionCoreTests {
    /// A core whose loads go to `requests` instead of the engine.
    private func makeCore() -> (PlayerSessionCore, Requests) {
        let requests = Requests()
        let core = PlayerSessionCore(engine: .makeForTesting(), load: { requests.list.append($0) })
        return (core, requests)
    }

    private final class Requests {
        var list: [MediaLoadRequest] = []
    }

    private final class RecordingSink: PlayerSessionSink {
        var events: [String] = []
        func timeUpdated(current: Double, duration: Double) { events.append("time \(current)") }
        func stateChanged(_ state: PlaybackState) { events.append("state \(state)") }
        func sessionClosing() { events.append("closing") }
    }

    @Test("The core takes the engine's callbacks; the host's callback hears an event before the sinks")
    func callbacksGoToHostThenSinks() {
        let (core, _) = makeCore()
        var order: [String] = []
        let sink = RecordingSink()
        core.addSink(sink)
        core.onTimeUpdate = { current, _ in order.append("host \(current), sink saw \(sink.events.count)") }
        core.onPlaybackStateChanged = { _ in order.append("host state, sink saw \(sink.events.count)") }

        core.engine.onTimeUpdate?(5, 100)
        core.engine.onPlaybackStateChanged?(.paused)

        #expect(order == ["host 5.0, sink saw 0", "host state, sink saw 1"])
        #expect(sink.events == ["time 5.0", "state paused"])
    }

    @Test("Completed reports onPlaybackEnded; other states do not")
    func completedReportsEnd() {
        let (core, _) = makeCore()
        var ended = 0
        core.onPlaybackEnded = { ended += 1 }
        core.engine.onPlaybackStateChanged?(.paused)
        core.engine.onPlaybackStateChanged?(.playing)
        #expect(ended == 0)
        core.engine.onPlaybackStateChanged?(.completed)
        #expect(ended == 1)
    }

    @Test("end() reports onClose once, even with nothing loaded; opens after it load nothing")
    func endIsTerminal() {
        let (core, requests) = makeCore()
        let sink = RecordingSink()
        core.addSink(sink)
        var closes = 0
        core.onClose = { _, _ in closes += 1 }

        core.end()
        core.end()

        #expect(closes == 1)
        #expect(core.isEnded)
        #expect(sink.events == ["closing"])
        #expect(!core.openStream(url: URL(string: "https://example.com/a.mkv")!))
        #expect(!core.load(MediaLoadRequest(path: "/x.mkv")))
        #expect(requests.list.isEmpty)
    }

    @Test("end() runs its hook after onClose and before the sinks")
    func endHookOrder() {
        let (core, _) = makeCore()
        var order: [String] = []
        let sink = RecordingSink()
        core.addSink(sink)
        core.onClose = { _, _ in order.append("onClose") }
        core.end { order.append("hook sink saw \(sink.events.count)") }
        #expect(order == ["onClose", "hook sink saw 0"])
    }

    @Test("close() with nothing opened reports nothing, and the session still opens")
    func closeWithNothingOpened() {
        let (core, requests) = makeCore()
        var closes = 0
        core.onClose = { _, _ in closes += 1 }
        core.close()
        #expect(closes == 0)
        #expect(!core.isEnded)
        #expect(core.openStream(url: URL(string: "https://example.com/a.mkv")!))
        #expect(requests.list.count == 1)
    }

    @Test("close() after a load reports onClose once and the session opens again")
    func closeAfterLoad() {
        let (core, requests) = makeCore()
        var closes = 0
        core.onClose = { _, _ in closes += 1 }
        core.openStream(url: URL(string: "https://example.com/a.mkv")!)
        core.close()
        core.close()
        #expect(closes == 1)
        #expect(core.openStream(url: URL(string: "https://example.com/b.mkv")!))
        core.close()
        #expect(closes == 2)
        #expect(requests.list.count == 2)
    }

    @Test("end() after close() does not report onClose again; a load in between makes it report")
    func endAfterCloseReportsOnce() {
        let (core, _) = makeCore()
        var closes = 0
        core.onClose = { _, _ in closes += 1 }
        core.openStream(url: URL(string: "https://example.com/a.mkv")!)
        core.close()
        core.end()
        #expect(closes == 1)

        let (again, _) = makeCore()
        again.onClose = { _, _ in closes += 1 }
        again.openStream(url: URL(string: "https://example.com/a.mkv")!)
        again.close()
        again.openStream(url: URL(string: "https://example.com/b.mkv")!)
        again.end()
        #expect(closes == 3)
    }

    @Test("Opening from inside the onClose of end() loads nothing; isEnded reads false there, true after")
    func openFromOnCloseOfEndLoadsNothing() {
        let (core, requests) = makeCore()
        var endedInside: Bool?
        var loadedInside: Bool?
        core.onClose = { [unowned core] _, _ in
            endedInside = core.isEnded
            loadedInside = core.openStream(url: URL(string: "https://example.com/next.mkv")!)
        }
        core.end()
        #expect(endedInside == false)
        #expect(loadedInside == false)
        #expect(core.isEnded)
        #expect(requests.list.isEmpty)
    }

    @Test("Media opened from inside onClose is not stopped by the close that reports it")
    func openFromOnCloseSurvives() {
        let (core, requests) = makeCore()
        let sink = RecordingSink()
        core.addSink(sink)
        core.openStream(url: URL(string: "https://example.com/a.mkv")!)
        core.onClose = { [unowned core] _, _ in
            core.openStream(url: URL(string: "https://example.com/b.mkv")!)
        }
        #expect(!core.close(), "Not stopped")
        #expect(requests.list.count == 2)
        #expect(sink.events.isEmpty, "The sinks heard of no closing: nothing was stopped")
        core.onClose = nil
        core.close()
        #expect(sink.events == ["closing"])
    }

    @Test("A load that failed still counts as opened: close() reports onClose (the alert's Close)")
    func closeAfterFailedLoad() {
        // The real engine: a missing file fails the load and leaves it neither loaded nor loading.
        let core = PlayerSessionCore(engine: .makeForTesting())
        var closes = 0
        core.onClose = { _, _ in closes += 1 }
        core.openStream(url: URL(fileURLWithPath: "/nonexistent/never-opened.mkv"))
        #expect(!core.engine.isLoaded)
        core.close()
        #expect(closes == 1)
        core.close()
        #expect(closes == 1)
    }

    @Test("openStream builds the request it was given")
    func openStreamBuildsRequest() throws {
        let (core, requests) = makeCore()
        let button = PlaybackActionButton(id: "intro", title: "Skip Intro", start: 1, end: 5)
        let navigation = TrackNavigation(hasNext: true, nextTitle: "Episode 2")
        core.openStream(
            url: URL(string: "https://example.com/a.mkv")!, title: "A",
            artworkURL: URL(string: "https://example.com/p.jpg"),
            headers: ["Authorization": "Bearer t"], startTime: 12, audioTrack: "jpn", subtitleTrack: "off",
            actionButtons: [button], trackNavigation: navigation)

        let request = try #require(requests.list.first)
        #expect(request.path == "https://example.com/a.mkv")
        #expect(request.title == "A")
        #expect(request.artworkURL == URL(string: "https://example.com/p.jpg"))
        #expect(request.headers == ["Authorization": "Bearer t"])
        #expect(request.startTime == 12)
        #expect(request.audioTrack == "jpn")
        #expect(request.subtitleTrack == "off")
        #expect(request.actionButtons == [button])
        #expect(request.trackNavigation == navigation)
    }

    @Test("load(_:) hands a whole request on: audio files and all")
    func loadTakesWholeRequest() throws {
        let (core, requests) = makeCore()
        let audio = MediaLoadRequest.AudioFile(url: URL(string: "https://example.com/a.m4a")!)
        let request = MediaLoadRequest(path: "/x.mkv", audioFiles: [audio])
        #expect(core.load(request))
        #expect(requests.list.first?.audioFiles == [audio])
    }

    @Test("A file loads by its standardized path, a stream by its address")
    func pathRule() {
        #expect(MediaLoadRequest.path(for: URL(fileURLWithPath: "/files/dir/../a b.mkv")) == "/files/a b.mkv")
        #expect(
            MediaLoadRequest.path(for: URL(string: "https://example.com/a.m3u8?x=1")!)
                == "https://example.com/a.m3u8?x=1")
    }

    @Test("The host's queue forwards to the engine")
    func hostQueueForwards() {
        let (core, _) = makeCore()
        core.onTrackNavigation = { _ in }
        #expect(core.engine.onTrackNavigation != nil)
        core.setTrackNavigation(TrackNavigation(hasNext: true))
        #expect(core.engine.trackNavigation.hasNext)
        var pressed: [String] = []
        core.onActionButton = { pressed.append($0) }
        #expect(core.engine.actionButtons.onPress != nil)
    }
}
