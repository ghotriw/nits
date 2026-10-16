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
}
