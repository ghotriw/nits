import AVFoundation
import Foundation
import Testing

@testable import NitsCore

/// A host that goes to the background (iOS) and comes back: the engine pauses and drops its decoder session, and the
/// picture returns to where it stood with an exact seek, staying paused until the user plays.
@Suite("Background and foreground", .serialized, .realtimePlayback, .hostDependent, .backstopTimeLimit)
@MainActor
struct BackgroundResumeTests {
    private static func load() async -> PlayerEngine? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return nil }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: path)
        guard await engine.waitForPlayback(advancingBy: 0.5) else {
            engine.stop()
            return nil
        }
        return engine
    }

    @Test("Back from the background the picture is where it stood, paused, and playing goes on from there")
    func foregroundResumesPictureAtSamePosition() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        _ = await engine.waitForPlayback(advancingBy: 1.0)
        let stood = engine.currentFramePTS

        engine.hostDidEnterBackground()
        #expect(!engine.isPlaying)
        try await Task.sleep(for: .seconds(2))
        let seekBefore = engine.seekGeneration.current
        engine.hostWillEnterForeground()
        // The picture comes back by a seek of its own (the decoder and the network start afresh from a keyframe).
        #expect(engine.seekGeneration.current != seekBefore)
        #expect(await engine.waitUntil(timeout: .seconds(3)) { !engine.isSeeking && engine.pendingSeekTime == nil })
        #expect(!engine.isPlaying, "Coming back does not play by itself")
        #expect(abs(engine.frameQueue.getLastRenderedPTS() - stood) <= 0.1)

        engine.play()
        // Past what the queue held decoded: from there on the decoder has to have its picture right.
        #expect(await engine.waitForPlayback(advancingBy: 3.0, timeout: .seconds(8)))
        #expect(engine.frameQueue.getLastRenderedPTS() > stood + 2.5, "Frames advance after play")
    }

    @Test("Going to the background drops the decoder's VideoToolbox session")
    func backgroundDropsDecoderSession() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        guard let session = engine.decoder as? VTVideoDecoder else { return }
        try #require(session.hasActiveSession)
        engine.hostDidEnterBackground()
        #expect(await engine.waitUntil(timeout: .seconds(3)) { !session.hasActiveSession })

        // And a second call, or a return without one, changes nothing.
        engine.hostDidEnterBackground()
        engine.hostWillEnterForeground()
        engine.hostWillEnterForeground()
        #expect(await engine.waitUntil(timeout: .seconds(3)) { !engine.isSeeking && engine.pendingSeekTime == nil })
        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 0.5, timeout: .seconds(3)))
        #expect(session.hasActiveSession, "The next decode made a fresh session")
    }

    @Test("A queue under a byte budget holds the frames the budget allows, or half a second, whichever is more")
    func queueStaysUnderBudget() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }

        // One frame's size, from a run without a budget.
        let probe = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        probe.load(path: path)
        guard await probe.waitForPlayback(advancingBy: 0.3) else {
            probe.stop()
            return
        }
        let frameBytes = probe.frameQueue.latestFrameBytes
        let frameRate = 1 / probe.nominalFrameDuration
        probe.stop()
        try #require(frameBytes > 0)

        let configuration = PlayerConfiguration(resumePlayback: false, frameQueueByteBudget: 8 * frameBytes)
        let engine = PlayerEngine.makeForTesting(configuration: configuration)
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 0.3))
        // Paused, the feeder fills the queue to its high water and waits.
        engine.pause()
        let limit = FrameQueueBudget.highWater(
            budgetBytes: 8 * frameBytes, frameBytes: frameBytes, frameRate: frameRate)
        #expect(limit.pause == max(8, Int((frameRate * 0.5).rounded(.up))))
        var highest = 0
        for _ in 0..<20 {
            highest = max(highest, engine.frameQueue.count)
            try await Task.sleep(for: .milliseconds(100))
        }
        // Frames still in the decoder when the feeder stops (reordering) may land after it.
        #expect(highest <= limit.pause + 4, "The queue held \(highest) frames; the high water is \(limit.pause)")
        #expect(highest < 25, "A budget keeps the queue well under today's 40 / 25")
    }
}

extension BackgroundResumeTests {
    @Test("A load that ends in the background ends paused on its first frame, and coming back seeks to it")
    func loadEndingInTheBackgroundStaysPaused() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }

        engine.load(path: path)
        engine.hostDidEnterBackground()
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.isLoaded })
        try await Task.sleep(for: .seconds(1))
        #expect(!engine.isPlaying, "A load must not start playing in the background")
        let clock = engine.playbackClock.currentTime().seconds
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.playbackClock.currentTime().seconds == clock, "The clock ran in the background")

        let seekBefore = engine.seekGeneration.current
        engine.hostWillEnterForeground()
        #expect(engine.seekGeneration.current != seekBefore, "Back from the background, the picture is sought afresh")
        #expect(await engine.waitUntil(timeout: .seconds(3)) { !engine.isSeeking && engine.pendingSeekTime == nil })
        #expect(!engine.isPlaying)
        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 1.0, timeout: .seconds(4)))
    }

    @Test("A load started in the background ends paused too")
    func loadStartedInTheBackgroundStaysPaused() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.hostDidEnterBackground()
        engine.load(path: path)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.isLoaded })
        try await Task.sleep(for: .seconds(1))
        #expect(!engine.isPlaying)
        engine.hostWillEnterForeground()
        #expect(await engine.waitUntil(timeout: .seconds(3)) { !engine.isSeeking && engine.pendingSeekTime == nil })
        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 1.0, timeout: .seconds(4)))
    }
}

extension BackgroundResumeTests {
    @Test("A display layer that requires a flush, or has failed, is flushed on coming back; a healthy one is not")
    func displayLayerNeedsFlushOnReturn() {
        #expect(PlayerEngine.displayLayerNeedsFlush(status: .failed, requiresFlush: true))
        #expect(PlayerEngine.displayLayerNeedsFlush(status: .failed, requiresFlush: false))
        #expect(PlayerEngine.displayLayerNeedsFlush(status: .rendering, requiresFlush: true))
        #expect(!PlayerEngine.displayLayerNeedsFlush(status: .rendering, requiresFlush: false))
        #expect(!PlayerEngine.displayLayerNeedsFlush(status: .unknown, requiresFlush: false))
    }

    @Test("Coming back logs the layer's state and leaves a healthy layer alone")
    func returnWithAHealthyLayer() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        _ = await engine.waitForPlayback(advancingBy: 0.5)
        engine.hostDidEnterBackground()
        engine.hostWillEnterForeground()
        #expect(await engine.waitUntil(timeout: .seconds(3)) { !engine.isSeeking && engine.pendingSeekTime == nil })
        #expect(!isDisplayLayerFailed(engine))
    }
}

@MainActor
private func isDisplayLayerFailed(_ engine: PlayerEngine) -> Bool {
    engine.sampleBufferRenderer.status == .failed
}
