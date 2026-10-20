@preconcurrency import AVFoundation
import AppKit
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
        guard let demuxer = self.demuxer, id != selectedAudioTrackId, audioTracks.contains(where: { $0.id == id })
        else { return }
        AppLog.info(.audio, "Switching to audio track: \(id)")

        stopFeedingAudio()
        demuxer.selectAudioTrack(trackId: id)
        self.selectedAudioTrackId = id
        saveCurrentPlaybackProgress()
        if let params = demuxer.getAudioCodecParameters() {
            let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        } else {
            self.audioDecoder = nil
        }

        // A seek still in flight keeps its target: the switch must not pull playback back to the frame before it.
        let position =
            chaseTargetTime
            ?? (hasVideo && currentFramePTS >= 0 ? currentFramePTS : synchronizer.currentTime().seconds)
        seek(to: position, exact: true)
    }

    public func selectSubtitleTrack(id: Int?) {
        selectSubtitleTrack(id: id, persistHistory: true)
    }

    func selectSubtitleTrack(id: Int?, persistHistory: Bool) {
        guard let id else {
            // Disable subtitles
            cancelSubtitleLoads()
            self.selectedSubtitleTrackId = nil
            self.activeSubtitleDocument = nil
            self.currentSubtitleCues.removeAll()
            self.currentSubtitleImages.removeAll()
            self.lastObservedLiveSubtitleVersion = -1
            demuxer?.selectSubtitleTrack(trackId: nil)
            if persistHistory {
                saveCurrentPlaybackProgress()
            }
            return
        }

        guard let track = subtitleTracks.first(where: { $0.id == id }) else { return }
        // Skipping through tracks must not leave a whole-file read running for each one passed.
        cancelSubtitleLoads(except: id)
        self.selectedSubtitleTrackId = id
        // The previous track's cues (and libass script) go until this one's document is there.
        self.activeSubtitleDocument = nil
        self.currentSubtitleCues = []
        self.currentSubtitleImages = []
        demuxer?.selectSubtitleTrack(trackId: id)
        if persistHistory {
            saveCurrentPlaybackProgress()
        }

        if track.isExternal {
            self.activeSubtitleDocument = loadedSubtitleDocuments[id]
            self.updateActiveSubtitles(at: currentTime)
            if activeSubtitleDocument == nil, track.format == .bitmap, let url = track.externalURL {
                let streamIndex = track.streamIndex
                // Pictures are read when the track is selected, as the pictures of a DVD run to tens of megabytes.
                loadSubtitleDocument(trackId: id) { interrupt in
                    EmbeddedSubtitleReader.extractEmbeddedSubtitles(
                        url: url.path, headers: [:], streamIndex: streamIndex, interrupt: interrupt)
                } isCurrent: { engine in
                    // Another file may have been opened meanwhile, with tracks of the same ids.
                    engine.subtitleTracks.contains {
                        $0.id == id && $0.externalURL == url && $0.streamIndex == streamIndex
                    }
                }
            }
        } else if let path = currentPath {
            if MediaURL.isNetworkURL(path) {
                // For network streams: bind immediately to in-band demuxed cues.
                // Do NOT launch a background secondary demuxer that hangs trying to reach EOF or fails on single-token URLs.
                let liveDoc = demuxer?.getLiveSubtitleDocument() ?? SubtitleDocument(cues: [])
                self.lastObservedLiveSubtitleVersion = demuxer?.liveSubtitleVersion ?? -1
                self.activeSubtitleDocument = liveDoc
                self.updateActiveSubtitles(at: currentTime)
                AppLog.info(
                    .subtitles,
                    "Selected network subtitle track id=\(id) ('\(track.title)'). Active in-band streaming."
                )
            } else if let cached = loadedSubtitleDocuments[id] {
                self.activeSubtitleDocument = cached
                self.updateActiveSubtitles(at: currentTime)
            } else {
                let headers = self.currentHeaders
                let demuxer = self.demuxer
                loadSubtitleDocument(trackId: id) { interrupt in
                    demuxer?.loadSubtitleDocument(for: id, url: path, headers: headers, interrupt: interrupt)
                } isCurrent: { engine in
                    // Track ids restart with every file: a result is only for the demuxer it was asked of.
                    engine.demuxer === demuxer
                }
            }
        }
    }

    public func loadExternalSubtitle(url: URL) {
        loadExternalSubtitles(urls: [url])
    }

    /// Adds subtitle files as tracks and selects the last one that could be read; files already added are reused.
    public func loadExternalSubtitles(urls: [URL]) {
        // The added tracks and the selection are reported once.
        beginDeferringTracksChanged()
        defer { endDeferringTracksChanged() }
        guard let trackId = urls.flatMap({ addExternalSubtitles(url: $0) }).last else { return }
        selectSubtitleTrack(id: trackId)
    }

    /// Adds a subtitle file as tracks (several for a VobSub index with more than one language), or finds the ones
    /// already made from it; empty if the file can't be read.
    func addExternalSubtitles(url: URL) -> [Int] {
        // A VobSub `.sub` loads through its `.idx`, whichever of the two was picked.
        let url = SidecarSubtitles.vobSubIndex(forDataFile: url) ?? url
        // One with no index is MicroDVD text or VobSub data on its own. Read as text, any bytes decode (Latin-1) into
        // a track with no cues.
        guard !SidecarSubtitles.isUnsupportedSubtitleFile(url) else {
            AppLog.warning(.subtitles, "Unsupported subtitle file (a .sub with no .idx next to it): \(url.path)")
            return []
        }
        if SidecarSubtitles.isBitmapSubtitleFile(url) { return addExternalBitmapSubtitles(url: url) }
        return addExternalSubtitle(url: url).map { [$0] } ?? []
    }

    /// Adds a PGS (`.sup`) or VobSub (`.idx`) file. Its pictures are read when a track is selected.
    private func addExternalBitmapSubtitles(url: URL) -> [Int] {
        let url = url.standardizedFileURL
        let existing = subtitleTracks.filter { $0.externalURL == url }
        if !existing.isEmpty { return existing.map(\.id) }

        let streams = EmbeddedSubtitleReader.bitmapSubtitleStreams(of: url)
        guard !streams.isEmpty else {
            AppLog.error(.subtitles, "No bitmap subtitle stream in \(url)")
            return []
        }
        let name = url.deletingPathExtension().lastPathComponent
        let tags = SidecarSubtitles.tags(of: url)
        var ids: [Int] = []
        for stream in streams {
            let id = 1000 + subtitleTracks.count
            let language = stream.language.isEmpty ? (tags.language ?? "und") : stream.language
            subtitleTracks.append(
                SubtitleTrack(
                    id: id,
                    streamIndex: stream.index,
                    title: streams.count > 1 ? "\(name) (\(language))" : "\(name) (External)",
                    language: language,
                    externalURL: url,
                    isForced: tags.isForced,
                    isSDH: tags.isSDH,
                    format: .bitmap
                ))
            ids.append(id)
        }
        return ids
    }

    /// A subtitle track read in the background: its task, and the interrupt that aborts the FFmpeg I/O the task may be
    /// blocked in, which cancelling the task alone wouldn't.
    struct SubtitleLoad {
        let task: Task<Void, Never>
        let interrupt: FFmpegInterrupt

        func cancel() {
            interrupt.cancel()
            task.cancel()
        }
    }

    /// Reads a track's document off the main thread and shows it if the track is still selected. Selecting the track
    /// again while it is read waits for that read. `isCurrent` says whether the result still belongs to the tracks
    /// listed when it arrives.
    private func loadSubtitleDocument(
        trackId id: Int,
        read: @escaping @Sendable (FFmpegInterrupt) -> SubtitleDocument?,
        isCurrent: @escaping @MainActor @Sendable (PlayerEngine) -> Bool
    ) {
        guard subtitleLoads[id] == nil else { return }
        let interrupt = FFmpegInterrupt()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let document = read(interrupt)
            await MainActor.run {
                guard let self else { return }
                if self.subtitleLoads[id]?.interrupt === interrupt { self.subtitleLoads[id] = nil }
                guard !interrupt.isCancelled, isCurrent(self) else { return }
                guard let document else {
                    AppLog.warning(.subtitles, "Can't read subtitle track \(id)")
                    return
                }
                self.loadedSubtitleDocuments[id] = document
                guard self.selectedSubtitleTrackId == id else { return }
                self.activeSubtitleDocument = document
                self.updateActiveSubtitles(at: self.currentTime)
            }
        }
        subtitleLoads[id] = SubtitleLoad(task: task, interrupt: interrupt)
    }

    /// Cancels the background reads of tracks other than `kept`.
    func cancelSubtitleLoads(except kept: Int? = nil) {
        for (id, load) in subtitleLoads where id != kept {
            load.cancel()
            subtitleLoads[id] = nil
        }
    }

    /// Takes the media's subtitles away: what is on screen (hosts get `[]`), the libass renderer, the documents read
    /// and the reads still running.
    func resetSubtitles() {
        cancelSubtitleLoads()
        selectedSubtitleTrackId = nil
        activeSubtitleDocument = nil
        currentSubtitleCues.removeAll()
        currentSubtitleImages.removeAll()
        loadedSubtitleDocuments.removeAll()
        lastObservedLiveSubtitleVersion = -1
    }

    /// The track of an external file to restore: the saved stream (one language of a VobSub index), else the first.
    func externalSubtitleTrack(among ids: [Int], streamIndex: Int?) -> Int? {
        guard let streamIndex else { return ids.first }
        return ids.first { id in subtitleTracks.first { $0.id == id }?.streamIndex == streamIndex } ?? ids.first
    }

    /// Adds a text subtitle file as a track, or finds the track already made from it; `nil` if the file can't be read.
    func addExternalSubtitle(url: URL) -> Int? {
        let url = url.isFileURL ? url.standardizedFileURL : url
        if let existing = subtitleTracks.first(where: { $0.externalURL == url }) {
            return existing.id
        }

        var content: String? = nil
        let encodings: [String.Encoding] = [.utf8, .windowsCP1251, .windowsCP1252, .isoLatin1, .utf16]
        for enc in encodings {
            if let str = try? String(contentsOf: url, encoding: enc) {
                content = str
                break
            }
        }

        guard let validContent = content else {
            AppLog.error(.subtitles, "Unable to decode subtitle file with supported encodings: \(url)")
            return nil
        }

        let fileExtension = url.pathExtension.lowercased()
        let isASS = fileExtension == "ass" || fileExtension == "ssa"
        let isVTT = fileExtension == "vtt" || validContent.hasPrefix("WEBVTT")
        let document =
            isASS
            ? SubtitleDocument.parseASS(validContent)
            : (isVTT ? SubtitleDocument.parseWebVTT(validContent) : SubtitleDocument.parseSRT(validContent))

        let trackId = 1000 + subtitleTracks.count
        let trackName = url.deletingPathExtension().lastPathComponent
        let tags = SidecarSubtitles.tags(of: url)
        let track = SubtitleTrack(
            id: trackId,
            streamIndex: -1,
            title: "\(trackName) (External)",
            language: tags.language ?? "und",
            externalURL: url,
            isForced: tags.isForced,
            isSDH: tags.isSDH,
            format: isASS ? .ass : .text
        )
        subtitleTracks.append(track)
        loadedSubtitleDocuments[trackId] = document
        return trackId
    }

    /// Adds the subtitle files next to a local media file as tracks (see `SidecarSubtitles`) and returns their ids.
    func addSidecarSubtitles(for path: String) -> [Int] {
        guard !MediaURL.isNetworkURL(path) else { return [] }
        let mediaURL = URL(string: path).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: path)
        let ids = SidecarSubtitles.urls(for: mediaURL).flatMap { addExternalSubtitles(url: $0) }
        if !ids.isEmpty {
            AppLog.info(.subtitles, "Found \(ids.count) subtitle file(s) next to the media")
        }
        return ids
    }

    /// The subtitle track to select when the media has none of its own: the first full (not forced) track in one of
    /// the user's preferred languages, else the first full track, else the first.
    func defaultExternalSubtitleTrackId(among ids: [Int]) -> Int? {
        let tracks = ids.compactMap { id in subtitleTracks.first { $0.id == id } }
        let fullTracks = tracks.filter { !$0.isForced }
        for preferred in Locale.preferredLanguages {
            guard let code = Locale.Language(identifier: preferred).languageCode else { continue }
            if let match = fullTracks.first(where: { Locale.Language(identifier: $0.language).languageCode == code }) {
                return match.id
            }
        }
        return (fullTracks.first ?? tracks.first)?.id
    }

    /// Shifts subtitles by `seconds` (clamped to `subtitleDelayRange`, rounded to milliseconds) and saves the delay
    /// for the file. One delay serves all of the file's subtitle tracks.
    public func setSubtitleDelay(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let range = Self.subtitleDelayRange
        let clamped = min(max((seconds * 1000).rounded() / 1000, range.lowerBound), range.upperBound)
        guard clamped != subtitleDelay else { return }
        subtitleDelay = clamped
        AppLog.info(.subtitles, "Subtitle delay changed to \(clamped)s")
        updateActiveSubtitles(at: currentTime)
        saveCurrentPlaybackProgress()
    }

    public func stepSubtitleDelay(by delta: Double) {
        setSubtitleDelay(subtitleDelay + delta)
    }

    public func resetSubtitleDelay() {
        setSubtitleDelay(0)
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

    func updateActiveSubtitles(at seconds: Double) {
        // A cue due at `t` shows at `t + subtitleDelay`.
        let seconds = seconds - subtitleDelay
        if let id = selectedSubtitleTrackId,
            let track = subtitleTracks.first(where: { $0.id == id }),
            !track.isExternal,
            let demuxer,
            let path = currentPath,
            MediaURL.isNetworkURL(path)
        {
            // For live network streams, refresh the document only when in-band cues version changes
            let currentVersion = demuxer.liveSubtitleVersion
            if currentVersion != self.lastObservedLiveSubtitleVersion || self.activeSubtitleDocument == nil {
                self.lastObservedLiveSubtitleVersion = currentVersion
                self.activeSubtitleDocument = demuxer.getLiveSubtitleDocument()
            }
            showSubtitles(of: activeSubtitleDocument, at: seconds)
            return
        }

        showSubtitles(of: activeSubtitleDocument, at: seconds)
    }

    private func showSubtitles(of document: SubtitleDocument?, at seconds: Double) {
        currentSubtitleCues = document?.activeCues(at: seconds) ?? []
        if isDrawingAuthoredSubtitles {
            renderAuthoredSubtitles(at: seconds)
            return
        }
        let images = document?.activeImageCues(at: seconds) ?? []
        if images != currentSubtitleImages { currentSubtitleImages = images }
    }
}

