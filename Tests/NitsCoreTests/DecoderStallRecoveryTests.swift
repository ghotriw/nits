import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// Decodes through a real decoder until `stall()`; from then on every call blocks, as a VideoToolbox session does
/// once its decoder service stops answering. `release()` lets the blocked callers return when the test ends.
final class StallingVideoDecoder: VideoDecoderProtocol, @unchecked Sendable {
    private let wrapped: any VideoDecoderProtocol
    private let state = OSAllocatedUnfairLock(initialState: (isStalled: false, isReleased: false, otherCalls: 0))
    private let gate = DispatchSemaphore(value: 0)

    init(wrapping wrapped: any VideoDecoderProtocol) {
        self.wrapped = wrapped
    }

    /// Calls other than `decode` made after the stall: the engine must not touch a stalled decoder.
    var callsAfterStall: Int { state.withLock { $0.otherCalls } }

    func stall() {
        state.withLock { $0.isStalled = true }
    }

    func release() {
        state.withLock { $0.isReleased = true }
        for _ in 0..<64 { gate.signal() }
    }

    /// Blocks the caller while stalled; returns whether it did.
    private func blockIfStalled(countingCall: Bool) -> Bool {
        let mustBlock = state.withLock { state -> Bool in
            guard state.isStalled else { return false }
            if countingCall { state.otherCalls += 1 }
            return !state.isReleased
        }
        if mustBlock { gate.wait() }
        return state.withLock { $0.isStalled }
    }

    func setOutputHandler(_ handler: @escaping OutputHandler) { wrapped.setOutputHandler(handler) }

    func decode(sampleBuffer: CMSampleBuffer) {
        if blockIfStalled(countingCall: false) { return }
        wrapped.decode(sampleBuffer: sampleBuffer)
    }

    func flush() {
        if blockIfStalled(countingCall: true) { return }
        wrapped.flush()
    }

    func waitForPendingFrames() {
        if blockIfStalled(countingCall: true) { return }
        wrapped.waitForPendingFrames()
    }

    func drain() {
        if blockIfStalled(countingCall: true) { return }
        wrapped.drain()
    }

    func resetSession() {
        if blockIfStalled(countingCall: true) { return }
        wrapped.resetSession()
    }
}

@Suite("Stalled video decoder recovery", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct DecoderStallRecoveryTests {
    /// Swaps in a decoder that stalls on demand while playback runs, so the feeder decodes through it.
    private func installStallingDecoder(in engine: PlayerEngine) async -> StallingVideoDecoder {
        engine.pause()
        let stalling = StallingVideoDecoder(wrapping: engine.decoder)
        engine.installVideoDecoder(stalling)
        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 0.3), "Playback did not run through the wrapper")
        return stalling
    }

    @Test("A decoder whose decode call never returns is replaced and playback continues from the last frame")
    func stalledDecoderIsReplaced() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        #expect(await engine.waitForPlayback())

        let stalling = await installStallingDecoder(in: engine)
        defer { stalling.release() }
        stalling.stall()

        // The display link plays out the frames already queued, then holds the last one; the stall timeout runs
        // from the decode call that blocked, so video freezes before the decoder is replaced.
        #expect(await engine.waitUntil { engine.frameQueue.count == 0 }, "Queued frames did not play out")
        let frozenAt = engine.currentFramePTS
        #expect(engine.decoder === stalling, "Replaced before the stall timeout")

        // Detection takes the stall timeout plus up to one check interval; the replacement then re-seeks.
        #expect(
            await engine.waitUntil(timeout: .seconds(15)) { engine.decoder !== stalling },
            "The stalled decoder was not replaced")
        let clockAtRecovery = engine.synchronizer.currentTime().seconds
        #expect(
            clockAtRecovery > frozenAt + 1,
            "The stall did not freeze video (frame \(frozenAt)s, clock \(clockAtRecovery)s)")

        // Resumes where video stopped, not where the clock ran on to during the stall timeout.
        #expect(await engine.waitForSeekToSettle())
        #expect(
            abs(engine.currentFramePTS - frozenAt) < 0.5,
            "Resumed at \(engine.currentFramePTS)s, video had stopped at \(frozenAt)s")
        #expect(
            await engine.waitUntil { engine.currentFramePTS > frozenAt + 1.0 && engine.isPlaying },
            "Video did not continue after the replacement (presented \(engine.currentFramePTS)s, stopped at \(frozenAt)s)"
        )
        #expect(engine.decoderStallRecoveries == 1)
        #expect(stalling.callsAfterStall == 0, "The engine called into the stalled decoder")

        engine.stop()
    }

    @Test("A second stall on the same media switches it to software decoding")
    func secondStallFallsBackToSoftware() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        #expect(await engine.waitForPlayback())

        for round in 1...2 {
            let stalling = await installStallingDecoder(in: engine)
            defer { stalling.release() }
            stalling.stall()
            #expect(
                await engine.waitUntil(timeout: .seconds(15)) { engine.decoder !== stalling },
                "Stall \(round): the stalled decoder was not replaced")
            #expect(await engine.waitForPlayback(), "Stall \(round): playback did not resume")
        }
        #expect(engine.decoderStallRecoveries == 2)
        #expect(engine.decoder is FFmpegVideoDecoder, "Expected a software decoder, got \(type(of: engine.decoder))")

        engine.stop()
    }

    @Test("A decoder that stalls inside a paused seek is replaced and the seek still lands")
    func stallDuringPausedSeek() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        #expect(await engine.waitForPlayback())
        engine.pause()
        #expect(await engine.waitUntil { !engine.isPlaying && !engine.isSeeking && engine.pendingSeekTime == nil })

        let stalling = StallingVideoDecoder(wrapping: engine.decoder)
        engine.installVideoDecoder(stalling)
        defer { stalling.release() }
        stalling.stall()

        // The seek's first decoder call (the flush) blocks; without the guard the serial seek queue would be held
        // for good and this seek, and every later one, would never settle.
        engine.seek(to: 12, exact: true)
        #expect(
            await engine.waitUntil(timeout: .seconds(15)) { engine.decoder !== stalling },
            "The decoder stalled in the seek was not replaced")
        #expect(await engine.waitForSeekToSettle(), "The seek did not settle after the replacement")
        #expect(abs(engine.currentFramePTS - 12) < 0.1, "Landed at \(engine.currentFramePTS)s instead of 12s")
        #expect(!engine.isPlaying)

        // The seek queue is free again.
        engine.seek(to: 5, exact: true)
        #expect(await engine.waitForSeekToSettle())
        #expect(abs(engine.currentFramePTS - 5) < 0.1, "Landed at \(engine.currentFramePTS)s instead of 5s")
        #expect(engine.decoderStallRecoveries == 1)

        engine.stop()
    }

    @Test("A decoder that stalls inside a seek during playback is replaced and playback resumes at the target")
    func stallDuringPlayingSeek() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        #expect(await engine.waitForPlayback())

        let stalling = await installStallingDecoder(in: engine)
        defer { stalling.release() }
        stalling.stall()
        engine.seek(to: 15, exact: true)

        #expect(
            await engine.waitUntil(timeout: .seconds(15)) { engine.decoder !== stalling },
            "The decoder stalled in the seek was not replaced")
        #expect(await engine.waitForPlayback(), "Playback did not resume after the replacement")
        #expect(
            engine.currentFramePTS >= 15 && engine.currentFramePTS < 18,
            "Resumed at \(engine.currentFramePTS)s, expected just past 15s")

        engine.stop()
    }
}

