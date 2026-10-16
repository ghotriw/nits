@preconcurrency import AVFoundation
import AppKit
import CFFmpeg
@preconcurrency import CoreMedia
import Foundation
import os

extension PlayerEngine {
    nonisolated func checkBackpressureAndResumeIfNeeded() {
        let shouldResume = isVideoDrainPaused.withLock { isPaused -> Bool in
            if isPaused {
                isPaused = false
                return true
            }
            return false
        }
        guard shouldResume, isFeeding.withLock({ $0 }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFeeding.withLock({ $0 }) else { return }
            self.startFeedingVideo()
        }
    }

    func stopFeedingVideo() {
        videoFeedingTask?.cancel()
        videoFeedingTask = nil
    }

    /// Cancels audio feeding. The task handle is kept so the next run can wait for this one to stash its
    /// undelivered output (see `runAudioFeeding`).
    func stopFeedingAudio() {
        audioFeedingTask?.cancel()
    }

    func startFeeding() {
        guard let demuxer = self.demuxer else { return }
        // Feeding will consume packets forward from the current position, so the standalone-step
        // contiguity invariant no longer holds once playback resumes; release the step window too.
        stepDecodeContiguous = false
        isStepPumping = false
        didStepSincePause = false
        stepFrameCache.clear()
        isFeeding.withLock { $0 = true }
        isVideoDrainPaused.withLock { $0 = false }

        if demuxer.hasVideo {
            startFeedingVideo()
        }
        startFeedingAudio()
    }

    func startFeedingVideo() {
        guard let demuxer = self.demuxer else { return }
        stopFeedingVideo()

        let feedingLock = self.isFeeding
        let drainPausedLock = self.isVideoDrainPaused
        let decoder = self.decoder
        let queue = self.frameQueue
        // Each run times its own decode calls, so a stalled run that returns late can't clear the next one's.
        let decodeWatch = DecodeWatch()
        videoDecodeWatch = decodeWatch

        videoFeedingTask = Task.detached(priority: .userInitiated) {
            await Self.runVideoFeeding(
                demuxer: demuxer,
                decoder: decoder,
                queue: queue,
                feedingLock: feedingLock,
                drainPausedLock: drainPausedLock,
                decodeWatch: decodeWatch
            )
        }
    }

    // MARK: - Stalled Decoder Recovery

    /// How long a decode call may take before the decoder counts as stalled. Calls return in milliseconds even
    /// for software decoders; VideoToolbox decodes asynchronously, so one that takes seconds is not coming back.
    static let decoderStallTimeout: Duration = .seconds(3)

    /// Replaces the video decoder when a decode call has not returned for `decoderStallTimeout`.
    ///
    /// A hardware decoder runs in VideoToolbox's decoder service, and `VTDecompressionSessionDecodeFrame` waits for
    /// it synchronously: when the service stops answering, the call never returns. Video then stops, the demuxer
    /// stops handing out audio (it doesn't read ahead past a full video packet queue) and the clock runs on through
    /// silence, so pausing and resuming can't help.
    func checkForStalledDecoder() {
        guard hasVideo, isPlaying, !isSeeking, let since = videoDecodeWatch?.decodeStartedAt else { return }
        let blockedFor = ContinuousClock.now - since
        guard blockedFor >= Self.decoderStallTimeout else { return }
        recoverFromStalledDecoder(blockedFor: blockedFor)
    }

    /// Abandons the stalled decoder and restarts video from the last presented frame with a new one: a fresh
    /// session the first time, software decoding for the rest of the media if that stalls too.
    ///
    /// The stalled decoder is left alone: flushing or invalidating a VideoToolbox session starts by waiting for
    /// its frames, which would block the caller the same way. Its feeder stays parked in the stalled call.
    func recoverFromStalledDecoder(blockedFor: Duration) {
        guard let demuxer else { return }
        decoderStallRecoveries += 1
        let preferSoftware = decoderStallRecoveries > 1
        AppLog.error(
            .video,
            "Video decoder stalled: a decode call has not returned for \(blockedFor). Replacing it with a \(preferSoftware ? "software" : "new") decoder"
        )

        // Frames the stalled decoder might still emit must not reach the queue the new one fills.
        decoder.setOutputHandler { _ in }
        stopFeedingVideo()
        videoDecodeWatch = nil
        guard
            let replacement = VideoDecoderFactory.makeDecoder(
                for: demuxer.codec, demuxer: demuxer, preferSoftware: preferSoftware)
        else {
            AppLog.error(.video, "No replacement video decoder for \(demuxer.codec); video stays stopped")
            return
        }
        installVideoDecoder(replacement)
        seek(to: currentFramePTS >= 0 ? currentFramePTS : currentTime, exact: true)
    }

    /// Makes `newDecoder` the engine's video decoder, feeding the frame queue.
    func installVideoDecoder(_ newDecoder: any VideoDecoderProtocol) {
        decoder = newDecoder
        applyDeinterlaceMode(refresh: false)
        let queue = frameQueue
        decoder.setOutputHandler { frame in
            if !frame.doNotDisplay {
                queue.push(frame)
            }
        }
    }

