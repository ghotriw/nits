import AVFoundation
import Foundation
import Testing

@testable import NitsCore

/// When the engine keeps the output running for a wait in the background (`BackgroundOutputHold`): iOS suspends an app
/// whose sound stopped, so buffering there must not let it go, for as long as `limit`.
@Suite("Background output hold")
@MainActor
struct BackgroundOutputHoldTests {
    @Test("Held once while waiting, let go when the wait ends")
    func holdsWhileWaiting() {
        let route = KeepRoute()
        let hold = BackgroundOutputHold()
        hold.update(waiting: true, route: route)
        hold.update(waiting: true, route: route)
        #expect(route.calls == [true])
        #expect(hold.isHolding)
        hold.update(waiting: false, route: route)
        hold.update(waiting: false, route: route)
        #expect(route.calls == [true, false])
        #expect(!hold.isHolding)
    }

    @Test("Past its limit the output is let go, and held again only for the next wait", .hostDependent)
    func limitEndsTheHold() async {
        let route = KeepRoute()
        let hold = BackgroundOutputHold(limit: .milliseconds(50))
        hold.update(waiting: true, route: route)
        // The limit's task runs on the main actor when it gets there: waited for, with room for a busy host.
        let deadline = ContinuousClock.now + .seconds(5)
        while hold.isHolding, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(route.calls == [true, false])
        // The same wait goes on: not held again.
        hold.update(waiting: true, route: route)
        #expect(route.calls == [true, false])
        // It ends, and another begins.
        hold.update(waiting: false, route: route)
        hold.update(waiting: true, route: route)
        #expect(route.calls == [true, false, true])
        hold.update(waiting: false, route: route)
    }

    @Test("The engine holds the output for buffering in the background only")
    func engineHoldsForBackgroundBuffering() {
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        let route = KeepRoute()
        engine.audioOutputRoute = route
        defer { engine.stop() }

        engine.isBuffering = true
        #expect(route.calls.isEmpty)
        engine.isBuffering = false

        engine.hostDidEnterBackground()
        engine.isBuffering = true
        #expect(route.calls == [true])
        engine.isBuffering = false
        #expect(route.calls == [true, false])

        // Buffering when the host leaves, and when it comes back.
        engine.hostWillEnterForeground()
        engine.isBuffering = true
        engine.hostDidEnterBackground()
        #expect(route.calls == [true, false, true])
        engine.hostWillEnterForeground()
        #expect(route.calls == [true, false, true, false])
        engine.isBuffering = false
    }
}

/// Records what the engine asks of `keepOutputRunning`.
@MainActor
private final class KeepRoute: AudioOutputRoute {
    var calls: [Bool] = []
    var reportsOutputRestarts: Bool { false }

    required init() {}

    func startMonitoring(
        binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
        onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void,
        onInterruption: @escaping @MainActor (_ began: Bool, _ shouldResume: Bool) -> Void,
        onRouteLost: @escaping @MainActor () -> Void
    ) {}
    func stopMonitoring() {}
    func activate(_ completion: @escaping @MainActor () -> Void) { completion() }
    func deactivate() {}
    func keepOutputRunning(_ keep: Bool) { calls.append(keep) }
    nonisolated static func currentOutputLatency() -> TimeInterval? { nil }
}