@Suite("StallGuardedVideoDecoder")
struct StallGuardedVideoDecoderTests {
    /// Counts calls; `decode` blocks while `blocking` is set, until `release()`.
    private final class BlockingDecoder: VideoDecoderProtocol, @unchecked Sendable {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let blocking = OSAllocatedUnfairLock(initialState: false)
        let handler = OSAllocatedUnfairLock<OutputHandler?>(initialState: nil)
        private let gate = DispatchSemaphore(value: 0)

        func release() { gate.signal() }
        func setOutputHandler(_ handler: @escaping OutputHandler) { self.handler.withLock { $0 = handler } }
        func decode(sampleBuffer: CMSampleBuffer) {
            calls.withLock { $0 += 1 }
            if blocking.withLock({ $0 }) { gate.wait() }
        }
        func flush() { calls.withLock { $0 += 1 } }
        func waitForPendingFrames() { calls.withLock { $0 += 1 } }
        func drain() {}
        func resetSession() {}
    }

    private func makeSample() throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        return try #require(sample)
    }

    @Test("Calls pass through until one overruns; then the decoder is silenced and reported once")
    func overrunMarksStalled() throws {
        let inner = BlockingDecoder()
        let stalls = LockIsolated(0)
        let guarded = StallGuardedVideoDecoder(wrapping: inner, timeout: .milliseconds(200)) { _ in
            stalls.withValue { $0 += 1 }
        }
        defer { inner.release() }
        let sample = try makeSample()

        guarded.setOutputHandler { _ in }
        guarded.decode(sampleBuffer: sample)
        guarded.waitForPendingFrames()
        #expect(inner.calls.withLock { $0 } == 2)
        #expect(!guarded.isStalled)

        inner.blocking.withLock { $0 = true }
        let started = ContinuousClock.now
        guarded.decode(sampleBuffer: sample)
        #expect(ContinuousClock.now - started < .seconds(2), "The overrunning call held the caller")
        #expect(guarded.isStalled)
        #expect(stalls.value == 1)

        // Later calls return at once without reaching the stalled decoder, and output stays silenced.
        guarded.flush()
        guarded.decode(sampleBuffer: sample)
        #expect(inner.calls.withLock { $0 } == 3)
        #expect(stalls.value == 1)
        let delivered = LockIsolated(false)
        guarded.setOutputHandler { _ in delivered.withValue { $0 = true } }
        let silenced = try #require(inner.handler.withLock { $0 })
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        silenced(DecodedFrame(pixelBuffer: try #require(pixelBuffer), pts: .zero, duration: .invalid))
        #expect(!delivered.value)
    }
}
