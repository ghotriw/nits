@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

extension PlayerEngine {
    /// Switches the audio track and re-reads the media from the current frame.
    ///
    /// The demuxer reads all tracks from one position, ahead of the clock by what is buffered (decoded video, queued
    /// packets). Packets of the new track before that position were skipped, so continuing from there started the
    /// new track up to a second ahead of the picture, further with every switch. An exact seek to the current frame
    /// re-reads both from there (as mpv does); the seek keeps playing or paused as it was.
    public func selectAudioTrack(id: Int) {
        if id == selectedAudioTrackId, let inputs, inputs.isAudioSelectionAutomatic {
            // Choosing the track picked on load keeps it for the file, whatever the language settings become.
            inputs.keepAudioSelection()
            saveCurrentPlaybackProgress()
            return
        }
        // Checked before feeding stops: a track that isn't there must leave the one playing heard.
        guard let inputs, id != selectedAudioTrackId, inputs.audioTracks.contains(where: { $0.id == id }) else {
            return
        }
        AppLog.info(.audio, "Switching to audio track: \(id)")

        stopFeedingAudio()
        inputs.selectAudioTrack(id: id)
        self.selectedAudioTrackId = id
        saveCurrentPlaybackProgress()
        if let input = inputs.audioSource?.audioDecoderInput() {
            let decoder = FFAudioDecoder(codecParameters: input.parameters, timebase: input.timebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        } else {
            self.audioDecoder = nil
        }

        seek(to: rereadPosition, exact: true)
    }

    /// Adds audio files as tracks of the media playing (a dub, a commentary) and selects the first track of the last
    /// file that could be read; a file added before (or being added) is reused. Files open off the main actor, as one
    /// may be on a network volume; the added tracks and the selection are reported once (`onTracksChanged`). Returns
    /// the track selected: `nil` when no file could be read, or another media was loaded meanwhile.
    @discardableResult
    public func loadExternalAudio(urls: [URL]) async -> MediaDemuxer.AudioTrack? {
        guard let inputs else { return nil }
        var chosen: MediaDemuxer.AudioTrack?
        for url in urls {
            if let first = await inputs.openExternalAudio(url: url).first { chosen = first }
        }
        guard self.inputs === inputs, let chosen else { return nil }
        deferringTracksChanged {
            audioTracks = inputs.audioTracks
            selectAudioTrack(id: chosen.id)
        }
        return chosen
    }

    /// Adds the audio tracks of a file to the media playing (`PlaybackInputs.openExternalAudio`), none selected.
    /// Returns them: none when the file can't be read, or another media was loaded meanwhile.
    @discardableResult
    func attachExternalAudio(url: URL, headers: [String: String] = [:]) async -> [MediaDemuxer.AudioTrack] {
        guard let inputs else { return [] }
        let added = await inputs.openExternalAudio(url: url, headers: headers)
        guard self.inputs === inputs, !added.isEmpty else { return [] }
        audioTracks = inputs.audioTracks
        return added
    }

    /// Where a seek that re-reads the media from the current frame goes (a track switch, a new decoder). A seek still
    /// in flight keeps its target: the re-read must not pull playback back to the frame before it.
    var rereadPosition: Double {
        chaseTargetTime
            ?? (media.hasVideo && currentFramePTS >= 0 ? currentFramePTS : synchronizer.currentTime().seconds)
    }

    /// Switches the HLS variant. Read on demand, without a seek: the demuxer splices at the new variant's first
    /// keyframe, so the picture changes once what is already buffered has played (`variantDidChange(to:)`). Read
    /// ahead (network sources), that splice would come only after the read-ahead has played, up to half a minute on:
    /// the switch seeks to the current frame instead, as an audio track switch does.
    ///
    /// Choosing the variant playing keeps it: adaptive bitrate stops, and what it switched to further ahead is dropped.
    public func selectVariant(id: Int) {
        guard let demuxer, variants.contains(where: { $0.id == id && $0.isSwitchable }) else { return }
        // Read ahead, other pictures may already be read past the ones playing.
        let readsAnother = demuxer.selectedVariantId != id || !pendingVariantChanges.isEmpty
        guard id != selectedVariantId || isVariantAutomatic || readsAnother else { return }
        demuxer.selectVariant(id: id)
        selectedVariantId = id
        isVariantAutomatic = false
        if demuxer.readsAhead, readsAnother {
            seek(to: rereadPosition, exact: true)
        }
    }

    /// Lets adaptive bitrate choose the variant again (read ahead only: it needs the read-ahead's measurements).
    public func selectAutomaticVariant() {
        guard let demuxer, canSelectAutomaticVariant, !isVariantAutomatic else { return }
        demuxer.setAdaptiveBitrate(true)
        isVariantAutomatic = true
    }

    /// The demuxer reads a variant's pictures for the timeline from `change.seconds` on. Read ahead, that is up to
    /// the read-ahead limit past playback: the change waits for playback to get there (`applyDueVariantChanges`), and
    /// replaces the changes after it that were read before a seek.
    func variantWillPlay(_ change: MediaDemuxer.VariantChange) {
        guard demuxer?.readsAhead == true else {
            variantDidChange(to: change)
            return
        }
        pendingVariantChanges.removeAll { $0.seconds >= change.seconds }
        pendingVariantChanges.append(change)
        // During a seek, what is due by its target: a seek reports the variant it reads from there, while a switch
        // the read-ahead thread made further on still waits for playback.
        applyDueVariantChanges(at: (chaseTargetTime ?? currentTime) + 0.1)
    }

    /// Applies the variant changes due by timeline second `seconds`.
    func applyDueVariantChanges(at seconds: Double) {
        while let first = pendingVariantChanges.first, first.seconds <= seconds {
            pendingVariantChanges.removeFirst()
            variantDidChange(to: first)
        }
    }

    /// A variant's pictures play now: its size, pixel aspect and frame rate (a ladder can mix 30 and 60 fps, and the
    /// display link is matched to the content).
    func variantDidChange(to change: MediaDemuxer.VariantChange) {
        selectedVariantId = change.variant.id
        // In one write, so observers never see one variant's width with another's height.
        var video = media.video
        if change.width > 0, change.height > 0 {
            video.width = change.width
            video.height = change.height
        }
        video.sampleAspectRatio = change.sampleAspectRatio
        media.video = video
        let frameDuration =
            decoder.outputsFieldRate
            ? FieldTiming.fieldDuration(ofFrameDuration: change.frameDuration) : change.frameDuration
        if frameDuration != nominalFrameDuration {
            nominalFrameDuration = frameDuration
            nominalFrameDurationLock.withLock { $0 = frameDuration }
            updateDisplayLinkFrameRate()
        }
    }

    /// Shifts audio against the picture by `seconds` (clamped to `audioDelayRange`, rounded to milliseconds) and saves
    /// the delay for the file.
    ///
    /// Takes effect without re-reading the media: the renderer is flushed and the audio it held is enqueued again
    /// with the new shift, followed by what was decoded but not yet delivered (see `DelayedAudioSink`).
    public func setAudioDelay(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let range = Self.audioDelayRange
        let clamped = min(max((seconds * 1000).rounded() / 1000, range.lowerBound), range.upperBound)
        guard clamped != audioDelay else { return }
        audioDelay = clamped
        AppLog.info(.audio, "Audio delay changed to \(clamped)s")
        applyAudioDelay()
        saveCurrentPlaybackProgress()
    }

    public func stepAudioDelay(by delta: Double) {
        setAudioDelay(audioDelay + delta)
    }

    public func resetAudioDelay() {
        setAudioDelay(0)
    }

    private func applyAudioDelay() {
        let delay = CMTime(seconds: audioDelay, preferredTimescale: 1_000_000)
        guard demuxer != nil, let decoder = audioDecoder else {
            audioSink.setDelay(delay)
            return
        }
        // Restarted even when paused: the run then feeds nothing, but `prepare` still moves the audio. A seek in
        // flight flushes it all again and reads audio from its target with the new delay.
        stopFeedingAudio()
        let sink = audioSink
        let synchronizer = self.synchronizer
        let generation = decoder.generation
        startFeedingAudio {
            let replay = sink.changeDelay(to: delay, keepingAudioAfter: synchronizer.currentTime())
            decoder.requeue(replay, generation: generation)
        }
    }
}

extension PlayerEngine {
    /// Reports a change of the tracks or their selection through `onTracksChanged`, or marks it while deferred.
    func tracksDidChange() {
        if tracksChangedDeferralDepth > 0 {
            hasDeferredTracksChange = true
        } else {
            reportTracksChanged()
        }
    }

