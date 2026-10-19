import CoreMedia
import Foundation

/// Holds the clock while media data runs out mid-playback, like mpv's cache pause.
///
/// The synchronizer starts with `delaysRateChangeUntilHasSufficientMediaData = false` and, once running, never
/// waits for data: when the demuxer or a decoder falls behind (slow network or disk, a video decoder too slow for
/// realtime starving audio through the demuxer's read-ahead limit), the clock runs on through silence, and audio and
/// video arriving later are already late. Instead the clock stops while media has run out and starts again once
/// data has built up, at the position where it stopped.
///
/// The trigger is audio running dry while the frame queue has fallen below the range the video feeder keeps it in
/// while frames arrive. Audio alone is not enough: a track that ends before the video must not stop playback, and
/// then the video keeps arriving and its queue stays in range. Nor is a low frame queue while audio plays (a decoder
/// briefly behind). Reading both streams from one demuxer, a real shortage drains both; waiting for the frame queue
/// to empty completely would let the clock run into silence for however much more video than audio was queued.
/// Without audio, the trigger is the frame queue running empty with the clock past the last frame.
///
/// Audio amounts are in seconds of playback (media seconds divided by the rate): the renderer queues about a second
/// of playback at any rate (measured 0.9–1.4 s of media at 1x, 2.8–3.9 s at 4x). Video amounts are in frames: the
/// feeder keeps 25–40 whatever the frame rate, which at 60 or 120 fps is well under half a second.
extension PlayerEngine {
    /// Seconds of playback of queued audio below which the renderer counts as running dry.
    static let bufferingAudioLowWatermark: Double = 0.15
    /// Seconds of playback of queued audio before playback resumes; above the low watermark, so a resume does not
    /// run straight into another hold.
    static let bufferingResumeAudio: Double = 0.5
    /// Queued frames below which video counts as running low: under the 25 the feeder refills from while frames
    /// arrive (measured minimum 25 at 1x–4x).
    static let bufferingVideoLowFrames = 20
    /// Queued frames before playback resumes; above `bufferingVideoLowFrames`, and reachable with the clock held,
    /// as the feeder fills to 40 before pausing.
    static let bufferingResumeFrames = 30
    /// How long the queued audio may stay unchanged before it counts as all there is. With the clock held the
    /// renderer stops taking audio once full, and with video at its limit the demuxer reads no further audio.
    static let bufferingAudioSettleTime: Duration = .milliseconds(500)
    static let bufferingPollInterval: Duration = .milliseconds(50)

    private var hasAudioStream: Bool {
        audioDecoder != nil && demuxer?.hasAudio == true
    }

    /// Media seconds of audio the renderer holds past `clock` (0 when it holds none).
    private func audioAhead(of clock: CMTime) -> Double {
        guard let end = audioSink.bufferedEnd, end.isNumeric else { return 0 }
        return (end - clock).seconds
    }

    /// Starts buffering when media has run out (see the extension's comment). Called by the periodic time
    /// observer, which fires only while the clock runs.
    func checkForStarvation() {
        guard isPlaying, !isBuffering, !isSeeking, chaseTargetTime == nil, !isPrerolling,
            let demuxer, !demuxer.isEOF, synchronizer.rate > 0
        else { return }
        let clock = synchronizer.currentTime()
        guard clock.isNumeric else { return }

        let rate = Double(synchronizer.rate)
        let ahead = audioAhead(of: clock)
        let queued = frameQueue.count
        let isStarved: Bool
        if hasAudioStream {
            isStarved =
                ahead < Self.bufferingAudioLowWatermark * rate && (!hasVideo || queued < Self.bufferingVideoLowFrames)
        } else if hasVideo {
            // A frame or two behind with nothing queued: a decoder that keeps up hovers at an empty queue at times.
            let frameDuration = nominalFrameDurationLock.withLock { $0 }
            isStarved = queued == 0 && clock.seconds > frameQueue.getLastRenderedPTS() + 2 * frameDuration
        } else {
            isStarved = false
        }
        guard isStarved else { return }

        synchronizer.setRate(0, time: clock)
        isBuffering = true
        AppLog.info(
            .engine,
            "Buffering at \(String(format: "%.3f", clock.seconds))s: audio \(String(format: "%.3f", ahead))s ahead, "
                + "\(queued) frame(s) queued; holding the clock"
        )
        bufferingResumeTask = Task { @MainActor [weak self] in
            await self?.waitToResumeAfterBuffering(heldAt: clock)
        }
    }

    private func waitToResumeAfterBuffering(heldAt clock: CMTime) async {
        let startedAt = ContinuousClock.now
        var audioEnd = audioSink.bufferedEnd
        var audioChangedAt = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.bufferingPollInterval)
            guard !Task.isCancelled, isBuffering else { return }
            if audioSink.bufferedEnd != audioEnd {
                audioEnd = audioSink.bufferedEnd
                audioChangedAt = .now
            }
            let isAudioSettled = ContinuousClock.now - audioChangedAt >= Self.bufferingAudioSettleTime
            guard isReadyToResumeAfterBuffering(heldAt: clock, audioSettled: isAudioSettled) else { continue }
            AppLog.info(
                .engine,
                "Buffering ended after \(ContinuousClock.now - startedAt): audio "
                    + "\(String(format: "%.3f", audioAhead(of: clock)))s ahead"
                    + "\(isAudioSettled ? " (no more coming)" : ""), \(frameQueue.count) frame(s) queued"
            )
            // Cancels this task and clears `isBuffering` (through `cancelPreroll`) before restarting the clock.
            startSynchronizerClockAfterPreroll(at: clock, alignWithBufferedAudio: true)
            return
        }
    }

    /// - Parameter audioSettled: The queued audio has not changed for `bufferingAudioSettleTime`, so no more is
    ///   coming while the clock is held. Playback then resumes with what there is: above the low watermark (the
    ///   renderer is full), or with video ready, when the audio may be stuck behind the demuxer's full video packet
    ///   queue. With neither, data has stopped altogether and the clock stays held.
    private func isReadyToResumeAfterBuffering(heldAt clock: CMTime, audioSettled: Bool) -> Bool {
        guard let demuxer, !demuxer.isEOF else { return true }
        // The clock is held at rate 0; the amounts are for the rate it resumes at.
        let ahead = audioAhead(of: clock)
        let isVideoReady = !hasVideo || frameQueue.count >= Self.bufferingResumeFrames
        let isAudioReady =
            !hasAudioStream || ahead >= Self.bufferingResumeAudio * playbackRate
            || (audioSettled && (ahead > Self.bufferingAudioLowWatermark * playbackRate || (hasVideo && isVideoReady)))
        return isAudioReady && isVideoReady
    }

    /// Ends buffering without restarting the clock; whoever calls it re-anchors or stops the clock itself.
    func cancelBuffering() {
        bufferingResumeTask?.cancel()
        bufferingResumeTask = nil
        if isBuffering {
            isBuffering = false
        }
    }
}

extension PlayerEngine {
    /// Timeline second up to which media has been read ahead of playback: at least `currentTime`, and `duration`
    /// once the input has been read to its end. The demuxer reads a few seconds ahead (its packet queues and the
    /// frame queue), so this is no download progress. Not observable; read it with `onTimeUpdate`.
    public var bufferedTime: Double {
        guard let demuxer, isLoaded else { return currentTime }
        let readAhead = demuxer.readAheadSeconds
        if readAhead == .infinity {
            return duration > 0 ? duration : currentTime
        }
        let buffered = max(currentTime, readAhead)
        return duration > 0 ? min(buffered, duration) : buffered
    }
}
