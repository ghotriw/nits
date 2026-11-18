import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// Passes calls through to a real decoder, holding each `decode` a few milliseconds (as a hardware decode can) and
/// recording how many ran at once.
final class OverlapCountingVideoDecoder: VideoDecoderProtocol, @unchecked Sendable {
    private let wrapped: any VideoDecoderProtocol
    private let state = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, calls: 0))

    init(wrapping wrapped: any VideoDecoderProtocol) {
        self.wrapped = wrapped
    }

    var maximumConcurrentDecodes: Int { state.withLock { $0.maximum } }
    var decodeCalls: Int { state.withLock { $0.calls } }

    func setOutputHandler(_ handler: @escaping OutputHandler) { wrapped.setOutputHandler(handler) }

    func decode(sampleBuffer: CMSampleBuffer) {
        state.withLock { state in
            state.active += 1
            state.calls += 1
            state.maximum = max(state.maximum, state.active)
        }
        defer { state.withLock { $0.active -= 1 } }
        Thread.sleep(forTimeInterval: 0.004)
        wrapped.decode(sampleBuffer: sampleBuffer)
    }

    func flush() { wrapped.flush() }
    func waitForPendingFrames() { wrapped.waitForPendingFrames() }
    func drain() { wrapped.drain() }
    func resetSession() { wrapped.resetSession() }
}

@Suite("Video feeder", .serialized, .realtimePlayback, .backstopTimeLimit)
@MainActor
struct VideoFeederOverlapTests {
    /// The feeder pauses at a full frame queue and goes on once it has drained; going on must not start a second
    /// feeder beside the first, whose decode would then run at the same time as the new one's on the same session
    /// (a VideoToolbox session hung in `VTDecompressionSessionDecodeFrame` that way).
    @Test("Resuming after backpressure never runs two decodes at once")
    func backpressureResumeKeepsOneFeeder() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        #expect(await engine.waitForPlayback())

        engine.pause()
        let counting = OverlapCountingVideoDecoder(wrapping: engine.decoder)
        engine.installVideoDecoder(counting)
        // A faster rate drains the queue sooner, so the feeder pauses and goes on more often.
        engine.setPlaybackRate(2.0)
        engine.play()
        // A busy main thread (an app's UI) delays whatever the engine sends it: a resume handed to it then lands while
        // the paused feeder has already gone on by itself.
        let start = engine.currentFramePTS
        let deadline = ContinuousClock.now + .seconds(10)
        while engine.currentFramePTS < start + 3.0, ContinuousClock.now < deadline {
            Self.blockMainThread(for: 0.02)
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.currentFramePTS >= start + 3.0, "Playback did not run through the wrapper")

        #expect(counting.decodeCalls > 60, "Too few decodes (\(counting.decodeCalls)) to cross the threshold")
        #expect(
            counting.maximumConcurrentDecodes == 1,
            "\(counting.maximumConcurrentDecodes) decodes ran at once")
        engine.stop()
    }

    private nonisolated static func blockMainThread(for seconds: TimeInterval) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}