    /// Holds back track change reports until the matching `endDeferringTracksChanged()`; nests.
    func beginDeferringTracksChanged() {
        tracksChangedDeferralDepth += 1
    }

    func endDeferringTracksChanged() {
        tracksChangedDeferralDepth = max(tracksChangedDeferralDepth - 1, 0)
        if tracksChangedDeferralDepth == 0, hasDeferredTracksChange {
            hasDeferredTracksChange = false
            reportTracksChanged()
        }
    }

    /// Reports a track clear a load owes (`tracksClearedUnreported`), for the paths that end it without new tracks.
    func reportClearedTracksIfOwed() {
        if tracksClearedUnreported { tracksDidChange() }
    }

    private func reportTracksChanged() {
        tracksClearedUnreported = false
        onTracksChanged?()
    }
}

extension PlayerEngine: SubtitleHost {
    var clockSeconds: Double { synchronizer.currentTime().seconds }

    var subtitleVideo: SubtitleVideo {
        SubtitleVideo(
            width: media.video.width, height: media.video.height, sampleAspectRatio: media.video.sampleAspectRatio,
            geometry: videoGeometry,
            frameDuration: nominalFrameDuration)
    }

    var isPresentingContinuously: Bool {
        isPlaying && isLoaded && !isLoading && !isSeeking && chaseTargetTime == nil
    }

    func rereadFromCurrentFrame() {
        seek(to: rereadPosition, exact: true)
    }

    func deferringTracksChanged(_ body: () -> Void) {
        beginDeferringTracksChanged()
        defer { endDeferringTracksChanged() }
        body()
    }
}
