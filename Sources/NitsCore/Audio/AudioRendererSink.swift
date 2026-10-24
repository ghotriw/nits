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
final class ReceiverAudioSink: AudioRendererSink, @unchecked Sendable {
    private let receiver: AVSampleBufferAudioRenderer.Receiver

    init(receiver: AVSampleBufferAudioRenderer.Receiver) {
        self.receiver = receiver
    }

    /// A cancelled wait does not throw: `enqueue` returns `.cancelledDueToFlush` (also when the feeding task is
    /// cancelled on pause) and the buffer was not taken. Treated as accepted, it was dropped and left a gap that
    /// became audible once the renderer played up to it, about a second after resuming.
    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws {
        nonisolated(unsafe) let sBuf = sampleBuffer
        let ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent> = CMReadySampleBuffer(unsafeBuffer: sBuf)
        switch try await receiver.enqueue(ready) {
        case .enqueued:
            break
        case .enqueuedWithSuggestedFlush(let reasons):
            AppLog.warning(.audio, "Audio renderer suggests a flush after enqueuing: \(reasons)")
        case .cancelledDueToFlush:
            throw CancellationError()
        case .cancelledDueToError(let error):
            throw error
        @unknown default:
            break
        }
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
/// to run dry (see `PlayerEngine+Buffering`), and which audio the renderer is holding back (see
/// `PlayerEngine+AudioLag`). A flush forgets both.
final class BufferTrackingAudioSink: AudioRendererSink {
    private struct State {
        var end: CMTime?
        /// Start of the buffer waiting for the renderer to take it.
        var pending: CMTime?
        /// Bumped by `flush()`, so an enqueue that was in flight across it doesn't record pre-flush media.
        var generation: UInt64 = 0
    }

    private let wrapped: any AudioRendererSink
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onFlush: (@Sendable () -> Void)?

    /// - Parameter onFlush: Called on every flush, before the renderer's: a flush restarts its audio queue, and with it
    ///   the output device's IO, under a clock that may keep running (see `AudioOutputInterruptionDetector`).
    init(wrapping wrapped: any AudioRendererSink, onFlush: (@Sendable () -> Void)? = nil) {
        self.wrapped = wrapped
        self.onFlush = onFlush
    }

    /// End of the latest audio enqueued since the last flush; `nil` if none.
    var bufferedEnd: CMTime? {
        state.withLock { $0.end }
    }

    /// Start of the audio the renderer has not taken yet while the feeder waits on its backpressure; `nil` while
    /// nothing waits.
    var pendingStart: CMTime? {
        state.withLock { $0.pending }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws {
        let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let end = start + CMSampleBufferGetDuration(sampleBuffer)
        let generation = state.withLock { state in
            state.pending = start
            return state.generation
        }
        defer {
            state.withLock { state in
                guard state.generation == generation else { return }
                state.pending = nil
            }
        }
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
            state.pending = nil
            state.generation &+= 1
        }
        onFlush?()
        wrapped.flush()
    }
}

/// Shifts audio against the picture by `delay` (positive plays it later) and keeps the audio it handed on, so a delay
/// change re-enqueues it with the new shift instead of re-reading the media (a seek, which stalls the picture).
///
/// The shift is in media time, applied to the timestamps the renderer schedules on the master clock; the clock, the
/// picture and subtitles stay on the media's own timeline.
final class DelayedAudioSink: AudioRendererSink {
    /// Media seconds of enqueued audio kept for `changeDelay`: what the renderer queues (up to ~4 s of media at 4x, see
    /// `PlayerEngine+Buffering`) plus a full swing of `PlayerEngine.audioDelayRange`.
    static let retainedSeconds: Double = 6

    private struct State {
        var delay: CMTime = .zero
        /// Enqueued audio, unshifted, in presentation order.
        var retained: [CMSampleBuffer] = []
        /// Bumped by `flush()` and `changeDelay`, so an enqueue in flight across them isn't retained.
        var generation: UInt64 = 0
    }

    private let wrapped: BufferTrackingAudioSink
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(wrapping wrapped: BufferTrackingAudioSink) {
        self.wrapped = wrapped
    }

    /// End of the latest audio enqueued since the last flush, on the clock's timeline (delay included).
    var bufferedEnd: CMTime? {
        wrapped.bufferedEnd
    }

    /// Start of the audio waiting for the renderer to take it, on the clock's timeline (delay included).
    var pendingStart: CMTime? {
        wrapped.pendingStart
    }

    /// Sets the delay for audio enqueued from now on, keeping what is already queued; for a pipeline that is flushed
    /// anyway (loading media).
    func setDelay(_ delay: CMTime) {
        state.withLock { $0.delay = delay }
    }

    /// Sets the delay and flushes the renderer. Returns the retained audio that, with the new delay, still ends after
    /// `clock`, for the caller to enqueue again before anything newer. Nothing may be enqueueing meanwhile: an
    /// enqueue in flight would deliver its buffer with the old delay after the flush.
    func changeDelay(to delay: CMTime, keepingAudioAfter clock: CMTime) -> [CMSampleBuffer] {
        let replay = state.withLockUnchecked { state in
            state.delay = delay
            state.generation &+= 1
            defer { state.retained.removeAll() }
            guard clock.isNumeric else { return state.retained }
            return state.retained.filter { Self.end(of: $0) + delay > clock }
        }
        wrapped.flush()
        return replay
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws {
        let (delay, generation) = state.withLock { ($0.delay, $0.generation) }
        let shifted = delay == .zero ? sampleBuffer : try Self.shift(sampleBuffer, by: delay)
        try await wrapped.enqueue(shifted)
        state.withLockUnchecked { state in
            guard state.generation == generation else { return }
            state.retained.append(sampleBuffer)
            let end = Self.end(of: sampleBuffer)
            guard end.isNumeric else { return }
            let horizon = end.seconds - Self.retainedSeconds
            let stale = state.retained.prefix { Self.end(of: $0).seconds < horizon }.count
            state.retained.removeFirst(stale)
        }
    }

    func flush() {
        state.withLock { state in
            state.retained.removeAll()
            state.generation &+= 1
        }
        wrapped.flush()
    }

    private static func end(of buffer: CMSampleBuffer) -> CMTime {
        CMSampleBufferGetPresentationTimeStamp(buffer) + CMSampleBufferGetDuration(buffer)
    }

    private static func shift(_ buffer: CMSampleBuffer, by delay: CMTime) throws -> CMSampleBuffer {
        let timing = try buffer.sampleTimingInfos().map { info in
            var info = info
            info.presentationTimeStamp = info.presentationTimeStamp + delay
            if info.decodeTimeStamp.isValid {
                info.decodeTimeStamp = info.decodeTimeStamp + delay
            }
            return info
        }
        return try CMSampleBuffer(copying: buffer, withNewTiming: timing)
    }
}
