import AVFoundation
import CoreMedia
import os

/// Feeds decoded audio to the `AVSampleBufferAudioRenderer` attached to the master-clock synchronizer.
///
/// Both implementations share one contract: `enqueue` suspends while the renderer applies backpressure
/// and throws `CancellationError` if the task is cancelled before the buffer is accepted, so the caller
/// keeps it pending (gapless pause/resume).
protocol AudioRendererSink: Sendable {
    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws
    func flush()
}

/// Attaches `renderer` to `synchronizer` and returns the sink matching the running OS.
func makeAudioRendererSink(
    renderer: AVSampleBufferAudioRenderer,
    synchronizer: AVSampleBufferRenderSynchronizer
) -> any AudioRendererSink {
    if #available(macOS 27.0, *) {
        return ReceiverAudioSink(receiver: synchronizer.sampleBufferReceiver(adding: renderer))
    }
    synchronizer.addRenderer(renderer)
    return LegacyAudioSink(renderer: renderer)
}

/// macOS 27+: the synchronizer's `Receiver`, which provides backpressure through `await enqueue`.
/// `@unchecked`: AVFoundation does not mark `Receiver` `Sendable`, but it is built for use from the feeding task.
@available(macOS 27.0, *)
private final class ReceiverAudioSink: AudioRendererSink, @unchecked Sendable {
    private let receiver: AVSampleBufferAudioRenderer.Receiver

    init(receiver: AVSampleBufferAudioRenderer.Receiver) {
        self.receiver = receiver
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws {
        nonisolated(unsafe) let sBuf = sampleBuffer
        let ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent> = CMReadySampleBuffer(unsafeBuffer: sBuf)
        _ = try await receiver.enqueue(ready)
    }

    func flush() {
        receiver.flush()
    }
}

/// macOS 15–26: direct `enqueue(_:)`, waiting cooperatively on `isReadyForMoreMediaData`.
/// `@unchecked`: `AVSampleBufferAudioRenderer` enqueue/flush/readiness are thread-safe, but not marked `Sendable`.
private final class LegacyAudioSink: AudioRendererSink, @unchecked Sendable {
    /// Polling interval while the renderer is not ready; well below the duration of one audio buffer.
    private static let readinessPollInterval: Duration = .milliseconds(5)

    private let renderer: AVSampleBufferAudioRenderer

    init(renderer: AVSampleBufferAudioRenderer) {
        self.renderer = renderer
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws {
        while !renderer.isReadyForMoreMediaData {
            try await Task.sleep(for: Self.readinessPollInterval)
        }
        try Task.checkCancellation()
        renderer.enqueue(sampleBuffer)
    }

    func flush() {
        renderer.flush()
    }
}

/// Remembers how far the audio handed to the renderer reaches, so the engine can tell when the renderer is about
/// to run dry (see `PlayerEngine+Buffering`). A flush forgets it.
final class BufferTrackingAudioSink: AudioRendererSink {
    private struct State {
        var end: CMTime?
        /// Bumped by `flush()`, so an enqueue that was in flight across it doesn't record pre-flush media.
        var generation: UInt64 = 0
    }

    private let wrapped: any AudioRendererSink
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(wrapping wrapped: any AudioRendererSink) {
        self.wrapped = wrapped
    }

    /// End of the latest audio enqueued since the last flush; `nil` if none.
    var bufferedEnd: CMTime? {
        state.withLock { $0.end }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws {
        let generation = state.withLock { $0.generation }
        let end = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) + CMSampleBufferGetDuration(sampleBuffer)
        try await wrapped.enqueue(sampleBuffer)
        guard end.isNumeric else { return }
        state.withLock { state in
            guard state.generation == generation else { return }
            state.end = state.end.map { max($0, end) } ?? end
        }
    }

    func flush() {
        state.withLock { state in
            state.end = nil
            state.generation &+= 1
        }
        wrapped.flush()
    }
}
