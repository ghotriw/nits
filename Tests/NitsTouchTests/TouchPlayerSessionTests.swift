#if os(iOS)
    import NitsCore
    import SwiftUI
    import Observation
    import Testing
    import os

    @testable import NitsCore
    @testable import NitsTouch

    @MainActor
    private final class Recorder {
        var events: [String] = []
        var requests: [MediaLoadRequest] = []
    }

    @MainActor
    private struct FakeAccess: ScopedURLAccessing {
        let recorder: Recorder
        func start(_ url: URL) -> Bool {
            recorder.events.append("start \(url.lastPathComponent)")
            return true
        }
        func stop(_ url: URL) { recorder.events.append("stop \(url.lastPathComponent)") }
    }

    @MainActor
    private final class FakeHooks: HostLifecycleHooks {
        var calls: [String] = []
        weak var recorder: Recorder?
        func hostDidEnterBackground() {
            calls.append("background")
            recorder?.events.append("background")
        }
        func hostWillEnterForeground() { calls.append("foreground") }
    }

    @MainActor
    private func makeEngine() -> PlayerEngine {
        PlayerEngine(
            configuration: TouchPlayerSession.defaultConfiguration, historyStore: PlaybackHistoryStore(fileURL: nil),
            durationCache: MediaDurationCache(fileURL: nil))
    }

    @Suite("Touch player session")
    @MainActor
    struct TouchPlayerSessionTests {
        private func session(
            recorder: Recorder = Recorder(), hooks: FakeHooks = FakeHooks()
        ) -> TouchPlayerSession {
            hooks.recorder = recorder
            return TouchPlayerSession(
                engine: makeEngine(), access: FakeAccess(recorder: recorder), hooks: hooks,
                load: { [recorder] request in
                    recorder.events.append("load \((request.path as NSString).lastPathComponent)")
                    recorder.requests.append(request)
                },
                saveProgress: { [recorder] in recorder.events.append("save") })
        }

        @Test("A second file's access is taken before its load and the first's released after it starts")
        func secondOpenReleasesFirstAccessAfterLoad() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            session.open(URL(fileURLWithPath: "/files/a.mkv"))
            session.open(URL(fileURLWithPath: "/files/b.mkv"))
            #expect(recorder.events == ["start a.mkv", "load a.mkv", "start b.mkv", "load b.mkv", "stop a.mkv"])
        }

        @Test("Closing releases the access held")
        func closeReleasesAccess() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            session.open(URL(fileURLWithPath: "/files/a.mkv"))
            session.close()
            #expect(recorder.events.last == "stop a.mkv")
            session.close()
            #expect(recorder.events.filter { $0.hasPrefix("stop") }.count == 1, "Released once")
        }

        @Test("A network address needs a scheme and a host")
        func networkStringWithoutSchemeIsRejected() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            #expect(!session.openNetwork("example.com/video.m3u8"))
            #expect(!session.openNetwork("ftp://example.com/video"))
            #expect(!session.openNetwork("   "))
            #expect(session.errorMessage != nil)
            #expect(recorder.events.isEmpty)
            #expect(session.openNetwork("  https://example.com/video.m3u8 "))
            #expect(recorder.events == ["load video.m3u8"])
            #expect(session.errorMessage == nil)
        }

        @Test("The engine shows every picture through the system layer")
        func renderModeIsSystem() {
            let session = TouchPlayerSession()
            #expect(session.engine.configuration.defaultRenderMode == .system)
            #expect(session.engine.renderMode == .system)
            #expect(session.engine.configuration.frameQueueByteBudget == TouchPlayerSession.frameQueueByteBudget)
        }

        @Test("A host's configuration and history store reach the engine")
        func hostConfiguration() {
            var configuration = TouchPlayerSession.defaultConfiguration
            configuration.defaultRenderMode = .metalToneMap
            let store = PlaybackHistoryStore(fileURL: nil)
            let session = TouchPlayerSession(configuration: configuration, historyStore: store)
            #expect(session.engine.configuration.defaultRenderMode == .metalToneMap)
            #expect(session.engine.historyStore === store)
        }

        @Test("Inactive (Control Center, a banner) touches nothing; background and back do")
        func inactivePhaseKeepsPlayingState() {
            let hooks = FakeHooks()
            let session = session(hooks: hooks)
            session.scenePhaseChanged(.active)
            session.scenePhaseChanged(.inactive)
            session.scenePhaseChanged(.active)
            #expect(hooks.calls.isEmpty)

            session.scenePhaseChanged(.inactive)
            session.scenePhaseChanged(.background)
            session.scenePhaseChanged(.background)
            session.scenePhaseChanged(.inactive)
            #expect(hooks.calls == ["background"])
            session.scenePhaseChanged(.active)
            #expect(hooks.calls == ["background", "foreground"])
        }

        @Test("Going to the background writes the history after the engine heard of it, not before")
        func backgroundSavesAfterEngineHears() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            session.scenePhaseChanged(.background)
            session.scenePhaseChanged(.background)
            #expect(recorder.events == ["background", "save"])
            session.scenePhaseChanged(.active)
            #expect(recorder.events == ["background", "save"], "Coming back saves nothing")
        }

        @Test("The engine's callbacks reach the host through the session")
        func callbacksGoThroughSession() {
            let session = session()
            var times: [Double] = []
            var states: [PlaybackState] = []
            var ended = 0
            session.onTimeUpdate = { current, _ in times.append(current) }
            session.onPlaybackStateChanged = { states.append($0) }
            session.onPlaybackEnded = { ended += 1 }

            session.engine.onTimeUpdate?(5, 100)
            session.engine.onPlaybackStateChanged?(.paused)
            session.engine.onPlaybackStateChanged?(.completed)

            #expect(times == [5])
            #expect(states == [.paused, .completed])
            #expect(ended == 1)
        }

        @Test("openStream hands the host's request on, with headers, start time, tracks, buttons and queue")
        func openStreamBuildsRequest() throws {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            let button = PlaybackActionButton(id: "intro", title: "Skip Intro", start: 1, end: 5)
            let navigation = TrackNavigation(hasNext: true, nextTitle: "Episode 2")
            session.openStream(
                url: URL(string: "https://example.com/a.mkv")!, title: "A", headers: ["Authorization": "Bearer t"],
                startTime: 12, audioTrack: "jpn", subtitleTrack: "off", actionButtons: [button],
                trackNavigation: navigation)
            let request = try #require(recorder.requests.first)
            #expect(request.path == "https://example.com/a.mkv")
            #expect(request.title == "A")
            #expect(request.headers == ["Authorization": "Bearer t"])
            #expect(request.startTime == 12)
            #expect(request.audioTrack == "jpn")
            #expect(request.subtitleTrack == "off")
            #expect(request.actionButtons == [button])
            #expect(request.trackNavigation == navigation)
        }

        @Test("A file URL given to openStream takes its access and releases it with the next network stream")
        func openStreamWithFileTakesAccess() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            session.openStream(url: URL(fileURLWithPath: "/files/a.mkv"))
            session.openStream(url: URL(string: "https://example.com/b.m3u8")!)
            #expect(recorder.events == ["start a.mkv", "load a.mkv", "load b.m3u8", "stop a.mkv"])
        }

        @Test("After end() nothing opens, no access is taken and onClose was reported once")
        func openAfterEnd() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            var closes = 0
            session.onClose = { _, _ in closes += 1 }
            session.open(URL(fileURLWithPath: "/files/a.mkv"))
            session.end()
            session.end()
            session.openStream(url: URL(fileURLWithPath: "/files/b.mkv"))
            session.load(MediaLoadRequest(path: "/files/c.mkv"))
            #expect(session.isEnded)
            #expect(closes == 1)
            #expect(recorder.events == ["start a.mkv", "load a.mkv", "stop a.mkv"])
        }

        @Test("close() (the X, the alert's Close) reports onClose once for opened media; the session opens again")
        func closeReportsOnce() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            var closes = 0
            session.onClose = { _, _ in closes += 1 }
            session.close()
            #expect(closes == 0, "Nothing was opened")
            session.openNetwork("https://example.com/a.m3u8")
            session.close()
            session.close()
            #expect(closes == 1)
            #expect(!session.isEnded)
            session.openNetwork("https://example.com/b.m3u8")
            #expect(recorder.events.filter { $0.hasPrefix("load") }.count == 2)
            session.close()
            #expect(closes == 2)
        }

        @Test("end() after close() reports onClose once; a file opened from onClose keeps its access")
        func closeThenEndAndReopenFromOnClose() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            var closes = 0
            session.onClose = { _, _ in closes += 1 }
            session.open(URL(fileURLWithPath: "/files/a.mkv"))
            session.close()
            session.end()
            #expect(closes == 1)

            let next = self.session(recorder: recorder)
            next.onClose = { [unowned next] _, _ in next.open(URL(fileURLWithPath: "/files/c.mkv")) }
            next.open(URL(fileURLWithPath: "/files/b.mkv"))
            next.close()
            #expect(!recorder.events.contains("stop c.mkv"), "The file the host opened stays accessible")
            #expect(recorder.events.contains("stop b.mkv"))
        }

        @Test("The same file written another way (with ..) keeps its access through load(_:)")
        func loadRecognisesTheSameFile() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            session.open(URL(fileURLWithPath: "/files/a.mkv"))
            session.load(MediaLoadRequest(path: "/files/sub/../a.mkv"))
            #expect(!recorder.events.contains("stop a.mkv"))
        }

        @Test("After end(): isEnded is observable state, and openNetwork says no")
        func endedSessionRefusesNetwork() {
            let session = session()
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = session.isEnded
            } onChange: {
                changed.withLock { $0 = true }
            }
            session.end()
            #expect(session.isEnded)
            #expect(changed.withLock { $0 }, "A view showing isEnded is redrawn")
            #expect(!session.openNetwork("https://example.com/a.m3u8"))
        }

        @Test("Opening from inside the onClose of end() loads nothing and takes no access")
        func openFromOnCloseOfEnd() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            session.onClose = { [unowned session] _, _ in
                session.open(URL(fileURLWithPath: "/files/next.mkv"))
            }
            session.end()
            #expect(recorder.events.isEmpty)
        }

        @Test("A load that fails, then the alert's Close, reports onClose exactly once")
        func failedLoadThenClose() {
            let session = TouchPlayerSession(engine: makeEngine())
            var closes = 0
            session.onClose = { _, _ in closes += 1 }
            session.open(URL(fileURLWithPath: "/nonexistent/never-opened.mkv"))
            #expect(!session.engine.isLoaded)
            session.close()
            #expect(closes == 1)
            session.close()
            #expect(closes == 1)
        }

        @Test("load(_:) of the held file's path keeps its access; of another path releases it")
        func loadKeepsOrReleasesAccess() {
            let recorder = Recorder()
            let session = session(recorder: recorder)
            session.open(URL(fileURLWithPath: "/files/a.mkv"))
            session.load(MediaLoadRequest(path: "/files/a.mkv", subtitleFiles: []))
            #expect(recorder.events == ["start a.mkv", "load a.mkv", "load a.mkv"])
            session.load(MediaLoadRequest(path: "/files/b.mkv"))
            #expect(recorder.events.last == "stop a.mkv")
            #expect(recorder.requests.count == 3)
        }

        @Test("The host's queue and buttons reach the engine through the session")
        func hostQueueForwards() {
            let session = session()
            session.onTrackNavigation = { _ in }
            session.setTrackNavigation(TrackNavigation(hasNext: true))
            #expect(session.engine.onTrackNavigation != nil)
            #expect(session.engine.trackNavigation.hasNext)
            session.onActionButton = { _ in }
            #expect(session.engine.actionButtons.onPress != nil)
        }
    }

    /// The count behind `UIApplication.isIdleTimerDisabled` (`heldCount > 0`): this process has no application to hold the
    /// flag, so the flag itself is for the app's own tests (Task 6).
    @Suite("Idle timer assertion")
    @MainActor
    struct IdleTimerTests {
        @Test("Two assertions held, one released: still held; both released: none")
        func idleTimerCountsAssertions() {
            let base = IdleTimerDisplaySleepAssertion.heldCount
            var first = IdleTimerDisplaySleepAssertion(reason: "first")
            var second = IdleTimerDisplaySleepAssertion(reason: "second")
            #expect(first != nil && second != nil)
            #expect(IdleTimerDisplaySleepAssertion.heldCount == base + 2)
            first = nil
            #expect(IdleTimerDisplaySleepAssertion.heldCount == base + 1, "One assertion is still held")
            second = nil
            #expect(IdleTimerDisplaySleepAssertion.heldCount == base)
        }
    }
#endif
