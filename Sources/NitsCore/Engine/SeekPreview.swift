@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import os

/// The frame a seek shows where it lands: decoded on `seekQueue` from the keyframe the demuxer seeked to, before
/// playback (or the paused picture) goes on from there.
enum SeekPreview {
    struct Result: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let pts: Double
        /// The frame's HDR metadata (Dolby Vision RPU, HDR10+): without it a paused seek tone-maps with static values, not
        /// the frame's.
        let hdrMetadata: FrameHDRMetadata?
    }

    /// Which of the decoded frames the preview shows.
    struct FrameChoice: Equatable {
        let target: Double
        let exact: Bool
        /// A forward frame step: the frame must be at or past it, or the step would not advance.
        let minPts: Double?

        /// Whether the frame at `candidate` replaces the one picked so far (at `current`, `nil` before the first).
        func prefers(_ candidate: Double, over current: Double?) -> Bool {
            guard let current else { return true }
            if let minPts {
                if candidate >= minPts {
                    return current < minPts || abs(candidate - target) < abs(current - target)
                }
                // The closest frame stands in until one past `minPts` comes.
                return current < minPts && abs(candidate - target) <= abs(current - target)
            }
            if exact {
                // The frame closest to the target, whatever order B-frames and the pipeline's tail come out in.
                return abs(candidate - target) <= abs(current - target)
            }
            // Keyframe seek: the earliest displayable frame (frame-threaded decoders may emit several frames once
            // their pipeline fills).
            return candidate < current
        }
    }

    private final class Box: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var pts: Double = -1.0
        var hdrMetadata: FrameHDRMetadata?
    }

    static func decode(
        demuxer: MediaDemuxer,
        decoder: any VideoDecoderProtocol,
        frameQueue: FrameQueue,
        seconds: Double,
        exact: Bool,
        minPts: Double? = nil,
        stepCache: StepFrameCache? = nil,
        isCurrent: @Sendable () -> Bool
    ) -> Result? {
        let lock = OSAllocatedUnfairLock()
        let box = Box()
        let choice = FrameChoice(target: seconds, exact: exact, minPts: minPts)
        // When seeding the step-frame cache (paused seek), decode all frames (discard disabled) for a wider
        // window before the target so backward stepping has ~1s of depth available; otherwise just 0.5s.
        let stepWindow: Double = stepCache != nil ? 1.1 : 0.5
        // Only cache a small margin past the target: the trailing over-read (`extraPipelineAttempts`) would
        // otherwise occupy the fixed-capacity cache with forward frames and starve backward-step depth.
        let stepForwardMargin: Double = 0.25
        // Up to the window before the target, non-reference frames are only decoded to be dropped: skip them. None in
        // the window is lost: a B-frame comes after, in decode order, the later reference it is predicted from, whose
        // packet already turns discarding off below. So a forward step (its target is a frame on) decodes them all.
        if exact {
            decoder.setDiscardNonReferenceFrames(true)
        }
        decoder.setOutputHandler { frame in
            if !frame.doNotDisplay {
                frameQueue.push(frame)
            }
            // Seed the step cache with every decoded frame in the window — including exact-seek preroll
            // frames flagged `doNotDisplay` (which carry valid pixel buffers). They are precisely the
            // frames below the target that backward stepping needs; the flag only suppresses them from the
            // transient seek preview, not from deliberate frame-by-frame display.
            if let stepCache, frame.pts.isValid,
                frame.pts.seconds >= seconds - stepWindow,
                frame.pts.seconds <= seconds + stepForwardMargin
            {
                stepCache.append(
                    pixelBuffer: frame.pixelBuffer, pts: frame.pts, hdrMetadata: frame.hdrMetadata)
            }
            if (exact || !frame.doNotDisplay) && frame.pts.isValid {
                let framePts = frame.pts.seconds
                lock.lock()
                if choice.prefers(framePts, over: box.buffer != nil ? box.pts : nil) {
                    box.buffer = frame.pixelBuffer
                    box.pts = framePts
                    box.hdrMetadata = frame.hdrMetadata
                }
                lock.unlock()
            }
        }

        defer {
            decoder.setDiscardNonReferenceFrames(false)
            decoder.outputDisplayableFrames(to: frameQueue)
        }

        let hasPreview: () -> Bool = {
            lock.lock()
            defer { lock.unlock() }
            return box.buffer != nil
        }

        let hasSatisfiedMinPts: () -> Bool = {
            guard let minPts else { return hasPreview() }
            lock.lock()
            defer { lock.unlock() }
            return box.buffer != nil && box.pts >= minPts
        }

        var attempts = 0
        var reachedTargetPacket = false
        var extraPipelineAttempts = 0
        var foundTarget = false
        var decodedAtLeastOne = false
        var hasCalculatedMaxAttempts = false
        // For non-exact (keyframe) seeks (IINA / mpv style), decode from the keyframe until the decoder
        // emits its first frame (1 packet for VideoToolbox; a few for frame-threaded libdav1d).
        // For exact seeks, decode from keyframe up to target seconds, dynamically sizing the attempt limit
        // based on the distance between the landing keyframe and the requested target position.
        var maxAttempts = exact ? 120 : 24
        while attempts < maxAttempts && !foundTarget && (isCurrent() || !decodedAtLeastOne) {
            if let sample = demuxer.nextVideoSample() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let ptsSeconds = CMTimeGetSeconds(pts)

                if exact && !hasCalculatedMaxAttempts && ptsSeconds.isFinite {
                    hasCalculatedMaxAttempts = true
                    // Dynamic ceiling: estimate needed packets from keyframe to target position.
                    // Generous 60fps * 1.5 multiplier + buffer accommodates 60fps streams, VFR, and B-frame reordering.
                    let distance = max(seconds - ptsSeconds, 1.0)
                    let estimatedPackets = Int(distance * 90.0) + 64
                    maxAttempts = min(max(estimatedPackets, 120), 1200)
                }

                if exact && ptsSeconds.isFinite && ptsSeconds >= (seconds - stepWindow) {
                    // Near target window: restore all frames (including non-reference B-frames)
                    decoder.setDiscardNonReferenceFrames(false)
                }

                decoder.decode(sampleBuffer: sample)
                decodedAtLeastOne = true
                attempts += 1
                if exact {
                    if ptsSeconds >= seconds {
                        reachedTargetPacket = true
                    }
                    if reachedTargetPacket {
                        decoder.waitForPendingFrames()
                        // Ensure we feed at least 6 packets past reachedTargetPacket so that
                        // any trailing B-frames or reordered pictures in display order are decoded.
                        extraPipelineAttempts += 1
                        if hasSatisfiedMinPts() && extraPipelineAttempts >= 6 {
                            foundTarget = true
                        } else if extraPipelineAttempts >= 16 {
                            foundTarget = true
                        }
                    }
                } else {
                    decoder.waitForPendingFrames()
                    if hasPreview() { foundTarget = true }
                }
            } else {
                break
            }
        }
        // Non-destructive: decoding continues from the next packet in runVideoFeeding, so the
        // decoder's reference frames must be preserved (a destructive flush breaks AV1/dav1d).
        decoder.waitForPendingFrames()

        lock.lock()
        let finalBuf = box.buffer
        let finalPts = box.pts
        let finalHDRMetadata = box.hdrMetadata
        lock.unlock()

        if let finalBuf, finalPts >= 0 {
            AppLog.debug(
                .engine,
                "seekPreview settled: pts=\(finalPts)s for target=\(seconds)s (exact=\(exact), attempts=\(attempts))")
            return Result(pixelBuffer: finalBuf, pts: finalPts, hdrMetadata: finalHDRMetadata)
        }
        AppLog.debug(
            .engine, "seekPreview found no frame for target=\(seconds)s (exact=\(exact), attempts=\(attempts))")
        return nil
    }
}
