import Foundation

/// When buffering starts and when it ends (see `PlayerEngine+Buffering`), decided from what is queued at the clock.
/// No engine and no clock: the engine reads the amounts (`Levels`) and holds or restarts the clock itself.
///
/// Audio amounts are in seconds of playback (media seconds divided by the rate): the renderer queues about a second
/// of playback at any rate (measured 0.9–1.4 s of media at 1x, 2.8–3.9 s at 4x). Video amounts are in frames: the
/// feeder keeps 25–40 whatever the frame rate, which at 60 or 120 fps is well under half a second.
enum BufferingPolicy {
    /// Seconds of playback of queued audio below which the renderer counts as running dry.
    static let audioLowWatermark: Double = 0.15
    /// Seconds of playback of queued audio before playback resumes; above the low watermark, so a resume does not
    /// run straight into another hold.
    static let resumeAudio: Double = 0.5
    /// Queued frames below which video counts as running low: under the 25 the feeder refills from while frames
    /// arrive (measured minimum 25 at 1x–4x).
    static let videoLowFrames = 20
    /// Queued frames before playback resumes; above `videoLowFrames`, and reachable with the clock held, as the
    /// feeder fills to 40 before pausing.
    static let resumeFrames = 30

    /// What is queued at the clock, for media that has not been read to its end.
    struct Levels: Equatable, Sendable {
        /// Media seconds of audio the renderer holds past the clock (0 when it holds none).
        var audioAhead: Double = 0
        var queuedFrames = 0
        /// A decoder and a source for audio.
        var hasAudio = false
        var hasVideo = false
        /// Audio comes over an input of its own (`PlaybackInputs.isAudioSeparate`).
        var isAudioSeparate = false
        /// The selected audio track has been read to its end.
        var isAudioEOF = false
        /// A buffer has waited on the renderer for `BufferTrackingAudioSink.fullAfter` (`isRendererFull`): its queue
        /// is full, so the audio that is missing is not behind the demuxer or the network. Full of what may not count
        /// as ahead: a renderer kept across a seek forward (`AudioJoin`) still holds the old position's audio, which it
        /// drops as late only while the clock runs. Held, it never makes room.
        var isAudioRendererFull = false
        /// The picture's input has no video packets queued for the decoder, reading ahead.
        var isVideoReadAheadDry = false
        /// Seconds the clock is past the last frame presented.
        var secondsPastLastFrame: Double = 0
        var frameDuration: Double = 0
    }

    /// Seconds of playback of queued audio before the clock starts on a renderer that was flushed, and before
    /// `AudioJoin` ends after handing the clock over (the renderer flushed or kept). Twice the low watermark: at the
    /// watermark `isStarved` would hold the clock again at its first check.
    static func audioAheadToStart(rate: Double) -> Double {
        2 * audioLowWatermark * rate
    }

    /// Media has run out at `rate`, the clock's current one (see `PlayerEngine+Buffering`).
    static func isStarved(_ levels: Levels, rate: Double) -> Bool {
        if levels.hasAudio, levels.isAudioSeparate {
            // An audio file on an input of its own: one input running out doesn't drain the other, so each stream
            // counts on its own. Audio that has ended plays no more; pictures run out when the picture's input has
            // none queued for the decoder (reading on demand, the feeder reads as it needs: never).
            // A full renderer, if of old audio, is no shortage: holding the clock would keep it full.
            let isAudioDry =
                levels.audioAhead < audioLowWatermark * rate && !levels.isAudioEOF && !levels.isAudioRendererFull
            let isVideoDry = levels.hasVideo && levels.queuedFrames < videoLowFrames && levels.isVideoReadAheadDry
            return isAudioDry || isVideoDry
        }
        if levels.hasAudio {
            guard levels.audioAhead < audioLowWatermark * rate else { return false }
            // Dry by the watermark, yet full (see above): of old audio, which tells nothing of the demuxer. The picture
            // does, as with audio of its own: its input has run out too. (Not the frame queue alone: with audio ahead
            // it is a decoder behind, and the renderer is full through most of playback.)
            if levels.isAudioRendererFull {
                return levels.hasVideo && levels.queuedFrames < videoLowFrames && levels.isVideoReadAheadDry
            }
            return !levels.hasVideo || levels.queuedFrames < videoLowFrames
        }
        if levels.hasVideo {
            // A frame or two behind with nothing queued: a decoder that keeps up hovers at an empty queue at times.
            return levels.queuedFrames == 0 && levels.secondsPastLastFrame > 2 * levels.frameDuration
        }
        return false
    }

    /// Enough has been queued to resume at `rate`, the one the held clock restarts at.
    ///
    /// - Parameter audioSettled: The queued audio has not changed for `PlayerEngine.bufferingAudioSettleTime`, so no
    ///   more is coming while the clock is held. Playback then resumes with what there is: above the low watermark (the renderer is full), or with
    ///   video ready, when the audio may be stuck behind the demuxer's full video packet queue, or (audio on an input
    ///   of its own) with the renderer refusing more. With none of these, data has stopped altogether and the clock
    ///   stays held.
    static func isReadyToResume(_ levels: Levels, rate: Double, audioSettled: Bool) -> Bool {
        let ahead = levels.audioAhead
        let isVideoReady = !levels.hasVideo || levels.queuedFrames >= resumeFrames
        let isAudioReady: Bool
        if !levels.hasAudio {
            isAudioReady = true
        } else if levels.isAudioSeparate {
            // On an input of its own no picture's queue holds the audio back: audio that stopped coming is short, not
            // all there is, and resuming with the picture ready would run into silence and buffer again at once. It
            // resumes once the renderer has enough (or is full), or the file has ended. A renderer that has refused
            // the next buffer for a while (`isAudioRendererFull`) is full however little is ahead, even nothing: of the
            // old position's audio, which only a running clock drops. Waiting for more would wait for ever.
            isAudioReady =
                levels.isAudioEOF || ahead >= resumeAudio * rate
                || (audioSettled && (ahead > audioLowWatermark * rate || levels.isAudioRendererFull))
        } else {
            // A full renderer as above: without a picture, the video-ready way out does not exist.
            isAudioReady =
                ahead >= resumeAudio * rate
                || (audioSettled
                    && (ahead > audioLowWatermark * rate || levels.isAudioRendererFull
                        || (levels.hasVideo && isVideoReady)))
        }
        return isAudioReady && isVideoReady
    }

    /// The renderer holds the audio for the position a hold resumes at (`AudioJoin.isRendererStale` can be cleared): it
    /// was fed from there while the clock was held. Not when it is full with less than the watermark ahead at `rate`:
    /// it can be full of the old position's audio, which a pause before the running clock drops it would keep in.
    static func holdsAudioForPosition(_ levels: Levels, rate: Double) -> Bool {
        !(levels.hasAudio && levels.isAudioRendererFull && levels.audioAhead < audioLowWatermark * rate)
    }
}
