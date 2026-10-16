@preconcurrency import CoreMedia
import Foundation
import os

/// Runs a decoder's blocking calls with a time limit, for callers that must not hang with it: the seek queue is
/// serial, so one call that never returns (a VideoToolbox session whose decoder service stopped answering) would
/// hold every later seek, frame step and load behind it.
///
/// Each call runs on this wrapper's own queue while the caller waits up to `timeout`. A call that overruns marks
/// the decoder stalled: its output is silenced, every later call returns at once, and `onStall` reports it. The
/// stalled call keeps its thread; nothing else can be done with it, since even flushing a VideoToolbox session
/// starts by waiting for the service. Non-blocking setters are forwarded directly.
final class StallGuardedVideoDecoder: VideoDecoderProtocol, @unchecked Sendable {
    let wrapped: any VideoDecoderProtocol
    private let timeout: Duration
    private let onStall: @Sendable (_ blockedFor: Duration) -> Void
    private let callQueue = DispatchQueue(label: "com.nits.decoder-call", qos: .userInteractive)
    private let stalled = OSAllocatedUnfairLock(initialState: false)

    init(
        wrapping wrapped: any VideoDecoderProtocol, timeout: Duration,
        onStall: @escaping @Sendable (_ blockedFor: Duration) -> Void
    ) {
        self.wrapped = wrapped
        self.timeout = timeout
        self.onStall = onStall
    }

    var isStalled: Bool { stalled.withLock { $0 } }

    private func callWithTimeout(_ body: @escaping @Sendable () -> Void) {
        guard !isStalled else { return }
        let done = DispatchSemaphore(value: 0)
        let startedAt = ContinuousClock.now
        callQueue.async {
            body()
            done.signal()
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) * 1e-18
        guard done.wait(timeout: .now() + seconds) == .timedOut else { return }
        stalled.withLock { $0 = true }
        // Frames the session might still emit must not reach the queue or step cache a replacement fills.
        wrapped.setOutputHandler { _ in }
        onStall(ContinuousClock.now - startedAt)
    }

    func setOutputHandler(_ handler: @escaping OutputHandler) {
        if isStalled {
            wrapped.setOutputHandler { _ in }
        } else {
            wrapped.setOutputHandler(handler)
        }
    }

    func decode(sampleBuffer: CMSampleBuffer) {
        let wrapped = self.wrapped
        nonisolated(unsafe) let sample = sampleBuffer
        callWithTimeout { wrapped.decode(sampleBuffer: sample) }
    }

    func flush() {
        let wrapped = self.wrapped
        callWithTimeout { wrapped.flush() }
    }

    func waitForPendingFrames() {
        let wrapped = self.wrapped
        callWithTimeout { wrapped.waitForPendingFrames() }
    }

    func drain() {
        let wrapped = self.wrapped
        callWithTimeout { wrapped.drain() }
    }

    func resetSession() {
        let wrapped = self.wrapped
        callWithTimeout { wrapped.resetSession() }
    }

    func setDiscardNonReferenceFrames(_ discard: Bool) {
        wrapped.setDiscardNonReferenceFrames(discard)
    }

    var outputsFieldRate: Bool { wrapped.outputsFieldRate }

    func setDeinterlaceMode(_ mode: DeinterlaceMode) {
        wrapped.setDeinterlaceMode(mode)
    }
}
