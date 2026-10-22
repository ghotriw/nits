import Foundation

// MARK: - Subtitle files

extension SubtitleController {
    public func addExternal(url: URL) {
        addExternal(urls: [url])
    }

    /// Adds subtitle files as tracks and selects the last one that could be read; files already added are reused.
    public func addExternal(urls: [URL]) {
        let addAndSelect = {
            guard let trackId = urls.flatMap({ self.addExternalFile(url: $0) }).last else { return }
            self.select(trackId: trackId)
        }
        // The added tracks and the selection are reported once.
        if let host { host.deferringTracksChanged(addAndSelect) } else { addAndSelect() }
    }

    /// Adds a subtitle file as tracks (several for a VobSub index with more than one language), or finds the ones
    /// already made from it; empty if the file can't be read.
    func addExternalFile(url: URL) -> [Int] {
        // A VobSub `.sub` loads through its `.idx`, whichever of the two was picked.
        // One with no index is MicroDVD or SubViewer text, which FFmpeg reads (VobSub data on its own reads as none).
        let url = SidecarSubtitles.vobSubIndex(forDataFile: url) ?? url
        if SidecarSubtitles.isBitmapSubtitleFile(url) { return addExternalBitmapFile(url: url) }
        return addExternalTextFile(url: url).map { [$0] } ?? []
    }

    /// Adds a PGS (`.sup`) or VobSub (`.idx`) file. Its pictures are read when a track is selected.
    private func addExternalBitmapFile(url: URL) -> [Int] {
        let url = url.standardizedFileURL
        let existing = tracks.filter { $0.externalURL == url }
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
            let id = 1000 + tracks.count
            let language = stream.language.isEmpty ? (tags.language ?? "und") : stream.language
            tracks.append(
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

    /// What tells the encoding of a subtitle file besides its bytes: the user's choice and the language in its name.
    func textEncodingHints(for url: URL) -> TextFileEncoding.Hints {
        TextFileEncoding.Hints(encoding: settings.encoding, language: SidecarSubtitles.tags(of: url).language)
    }

    /// Adds a text subtitle file as a track, or finds the track already made from it; `nil` if the file can't be read.
    /// SRT, WebVTT and ASS files are parsed here; the formats FFmpeg reads (`FFmpegTextSubtitles`) only have their
    /// beginning looked at, and are read in the background when the track is selected.
    func addExternalTextFile(url: URL) -> Int? {
        let url = url.isFileURL ? url.standardizedFileURL : url
        if let existing = tracks.first(where: { $0.externalURL == url }) {
            return existing.id
        }

        let fileExtension = url.pathExtension.lowercased()
        let isASS = fileExtension == "ass" || fileExtension == "ssa"
        var document: SubtitleDocument?
        if FFmpegTextSubtitles.extensions.contains(fileExtension) {
            guard FFmpegTextSubtitles.isReadable(url, hints: textEncodingHints(for: url)) else {
                AppLog.warning(
                    .subtitles, "No subtitles in a format FFmpeg reads (MicroDVD, SubViewer, SAMI) in \(url.path)")
                return nil
            }
        } else {
            guard let data = try? Data(contentsOf: url),
                let content = TextFileEncoding.decode(data, hints: textEncodingHints(for: url))
            else {
                AppLog.error(.subtitles, "Unable to decode subtitle file with supported encodings: \(url)")
                return nil
            }
            let isVTT = fileExtension == "vtt" || content.text.hasPrefix("WEBVTT")
            document =
                isASS
                ? SubtitleDocument.parseASS(content.text)
                : (isVTT ? SubtitleDocument.parseWebVTT(content.text) : SubtitleDocument.parseSRT(content.text))
        }

        let trackId = 1000 + tracks.count
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
        tracks.append(track)
        loadedDocuments[trackId] = document
        return trackId
    }

    /// Adds the subtitle files next to a local media file as tracks (see `SidecarSubtitles`).
    func addSidecarFiles(for path: String) {
        guard !MediaURL.isNetworkURL(path) else { return }
        let mediaURL = URL(string: path).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: path)
        let ids = SidecarSubtitles.urls(for: mediaURL).flatMap { addExternalFile(url: $0) }
        if !ids.isEmpty {
            AppLog.info(.subtitles, "Found \(ids.count) subtitle file(s) next to the media")
        }
    }
}
