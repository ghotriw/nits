import AVFoundation
import CoreMedia

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