    private nonisolated static func runVideoFeeding(
        demuxer: MediaDemuxer,
        decoder: any VideoDecoderProtocol,
        queue: FrameQueue,
        feedingLock: OSAllocatedUnfairLock<Bool>,
        drainPausedLock: OSAllocatedUnfairLock<Bool>,
        decodeWatch: DecodeWatch
    ) async {
        let sampleCountLock = OSAllocatedUnfairLock(initialState: 0)
        while !Task.isCancelled && feedingLock.withLock({ $0 }) {
            // Cooperative backpressure: pause decoding when queue has >= 40 frames
            if queue.count >= 40 {
                drainPausedLock.withLock { $0 = true }
                while !Task.isCancelled && queue.count > 25 && feedingLock.withLock({ $0 }) {
                    try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                }
                drainPausedLock.withLock { $0 = false }
                if Task.isCancelled || !feedingLock.withLock({ $0 }) { break }
            }

            guard let sample = demuxer.nextVideoSample() else {
                if demuxer.isEOF {
                    AppLog.debug(.engine, "Demuxer reached EOF for video. Draining decoder...")
                    decoder.drain()
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }

            let count = sampleCountLock.withLock { count -> Int in
                count += 1
                return count
            }
            if count <= 5 || count % 200 == 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                AppLog.debug(
                    .video,
                    "Decoding video sample #\(count), pts: \(CMTimeGetSeconds(pts))s, queueCount: \(queue.count)"
                )
            }

            let signpostID = PlayerPerformanceMonitor.shared.signposter.makeSignpostID()
            let interval = PlayerPerformanceMonitor.shared.signposter.beginInterval(
                "EnqueueDecodeFrame", id: signpostID)
            decodeWatch.begin()
            decoder.decode(sampleBuffer: sample)
            decodeWatch.end()
            PlayerPerformanceMonitor.shared.signposter.endInterval("EnqueueDecodeFrame", interval)
        }
    }

    func startFeedingAudio() {
        guard let demuxer = self.demuxer, let aDecoder = self.audioDecoder else { return }
        // The previous run may still be unwinding from its cancellation; the new one waits for it so the
        // output it stashes is delivered first and in order.
        let previousRun = audioFeedingTask
        previousRun?.cancel()

        let feedingLock = self.isFeeding
        let sink = self.audioSink
        let audioTimebase = demuxer.audioTimebase

        audioFeedingTask = Task.detached(priority: .userInitiated) {
            await previousRun?.value
            await Self.runAudioFeeding(
                demuxer: demuxer,
                audioDecoder: aDecoder,
                sink: sink,
                feedingLock: feedingLock,
                audioTimebase: audioTimebase
            )
        }
    }

    /// Feeds decoded audio to the renderer until cancelled or EOF.
    ///
    /// Cancellation (pause) usually lands while `enqueue` waits on renderer backpressure, i.e. with part of a
    /// decoded packet still undelivered. That remainder is stashed in the decoder and delivered first by the
    /// next run instead of being dropped, so pause/resume keeps the audio stream gapless.
    private nonisolated static func runAudioFeeding(
        demuxer: MediaDemuxer,
        audioDecoder: FFAudioDecoder,
        sink: any AudioRendererSink,
        feedingLock: OSAllocatedUnfairLock<Bool>,
        audioTimebase: AVRational
    ) async {
        var hasLoggedFirstAudioBuffer = false
        var pendingGeneration = audioDecoder.generation
        var pending = ArraySlice(audioDecoder.takeUndelivered())
        defer { audioDecoder.stashUndelivered(pending, generation: pendingGeneration) }

        while !Task.isCancelled && feedingLock.withLock({ $0 }) {
            guard let buf = pending.first else {
                guard let packet = demuxer.nextAudioPacket() else {
                    if demuxer.isEOF {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                    continue
                }
                pendingGeneration = audioDecoder.generation
                pending = ArraySlice(
                    audioDecoder.decode(
                        packetData: packet.data,
                        pts: packet.pts,
                        timebase: audioTimebase
                    ))
                continue
            }
            do {
                try await sink.enqueue(buf)
            } catch is CancellationError {
                break  // not accepted by the renderer; stays pending
            } catch {
                AppLog.warning(.audio, "Audio enqueue failed: \(error)")
            }
            pending.removeFirst()
            if !hasLoggedFirstAudioBuffer {
                hasLoggedFirstAudioBuffer = true
                let pts = CMSampleBufferGetPresentationTimeStamp(buf)
                AppLog.debug(
                    .audio,
                    "First audio buffer enqueued to renderer: pts = \(pts.isValid ? String(format: "%.3f", pts.seconds) : "invalid")s"
                )
            }
        }
    }
}

/// When the video feeder's decode call in progress began; `nil` between calls.
final class DecodeWatch: Sendable {
    private let startedAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    var decodeStartedAt: ContinuousClock.Instant? {
        startedAt.withLock { $0 }
    }

    func begin() {
        startedAt.withLock { $0 = .now }
    }

    func end() {
        startedAt.withLock { $0 = nil }
    }
}
