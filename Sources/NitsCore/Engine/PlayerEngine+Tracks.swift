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
        guard let demuxer = self.demuxer else { return }
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
            self.selectedSubtitleTrackId = nil
            self.activeSubtitleDocument = nil
            self.currentSubtitleCues.removeAll()
            self.lastObservedLiveSubtitleVersion = -1
            demuxer?.selectSubtitleTrack(trackId: nil)
            if persistHistory {
                saveCurrentPlaybackProgress()
            }
            return
        }

        guard let track = subtitleTracks.first(where: { $0.id == id }) else { return }
        self.selectedSubtitleTrackId = id
        demuxer?.selectSubtitleTrack(trackId: id)
        if persistHistory {
            saveCurrentPlaybackProgress()
        }

        if track.isExternal {
            self.activeSubtitleDocument = loadedSubtitleDocuments[id]
            self.updateActiveSubtitles(at: currentTime)
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
                Task.detached(priority: .userInitiated) { [weak self, demuxer, path, headers] in
                    let doc = demuxer?.loadSubtitleDocument(for: id, url: path, headers: headers)
                    await MainActor.run {
                        guard let self, self.selectedSubtitleTrackId == id else { return }
                        if let doc {
                            self.loadedSubtitleDocuments[id] = doc
                            self.activeSubtitleDocument = doc
                            self.updateActiveSubtitles(at: self.currentTime)
                        } else {
                            AppLog.warning(
                                .subtitles,
                                "Warning: Failed to extract embedded subtitle document for track id=\(id)"
                            )
                        }
                    }
                }
            }
        }
    }

    public func loadExternalSubtitle(url: URL) {
        guard let trackId = addExternalSubtitle(url: url) else { return }
        selectSubtitleTrack(id: trackId)
    }

    /// Adds a subtitle file as a track, or finds the track already made from it; `nil` if the file can't be read.
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

        let isVTT = url.pathExtension.lowercased() == "vtt" || validContent.hasPrefix("WEBVTT")
        let document = isVTT ? SubtitleDocument.parseWebVTT(validContent) : SubtitleDocument.parseSRT(validContent)

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
            isSDH: tags.isSDH
        )
        subtitleTracks.append(track)
        loadedSubtitleDocuments[trackId] = document
        return trackId
    }

    /// Adds the subtitle files next to a local media file as tracks (see `SidecarSubtitles`) and returns their ids.
    func addSidecarSubtitles(for path: String) -> [Int] {
        guard !MediaURL.isNetworkURL(path) else { return [] }
        let mediaURL = URL(string: path).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: path)
        let ids = SidecarSubtitles.urls(for: mediaURL).compactMap { addExternalSubtitle(url: $0) }
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
            if let doc = self.activeSubtitleDocument {
                self.currentSubtitleCues = doc.activeCues(at: seconds)
            } else {
                self.currentSubtitleCues = []
            }
            return
        }

        if let doc = self.activeSubtitleDocument {
            self.currentSubtitleCues = doc.activeCues(at: seconds)
        } else {
            self.currentSubtitleCues = []
        }
    }
}
