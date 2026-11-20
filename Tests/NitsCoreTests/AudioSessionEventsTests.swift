import AVFoundation
import Foundation
import Testing

@testable import NitsCore

/// What the engine does when the system takes the audio away or hands it back (iOS: a call, Siri, an alarm, AirPods
/// out), and when the renderer is flushed by the system itself. The platform route only reports the events; the policy
/// is the engine's, so these call its handlers (and post the renderer's notification) on macOS.
@Suite("Audio session events", .serialized, .realtimePlayback, .backstopTimeLimit)
@MainActor
struct AudioSessionEventsTests {
    private static func load() async -> PlayerEngine? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .flashClick) else { return nil }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: path)
        guard await engine.waitForPlayback(advancingBy: 0.3) else {
            engine.stop()
            return nil
        }
        return engine
    }

    @Test("Losing the route (AirPods out) pauses")
    func routeLossPauses() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        #expect(engine.isPlaying)
        engine.handleAudioRouteLost()
        #expect(!engine.isPlaying)
    }

    @Test("Losing the route while paused leaves it paused")
    func routeLossWhilePaused() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.pause()
        engine.handleAudioRouteLost()
        #expect(!engine.isPlaying)
    }

    @Test("An interruption that ends with shouldResume resumes only what was playing")
    func interruptionResumesOnlyIfPlaying() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }

        // Paused before: stays paused.
        engine.pause()
        engine.handleAudioInterruption(began: true, shouldResume: false)
        engine.handleAudioInterruption(began: false, shouldResume: true)
        #expect(!engine.isPlaying)

        // Playing before: paused by the interruption, playing after it, and the audio advances.
        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 0.2))
        engine.handleAudioInterruption(began: true, shouldResume: false)
        #expect(!engine.isPlaying)
        engine.handleAudioInterruption(began: false, shouldResume: true)
        #expect(engine.isPlaying)
        #expect(await engine.waitForPlayback(advancingBy: 0.3))
        #expect(engine.audioSink.bufferedEnd != nil)
    }

    @Test("An interruption that ends without shouldResume stays paused")
    func interruptionWithoutShouldResume() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.handleAudioInterruption(began: true, shouldResume: false)
        engine.handleAudioInterruption(began: false, shouldResume: false)
        #expect(!engine.isPlaying)
    }

    @Test("What a user paused during the interruption is not resumed by its end")
    func pausedByUserDuringInterruption() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.handleAudioInterruption(began: true, shouldResume: false)
        engine.play()
        engine.pause()
        engine.handleAudioInterruption(began: false, shouldResume: true)
        #expect(!engine.isPlaying)
    }

    @Test("A flush the system made is answered by feeding the audio again from the clock, which never stops")
    func automaticFlushRefeedsAudio() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        let renderer = engine.audioRenderer
        let clock = engine.playbackClock
        let before = clock.currentTime().seconds

        engine.firstFedAudioPTS.withLock { $0 = nil }
        // The Mac's own output may flush the renderer too while the test runs: counted from here, at least ours.
        let flushes = engine.automaticAudioFlushCount
        renderer.flush()
        NotificationCenter.default.post(
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
            userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: clock.currentTime())])
        #expect(await engine.waitUntil(timeout: .seconds(1)) { engine.automaticAudioFlushCount >= flushes + 1 })

        // Audio again within a second, from where the clock is (not from where the feeder had got to).
        // The run restarts (its first buffer sets `firstFedAudioPTS`), and it starts with audio the clock has not played.
        #expect(await engine.waitUntil(timeout: .seconds(1)) { engine.firstFedAudioPTS.withLock { $0 } != nil })
        let firstFed = try #require(engine.firstFedAudioPTS.withLock { $0 }?.seconds)
        #expect(firstFed <= clock.currentTime().seconds)
        #expect(
            await engine.waitUntil(timeout: .seconds(1)) {
                guard let end = engine.audioSink.bufferedEnd, end.isNumeric else { return false }
                return end > clock.currentTime()
            })

        // The clock ran on through it.
        #expect(clock.readRate == 1)
        #expect(clock.currentTime().seconds > before)
        #expect(engine.isPlaying)
    }
}

