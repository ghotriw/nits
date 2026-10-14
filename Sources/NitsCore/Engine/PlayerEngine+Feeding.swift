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

        videoFeedingTask = Task.detached(priority: .userInitiated) {
            await Self.runVideoFeeding(
                demuxer: demuxer,
                decoder: decoder,
                queue: queue,
                feedingLock: feedingLock,
                drainPausedLock: drainPausedLock
            )
        }
    }

    private nonisolated static func runVideoFeeding(
        demuxer: MediaDemuxer,
        decoder: any VideoDecoderProtocol,
        queue: FrameQueue,
        feedingLock: OSAllocatedUnfairLock<Bool>,
        drainPausedLock: OSAllocatedUnfairLock<Bool>
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
            decoder.decode(sampleBuffer: sample)
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