extension PlayerEngine {
    /// Reports a change of the tracks or their selection through `onTracksChanged`, or marks it while deferred.
    func tracksDidChange() {
        if tracksChangedDeferralDepth > 0 {
            hasDeferredTracksChange = true
        } else {
            onTracksChanged?()
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
            onTracksChanged?()
        }
    }
}

// MARK: - Authored (libass) subtitles

extension PlayerEngine {
    /// Keeps libass in step with the selected track, the setting and the size to draw at: starts its renderer for an
    /// ASS track, hands it the events a live source has read since, and drops it when it no longer applies. Nothing
    /// here waits for libass: creating the renderer (fonts) and feeding it happen off the main thread.
    func syncAuthoredSubtitles() {
        let selected = selectedSubtitleTrackId.flatMap { id in subtitleTracks.first { $0.id == id } }
        guard usesAuthoredSubtitleStyles, subtitleRenderSize.width >= 1, subtitleRenderSize.height >= 1,
            selected?.format == .ass, let script = activeSubtitleDocument?.assScript, let trackId = selected?.id
        else {
            dropAuthoredRenderer()
            return
        }

        authoredScript = script
        if authoredRendererTrackId != trackId {
            startAuthoredRenderer(for: script, trackId: trackId)
        } else {
            renderAuthoredSubtitles(at: currentTime - subtitleDelay)
        }
    }

