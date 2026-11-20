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
        renderer.flush()
        NotificationCenter.default.post(
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
            userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: clock.currentTime())])
        #expect(await engine.waitUntil(timeout: .seconds(1)) { engine.automaticAudioFlushCount == 1 })

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

    required init() {}

    func startMonitoring(
        binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
        onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void,
        onInterruption: @escaping @MainActor (_ began: Bool, _ shouldResume: Bool) -> Void,
        onRouteLost: @escaping @MainActor () -> Void
    ) {}

    func stopMonitoring() {}
    func activate() { activations += 1 }
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
        renderer.flush()
        NotificationCenter.default.post(
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
            userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: clock.currentTime())])
        #expect(await engine.waitUntil(timeout: .seconds(1)) { engine.automaticAudioFlushCount == 1 })
        // The feeding run's start flushes the renderer through the sink (`rendererFlushed`): the device's events come after it.
        #expect(await engine.waitUntil(timeout: .seconds(1)) { engine.firstFedAudioPTS.withLock { $0 } != nil })
        engine.audioOutputRunningChanged(true)
        try await Task.sleep(for: .milliseconds(80))
        engine.audioOutputRunningChanged(false)
        engine.audioOutputRunningChanged(true)

        // The second path ran too, once.
        #expect(
            await engine.waitUntil(timeout: .seconds(2)) {
                engine.audioOutputInterruptionLock.withLock { $0.recoveries } == recoveriesBefore + 1
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
        #expect(engine.automaticAudioFlushCount == 1)
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
