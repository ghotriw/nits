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
        let decoder = stallGuardedDecoder(for: "the video feeder")
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

    // MARK: - Stalled Decoder Recovery

    /// How long a decoder call may take before the decoder counts as stalled. Calls return in milliseconds even
    /// for software decoders; VideoToolbox decodes asynchronously, so one that takes seconds is not coming back.
    static let decoderStallTimeout: Duration = .seconds(3)

    /// The engine's decoder with its blocking calls limited to `decoderStallTimeout`, for the video feeder and for
    /// work on `seekQueue` (seek previews, frame-step pumps, the flush after a load).
    ///
    /// A hardware decoder runs in VideoToolbox's decoder service, and `VTDecompressionSessionDecodeFrame` waits for
    /// it synchronously: when the service stops answering, the call never returns. In the feeder, video then stops,
    /// the demuxer stops handing out audio (it doesn't read ahead past a full video packet queue) and the clock runs
    /// on through silence; on the serial `seekQueue`, every later seek would wait behind it. Guarded, the caller
    /// carries on without the decoder (a seek lands without a preview frame) and `recoverFromStalledDecoder`
    /// replaces it. `caller` names the user in the log.
    func stallGuardedDecoder(for caller: String) -> StallGuardedVideoDecoder {
        let current = decoder
        return StallGuardedVideoDecoder(wrapping: current, timeout: Self.decoderStallTimeout) {
            [weak self] blockedFor in
            DispatchQueue.main.async {
                self?.recoverFromStalledDecoder(current, blockedFor: blockedFor, caller: caller)
            }
        }
    }

    /// Replaces a stalled decoder and restarts video with the new one where it stood: at the target of a seek in
    /// flight (which the new seek supersedes, as a newer target would), else at the last presented frame. The
    /// guarded wrapper has already silenced the stalled decoder; it is otherwise left alone, since flushing or
    /// invalidating a VideoToolbox session starts by waiting for its frames, and its call keeps its thread.
    func recoverFromStalledDecoder(_ stalled: any VideoDecoderProtocol, blockedFor: Duration, caller: String) {
        // Already replaced (a stall seen by both the feeder and a seek), or another media was loaded meanwhile.
        guard stalled === decoder else { return }
        logDecoderStall("a call from \(caller) has not returned for \(blockedFor)")
        stopFeedingVideo()
        guard replaceStalledDecoder() else { return }
        let target = chaseTargetTime ?? (currentFramePTS >= 0 ? currentFramePTS : currentTime)
        seek(to: target, exact: true)
    }

    /// Installs a new decoder in place of a stalled one: a fresh session the first time, software decoding for
    /// the rest of the media after that. Returns `false` when there is none, leaving video stopped.
    private func replaceStalledDecoder() -> Bool {
        guard let demuxer else { return false }
        decoderStallRecoveries += 1
        let preferSoftware = decoderStallRecoveries > 1
        guard
            let replacement = VideoDecoderFactory.makeDecoder(
                for: demuxer.codec, demuxer: demuxer, preferSoftware: preferSoftware)
        else {
            AppLog.error(.video, "No replacement video decoder for \(demuxer.codec); video stays stopped")
            return false
        }
        AppLog.error(.video, "Replacing the stalled video decoder with a \(preferSoftware ? "software" : "new") one")
        installVideoDecoder(replacement)
        return true
    }

    /// Logs a stall with the state that tells its possible causes apart:
    /// whether the display layer still holds or rejects frames, whether the session owes output, and where
    /// playback and the queue stood.
    private func logDecoderStall(_ what: String) {
        let renderer = displayLayer.sampleBufferRenderer
        let layerStatus: String
        switch renderer.status {
        case .rendering: layerStatus = "rendering"
        case .failed: layerStatus = "failed (\(renderer.error.map { "\($0)" } ?? "no error"))"
        case .unknown: layerStatus = "unknown"
        @unknown default: layerStatus = "status \(renderer.status.rawValue)"
        }
        let decoderDescription: String
        if let session = decoder as? VTVideoDecoder {
            decoderDescription = "VideoToolbox, \(session.pendingFrameCount) frame(s) in flight"
        } else {
            decoderDescription = String(describing: type(of: decoder))
        }
        let codec = demuxer.map { "\($0.codec)" } ?? "?"
        let layer = "display layer \(layerStatus), requires flush: \(renderer.requiresFlushToResumeDecoding)"
        let position = "frame \(currentFramePTS)s, clock \(synchronizer.currentTime().seconds)s"
        let state = "playing \(isPlaying), seeking \(isSeeking), stepping \(isStepPumping)"
        AppLog.error(
            .video,
            "Video decoder stalled: \(what). Decoder: \(decoderDescription), codec \(codec); \(layer); queue "
                + "\(frameQueue.count) frame(s); \(position); \(state); recoveries so far \(decoderStallRecoveries)"
        )
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
        decoder: StallGuardedVideoDecoder,
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
                    await decoder.drainAsync()
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
            await decoder.decodeAsync(sampleBuffer: sample)
            PlayerPerformanceMonitor.shared.signposter.endInterval("EnqueueDecodeFrame", interval)
            // Recovery replaces the decoder and restarts feeding; reading on would only discard packets.
            if decoder.isStalled { break }
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
        let firstFedPTS = self.firstFedAudioPTS
        firstFedPTS.withLock { $0 = nil }

        audioFeedingTask = Task.detached(priority: .userInitiated) {
            await previousRun?.value
            await Self.runAudioFeeding(
                demuxer: demuxer,
                audioDecoder: aDecoder,
                sink: sink,
                feedingLock: feedingLock,
                audioTimebase: audioTimebase,
                firstFedPTS: firstFedPTS
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
        audioTimebase: AVRational,
        firstFedPTS: OSAllocatedUnfairLock<CMTime?>
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
                firstFedPTS.withLock { $0 = pts }
                AppLog.debug(
                    .audio,
                    "First audio buffer enqueued to renderer: pts = \(pts.isValid ? String(format: "%.3f", pts.seconds) : "invalid")s"
                )
            }
        }
    }
}