/// Counts what the engine asks of its route; stands in for the platform's.
@MainActor
private final class CountingRoute: AudioOutputRoute {
    var activations = 0
    var deactivations = 0
    /// What the route says of itself: a route without the report (iOS) leaves the re-anchor after a change of output to the engine.
    var reportsOutputRestarts = false

    required init() {}

    func startMonitoring(
        binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
        onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void,
        onInterruption: @escaping @MainActor (_ began: Bool, _ shouldResume: Bool) -> Void,
        onRouteLost: @escaping @MainActor () -> Void
    ) {}

    func stopMonitoring() {}
    func activate(_ completion: @escaping @MainActor () -> Void) {
        activations += 1
        completion()
    }
    func deactivate() { deactivations += 1 }
    nonisolated static func currentOutputLatency() -> TimeInterval? { nil }
}

extension AudioSessionEventsTests {
    @Test("The session is taken when playback starts and given back by stop(), not when the engine is made")
    func sessionFollowsPlayback() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .flashClick) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        let route = CountingRoute()
        engine.audioOutputRoute = route
        defer { engine.stop() }
        #expect(route.activations == 0)
        #expect(route.deactivations == 0)

        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        #expect(route.activations == 1)
        #expect(route.deactivations == 0)

        // Pausing keeps the output: other audio must not start under a paused video.
        engine.pause()
        #expect(route.deactivations == 0)

        engine.stop()
        #expect(route.deactivations == 1)
    }

    @Test("A second interruption before the first ends still resumes what played before the first")
    func twoInterruptionsInARow() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.handleAudioInterruption(began: true, shouldResume: false)  // the call
        engine.handleAudioInterruption(began: true, shouldResume: false)  // Siri during it
        #expect(!engine.isPlaying)
        engine.handleAudioInterruption(began: false, shouldResume: true)
        #expect(engine.isPlaying)
    }

    @Test("A flush by the system followed by the device restarting its IO feeds the audio on, the clock running")
    func flushThenOutputRestart() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        let renderer = engine.audioRenderer
        let clock = engine.playbackClock
        let before = clock.currentTime().seconds
        let recoveriesBefore = engine.audioOutputInterruptionLock.withLock { $0.recoveries }

        // AirPods connecting: the system flushes the renderer, then the device stops its IO after running a while and
        // starts it again (`AudioOutputInterruptionDetector`).
        engine.firstFedAudioPTS.withLock { $0 = nil }
        // The Mac's own output may flush the renderer too while the test runs: counted from here, at least ours.
        let flushes = engine.automaticAudioFlushCount
        renderer.flush()
        NotificationCenter.default.post(
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
            userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: clock.currentTime())])
        #expect(await engine.waitUntil(timeout: .seconds(1)) { engine.automaticAudioFlushCount >= flushes + 1 })
        // The feeding run's start flushes the renderer through the sink (`rendererFlushed`): the device's events come after it.
        #expect(await engine.waitUntil(timeout: .seconds(1)) { engine.firstFedAudioPTS.withLock { $0 } != nil })
        engine.audioOutputRunningChanged(true)
        try await Task.sleep(for: .milliseconds(80))
        engine.audioOutputRunningChanged(false)
        engine.audioOutputRunningChanged(true)

        // The second path ran too (a real device event of the Mac may add its own).
        #expect(
            await engine.waitUntil(timeout: .seconds(2)) {
                engine.audioOutputInterruptionLock.withLock { $0.recoveries } >= recoveriesBefore + 1
            })
        // And the sound is on: fed again, ahead of the clock, not stopped, and no piece of it twice (the end of what is
        // fed only moves on).
        #expect(await engine.waitForPlayback(advancingBy: 0.5))
        var lastEnd = -Double.infinity
        for _ in 0..<10 {
            if let end = engine.audioSink.bufferedEnd, end.isNumeric {
                #expect(end.seconds >= lastEnd)
                lastEnd = end.seconds
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(lastEnd > clock.currentTime().seconds)
        #expect(engine.isPlaying)
        #expect(clock.readRate == 1)
        #expect(clock.currentTime().seconds > before + 1)
        #expect(engine.automaticAudioFlushCount >= flushes + 1)
    }
}

