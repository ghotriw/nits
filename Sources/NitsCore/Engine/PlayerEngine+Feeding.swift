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

    func stopFeedingAudio() {
        audioFeedingTask?.cancel()
        audioFeedingTask = nil
    }

    func startFeeding() {
        guard let demuxer = self.demuxer else { return }
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
        stopFeedingAudio()

        let feedingLock = self.isFeeding
        let receiver = self.audioReceiver
        let audioTimebase = demuxer.audioTimebase

        audioFeedingTask = Task.detached(priority: .userInitiated) {
            await Self.runAudioFeeding(
                demuxer: demuxer,
                audioDecoder: aDecoder,
                receiver: receiver,
                feedingLock: feedingLock,
                audioTimebase: audioTimebase
            )
        }
    }

    private nonisolated static func runAudioFeeding(
        demuxer: MediaDemuxer,
        audioDecoder: FFAudioDecoder,
        receiver: AVSampleBufferAudioRenderer.Receiver,
        feedingLock: OSAllocatedUnfairLock<Bool>,
        audioTimebase: AVRational
    ) async {
        while !Task.isCancelled && feedingLock.withLock({ $0 }) {
            guard let packet = demuxer.nextAudioPacket() else {
                if demuxer.isEOF {
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            let pcmBuffers = audioDecoder.decode(
                packetData: packet.data,
                pts: packet.pts,
                timebase: audioTimebase
            )
            for buf in pcmBuffers {
                if Task.isCancelled || !feedingLock.withLock({ $0 }) { break }
                nonisolated(unsafe) let sBuf = buf
                let ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent> = CMReadySampleBuffer(unsafeBuffer: sBuf)
                _ = try? await receiver.enqueue(ready)
            }
        }
    }
}
