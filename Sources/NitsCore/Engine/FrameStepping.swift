import Foundation

/// Where paused frame stepping stands: what lets a step go without a keyframe re-seek. Released whenever the pipeline
/// moves on: playback feeding resumes, a seek repositions it, media loads or stops. A class, as the cache it holds is
/// one: a copy's reset would clear the engine's cache but not the engine's flags. Main actor only.
final class FrameStepState {
    /// Lazily-populated window of decoded frames around the current position for cheap paused frame-stepping
    /// in both directions. Empty during normal playback; populated while paused-stepping and held until
    /// playback resumes or a seek repositions the pipeline.
    let cache = StepFrameCache(capacity: 32)
    /// The decoder and demuxer are positioned contiguously just past the current frame, so a forward frame step can
    /// decode incrementally (or serve an over-read frame) instead of re-seeking to the keyframe and re-decoding the
    /// whole GOP. Set after an exact seek settles paused.
    var isContiguous = false
    /// A forward step pump is decoding on `seekQueue`. Guards against key-repeat presses falling through to a heavy
    /// keyframe re-seek mid-pump; extra presses are ignored until the pump completes.
    var isPumping = false
    /// The playback cursor has drifted from the last seek baseline via frame-stepping. On resume the demuxer/decoder
    /// sit ahead of the cursor and audio before the baseline was purged, so `play()` reseeks to `currentTime` to
    /// restore clean A/V alignment.
    var didStepSincePause = false

    /// A seek repositions the pipeline: the steps' window and position no longer hold. A pump in flight is left to
    /// finish, and to clear `isPumping` itself.
    func releaseWindow() {
        isContiguous = false
        didStepSincePause = false
        cache.clear()
    }

    /// Playback goes on, or the media goes: stepping ends altogether.
    func reset() {
        releaseWindow()
        isPumping = false
    }
}

/// Decodes forward from a contiguous position for a forward frame step, into the step cache.
enum FrameStepPump {
    struct Outcome: Sendable {
        /// The frame after the one shown, if one was decoded.
        let entry: StepFrameCache.Entry?
        /// The demuxer had no more samples to read.
        let hitBoundary: Bool
    }

    /// Decodes until a frame past `baseTime` is in `stepCache`, and a few more for the steps after it; on
    /// `seekQueue`. Decoded frames go to the cache meanwhile, to `frameQueue` again after.
    static func run(
        demuxer: MediaDemuxer,
        decoder: any VideoDecoderProtocol,
        frameQueue: FrameQueue,
        stepCache: StepFrameCache,
        after baseTime: Double,
        isSuperseded: @Sendable () -> Bool
    ) -> Outcome {
        decoder.setOutputHandler { frame in
            if !frame.doNotDisplay, frame.pts.isValid {
                stepCache.append(
                    pixelBuffer: frame.pixelBuffer, pts: frame.pts, hdrMetadata: frame.hdrMetadata)
            }
        }
        defer { decoder.outputDisplayableFrames(to: frameQueue) }

        var entry: StepFrameCache.Entry? = nil
        var hitBoundary = false
        var attempts = 0
        // Keep decoding a few frames past the one we need so subsequent (including key-repeat) forward
        // steps are served straight from the cache without re-entering a pump.
        let prefetchAhead = 6
        // A contiguous position never needs a whole GOP; this covers decoder reorder depth plus margin.
        let maxAttempts = 48
        while attempts < maxAttempts && !isSuperseded() {
            guard let sample = demuxer.nextVideoSample() else {
                hitBoundary = true
                break
            }
            decoder.decode(sampleBuffer: sample)
            decoder.waitForPendingFrames()
            attempts += 1
            if entry == nil {
                entry = stepCache.frameAfter(baseTime)
            }
            // Once the target frame exists, stop after enough look-ahead frames are buffered.
            if entry != nil, stepCache.countAfter(baseTime) >= prefetchAhead + 1 {
                break
            }
        }
        return Outcome(entry: entry, hitBoundary: hitBoundary)
    }
}
