#if os(iOS)
    import NitsCore
    import SwiftUI
    import Testing

    @testable import NitsCore
    @testable import NitsTouch

    @MainActor
    private final class Recorder {
        var events: [String] = []
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
        func hostDidEnterBackground() { calls.append("background") }
        func hostWillEnterForeground() { calls.append("foreground") }
    }

    @Suite("Touch player session")
    @MainActor
    struct TouchPlayerSessionTests {
        private func session(
            recorder: Recorder = Recorder(), hooks: FakeHooks = FakeHooks()
        ) -> TouchPlayerSession {
            TouchPlayerSession(
                access: FakeAccess(recorder: recorder), hooks: hooks,
                load: { [recorder] path in recorder.events.append("load \((path as NSString).lastPathComponent)") })
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