    private func dropAuthoredRenderer() {
        guard authoredRendererTrackId != nil || isDrawingAuthoredSubtitles else { return }
        authoredGeneration += 1
        authoredRenderer = nil
        authoredRendererTrackId = nil
        authoredScript = nil
        pendingAuthoredRenderTime = nil
        isDrawingAuthoredSubtitles = false
        if !currentSubtitleImages.isEmpty { currentSubtitleImages = [] }
    }

    /// Creates the renderer in the background. The text cues stay hidden meanwhile, so a track doesn't flash as plain
    /// text before it appears styled; if libass can't read the script, the text is shown after all.
    private func startAuthoredRenderer(for script: AssScript, trackId: Int) {
        authoredGeneration += 1
        let generation = authoredGeneration
        authoredRenderer = nil
        authoredRendererTrackId = trackId
        pendingAuthoredRenderTime = nil
        isDrawingAuthoredSubtitles = true
        AppLog.info(.subtitles, "Drawing subtitle track \(trackId) with libass")
        Task.detached(priority: .userInitiated) { [weak self] in
            let renderer = AssSubtitleRenderer(script: script)
            await MainActor.run {
                guard let self, self.authoredGeneration == generation else { return }
                guard let renderer else {
                    AppLog.warning(.subtitles, "libass can't read the script of subtitle track \(trackId)")
                    self.isDrawingAuthoredSubtitles = false
                    return
                }
                self.authoredRenderer = renderer
                self.renderAuthoredSubtitles(at: self.currentTime - self.subtitleDelay)
            }
        }
    }