extension AudioSessionEventsTests {
    @Test("The session is given back when the media ends, and taken again by the next play")
    func sessionEndsWithTheMedia() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .flashClick) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        let route = CountingRoute()
        engine.audioOutputRoute = route
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        #expect(route.activations == 1)

        engine.seek(to: engine.media.duration - 1.5)
        #expect(await engine.waitUntil(timeout: .seconds(8)) { engine.playbackState == .completed })
        #expect(route.deactivations == 1, "Other apps' audio can go on once the media has ended")

        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 0.3, timeout: .seconds(4)))
        #expect(route.activations == 2)
    }
}

/// A route whose session takes its time: `activate` calls back only when the test says so.
@MainActor
private final class SlowRoute: AudioOutputRoute {
    var pending: [@MainActor () -> Void] = []
    var reportsOutputRestarts = false

    required init() {}

    func startMonitoring(
        binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
        onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void,
        onInterruption: @escaping @MainActor (_ began: Bool, _ shouldResume: Bool) -> Void,
        onRouteLost: @escaping @MainActor () -> Void
    ) {}

    func stopMonitoring() {}
    func activate(_ completion: @escaping @MainActor () -> Void) { pending.append(completion) }
    func deactivate() {}
    nonisolated static func currentOutputLatency() -> TimeInterval? { nil }
}

extension AudioSessionEventsTests {
    @Test("The clock does not start before the audio session is active, and starts when it is")
    func clockWaitsForTheSession() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .flashClick) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        let route = SlowRoute()
        engine.audioOutputRoute = route
        defer { engine.stop() }

        engine.load(path: path)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { !route.pending.isEmpty })
        // Played, as far as the engine is concerned, but the clock stands: the output is not ready. (Shorter than the
        // preroll's own timeout, which starts it anyway.)
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.isPlaying)
        #expect(engine.playbackClock.rate == 0, "The clock ran before the session was active")

        for completion in route.pending { completion() }
        // Started by the completion, not by the preroll's own timeout a second after the start.
        #expect(await engine.waitUntil(timeout: .milliseconds(500)) { engine.playbackClock.rate > 0 })
        #expect(await engine.waitForPlayback(advancingBy: 0.3, timeout: .seconds(4)))
    }
}

extension AudioSessionEventsTests {
    @Test(
        "A change of output on a route that does not report restarts is followed by a re-anchor: sound on, clock running"
    )
    func routeChangeReanchorsWithoutRestartReport() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .flashClick) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        let route = CountingRoute()
        route.reportsOutputRestarts = false
        engine.audioOutputRoute = route
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.5))
        let clock = engine.playbackClock
        let before = clock.currentTime().seconds
        engine.firstFedAudioPTS.withLock { $0 = nil }

        engine.handleAudioOutputRouteChange()
        #expect(await engine.waitUntil(timeout: .seconds(2)) { engine.audioRouteReanchors == 1 })
        // The audio is fed again after the flush, ahead of the clock, and the clock runs on.
        #expect(await engine.waitUntil(timeout: .seconds(2)) { engine.firstFedAudioPTS.withLock { $0 } != nil })
        #expect(
            await engine.waitUntil(timeout: .seconds(2)) {
                guard let end = engine.audioSink.bufferedEnd, end.isNumeric else { return false }
                return end > clock.currentTime()
            })
        #expect(await engine.waitForPlayback(advancingBy: 0.5, timeout: .seconds(3)))
        #expect(engine.isPlaying)
        #expect(clock.readRate == 1)
        #expect(clock.currentTime().seconds > before + 0.5)
    }

    @Test("A route that reports restarts (macOS) is left to its detector: no re-anchor of the engine's own")
    func routeChangeWithRestartReportIsUnchanged() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.handleAudioOutputRouteChange()
        try await Task.sleep(for: PlayerEngine.routeChangeSettleTime + .milliseconds(500))
        #expect(engine.audioRouteReanchors == 0)
        #expect(engine.isPlaying)
    }

    @Test("A pause before the settle time ends cancels the re-anchor")
    func pauseCancelsRouteChangeReanchor() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        let route = CountingRoute()
        route.reportsOutputRestarts = false
        engine.audioOutputRoute = route
        engine.handleAudioOutputRouteChange()
        engine.pause()
        try await Task.sleep(for: PlayerEngine.routeChangeSettleTime + .milliseconds(500))
        #expect(engine.audioRouteReanchors == 0)
        #expect(!engine.isPlaying)
    }
}
