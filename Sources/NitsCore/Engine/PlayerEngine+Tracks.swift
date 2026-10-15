@preconcurrency import AVFoundation
import AppKit
@preconcurrency import CoreMedia
import Foundation

extension PlayerEngine {
    public func selectAudioTrack(id: Int) {
        guard let demuxer = self.demuxer else { return }
        AppLog.info(.audio, "Switching to audio track: \(id)")
        let wasPlaying = isPlaying
        pause()

        // Stop requesting data and flush renderers
        stopFeedingAudio()
        audioSink.flush()
        audioDecoder?.flush()

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

        if wasPlaying {
            play()
        }
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
            return
        }

        let isVTT = url.pathExtension.lowercased() == "vtt" || validContent.hasPrefix("WEBVTT")
        let document = isVTT ? SubtitleDocument.parseWebVTT(validContent) : SubtitleDocument.parseSRT(validContent)

        let trackId = 1000 + subtitleTracks.count
        let trackName = url.deletingPathExtension().lastPathComponent
        let track = SubtitleTrack(
            id: trackId,
            streamIndex: -1,
            title: "\(trackName) (External)",
            language: "und",
            isExternal: true
        )
        subtitleTracks.append(track)
        loadedSubtitleDocuments[trackId] = document
        selectSubtitleTrack(id: trackId)
    }

    func updateActiveSubtitles(at seconds: Double) {
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
