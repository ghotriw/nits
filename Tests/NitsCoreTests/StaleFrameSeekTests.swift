import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// Decodes through a real decoder, but holds one `decode` call of the video feeder when armed, as a decode that is still
/// in flight when a seek comes. The call goes on to decode its (old) packet once released: by the first
/// `waitForPendingFrames()` (a seek preview's wait for its own frames), or after `releaseAfter`. That wait then waits
/// for the old packet to have been handed to the decoder, so its frame is always among the ones the preview collects.
final class LateDecodeVideoDecoder: VideoDecoderProtocol, @unchecked Sendable {
    private let wrapped: any VideoDecoderProtocol
    private let releaseAfter: DispatchTimeInterval
    private let state = OSAllocatedUnfairLock(initialState: (isArmed: false, isHolding: false, isReleased: false))
    private let gate = DispatchSemaphore(value: 0)
    /// Signalled once the held call has handed its packet to the wrapped decoder.
    private let handedOver = DispatchSemaphore(value: 0)

    init(wrapping wrapped: any VideoDecoderProtocol, releaseAfter: DispatchTimeInterval = .milliseconds(400)) {
        self.wrapped = wrapped
        self.releaseAfter = releaseAfter
    }

    /// The next `decode` call is held.
    func arm() { state.withLock { $0.isArmed = true } }

    /// A `decode` call is held now.
    var isHolding: Bool { state.withLock { $0.isHolding } }

    private func release() {
        let wasHolding = state.withLock { state -> Bool in
            guard state.isHolding, !state.isReleased else { return false }
            state.isReleased = true
            return true
        }
        if wasHolding { gate.signal() }
    }

    func setOutputHandler(_ handler: @escaping OutputHandler) { wrapped.setOutputHandler(handler) }

    func decode(sampleBuffer: CMSampleBuffer) {
        let mustHold = state.withLock { state -> Bool in
            guard state.isArmed else { return false }
            state.isArmed = false
            state.isHolding = true
            return true
        }
        if mustHold { _ = gate.wait(timeout: .now() + releaseAfter) }
        wrapped.decode(sampleBuffer: sampleBuffer)
        if mustHold { handedOver.signal() }
    }

    func flush() { wrapped.flush() }

    func waitForPendingFrames() {
        // The held decode goes on while the caller waits: its frame comes out to whichever handler is set by then.
        if state.withLock({ $0.isHolding && !$0.isReleased }) {
            release()
            // Bounded, in case the held call never gets to the decoder.
            _ = handedOver.wait(timeout: .now() + .seconds(2))
        }
        wrapped.waitForPendingFrames()
    }

    func drain() { wrapped.drain() }
    func resetSession() { wrapped.resetSession() }
    func setDiscardNonReferenceFrames(_ discard: Bool) { wrapped.setDiscardNonReferenceFrames(discard) }
}

/// A seek superseding a run whose video feeder is inside a decode must not show that decode's frame: the picture, and the
/// clock that starts from it, would be at the old position while the demuxer and the queue are at the landing.
@Suite("Stale frame after a seek", .serialized, .realtimePlayback, .hostDependent)
@MainActor
struct StaleFrameSeekTests {
    @Test("A forward keyframe seek lands at or after its target when the feeder's decode of an old packet is in flight")
    func landsAtTheTarget() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: path)
        #expect(await engine.waitForPlayback())
        engine.pause()
        let late = LateDecodeVideoDecoder(wrapping: engine.decoder)
        engine.installVideoDecoder(late)
        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 0.3), "Playback did not run through the wrapper")

        late.arm()
        #expect(await engine.waitUntil(timeout: .seconds(5)) { late.isHolding }, "The feeder never held a decode")
        let playedAt = engine.currentFramePTS
        // Keyframes every 5 s: a forward seek well past the position lands on the keyframe at or after the target.
        let target = (playedAt / 5).rounded(.down) * 5 + 15.5
        guard target < engine.media.duration - 6 else { return }
        engine.seek(to: target, exact: false, forward: true)
        #expect(await engine.waitForSeekToSettle(), "The seek did not settle")

        #expect(
            engine.currentTime >= target - 0.01,
            "Landed at \(engine.currentTime)s for a forward seek to \(target)s, the frame of the decode in flight (at ~\(playedAt)s) won"
        )
        // And the picture runs from there.
        #expect(await engine.waitForPlayback(advancingBy: 0.3), "Playback did not run after the seek")
        #expect(abs(engine.currentFramePTS - engine.playbackClock.currentTime().seconds) < 2)
    }
}