    /// Renders off the main thread, at most one at a time; a time asked for meanwhile is rendered next. The events
    /// read since the last render go to libass in the same task, as it may be busy with a frame.
    func renderAuthoredSubtitles(at seconds: Double) {
        guard let renderer = authoredRenderer else { return }
        guard !isAuthoredRenderRunning else {
            pendingAuthoredRenderTime = seconds
            return
        }
        isAuthoredRenderRunning = true
        let size = subtitleRenderSize
        let video = (width: videoWidth, height: videoHeight)
        // The pixel aspect of the video's own pixels: ASS coordinates are in them, the frame is in square ones.
        let pixelAspect = sampleAspectRatio.multiplier
        let events = authoredScript?.events ?? []
        Task.detached(priority: .userInitiated) { [weak self] in
            renderer.addEvents(events)
            renderer.configure(
                frameWidth: Int(size.width.rounded()), frameHeight: Int(size.height.rounded()), videoWidth: video.width,
                videoHeight: video.height, pixelAspect: pixelAspect)
            let output = renderer.render(at: seconds)
            await MainActor.run {
                guard let self else { return }
                self.isAuthoredRenderRunning = false
                // A frame of a renderer since replaced is dropped, but a time asked for meanwhile is still rendered
                // (by the current renderer): paused, nothing else would draw it.
                if renderer === self.authoredRenderer, case .frame(let cue) = output {
                    self.currentSubtitleImages = cue.map { [$0] } ?? []
                }
                if let next = self.pendingAuthoredRenderTime {
                    self.pendingAuthoredRenderTime = nil
                    self.renderAuthoredSubtitles(at: next)
                }
            }
        }
    }
}
