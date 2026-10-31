import Foundation

// MARK: - Subtitle files

/// What `SubtitleController.addExternal(urls:)` came to.
public enum AddedSubtitleFiles: Sendable, Equatable {
    /// The track selected: of the last file that could be read.
    case selected(SubtitleTrack)
    /// None of the files could be read.
    case unreadable
    /// Other media loaded while they were read: not added.
    case mediaChanged
}

extension SubtitleController {
    @discardableResult
    public func addExternal(url: URL) async -> AddedSubtitleFiles {
        await addExternal(urls: [url])
    }

    /// Adds subtitle files as tracks and selects the last one that could be read; files already added are reused, not
    /// read again. Local files are read off the main actor (`MediaSubtitleFiles`); not added if other media loads
    /// meanwhile.
    @discardableResult
    public func addExternal(urls: [URL]) async -> AddedSubtitleFiles {
        await addExternal(urls: urls, asSecondary: false)
    }

    /// `addExternal(urls:)`, the last file shown as the second track (`SecondarySubtitles`) rather than the main one;
    /// `.unreadable` also when it can't be (pictures).
    func addExternal(urls: [URL], asSecondary: Bool) async -> AddedSubtitleFiles {
        let generation = mediaGeneration
        let lookup = MediaSubtitleFiles.Lookup(
            requested: urls.filter(\.isFileURL).map { MediaLoadRequest.SubtitleFile(url: $0) },
            encoding: settings.encoding, fileEncodings: fileEncodings(), listed: Set(tracks.compactMap(\.externalURL)))
        let read = await Task.detached(priority: .userInitiated) { MediaSubtitleFiles.read(lookup) }.value
        guard mediaGeneration == generation else {
            AppLog.info(.subtitles, "Subtitle files read for media no longer loaded: not added")
            return .mediaChanged
        }
        var selected: Int?
        let addAndSelect = {
            let ids = urls.flatMap { url -> [Int] in
                guard url.isFileURL else { return self.addNetworkFile(url: url) }
                if let file = read[url] { return self.addReadFile(file) }
                // Listed already, not read again.
                guard let target = read.target(of: url) else { return [] }
                return self.tracks.filter { $0.externalURL == target }.map(\.id)
            }
            guard let trackId = ids.last else { return }
            if asSecondary {
                self.secondary.select(trackId: trackId)
                guard self.secondary.selectedTrackId == trackId else { return }
            } else {
                self.select(trackId: trackId)
            }
            selected = trackId
        }
        // The added tracks and the selection are reported once.
        if let host { host.deferringTracksChanged(addAndSelect) } else { addAndSelect() }
        guard let track = selected.flatMap({ id in tracks.first { $0.id == id } }) else { return .unreadable }
        return .selected(track)
    }

    /// Lists a network subtitle file as a track, or finds the one already made from it; it is downloaded when
    /// selected (`RemoteSubtitle`), off the main actor.
    func addNetworkFile(url: URL) -> [Int] {
        // Tagged by its name, as a local file is. Without the media's headers: it may be on another host.
        let tags = SidecarSubtitles.tags(of: url)
        let file = MediaLoadRequest.SubtitleFile(
            url: url, title: "\(url.deletingPathExtension().lastPathComponent) (External)",
            language: tags.language, headers: [:], isForced: tags.isForced, isSDH: tags.isSDH)
        addSubtitleFiles([file], defaultHeaders: [:], read: MediaSubtitleFiles())
        return tracks.filter { $0.externalURL == url }.map(\.id)
    }

    /// Lists a local file `SubtitleFileRead` read as tracks, as `file` says when given, or finds those already made
    /// from it; empty if it couldn't be read.
    @discardableResult
    func addReadFile(_ read: SubtitleFileRead, file: MediaLoadRequest.SubtitleFile? = nil) -> [Int] {
        let url = read.url
        let existing = tracks.filter { $0.externalURL == url }
        if !existing.isEmpty { return existing.map(\.id) }
        let tags = SidecarSubtitles.tags(of: url)
        let name = url.deletingPathExtension().lastPathComponent
        switch read.content {
        case nil:
            return []
        case .bitmap(let streams):
            let name = file?.title ?? name
            var ids: [Int] = []
            for stream in streams {
                let id = 1000 + tracks.count
                let language = stream.language.isEmpty ? (file?.language ?? tags.language ?? "und") : stream.language
                let title =
                    streams.count > 1
                    ? "\(name) (\(language))" : (file?.title ?? "\(name) (External)")
                tracks.append(
                    SubtitleTrack(
                        id: id,
                        streamIndex: stream.index,
                        title: title,
                        language: language,
                        externalURL: url,
                        isForced: tags.isForced || file?.isForced == true,
                        isSDH: tags.isSDH || file?.isSDH == true,
                        isAutoGenerated: file?.isAutoGenerated == true,
                        format: .bitmap
                    ))
                ids.append(id)
            }
            return ids
        case .document, .ffmpegText:
            var document: SubtitleDocument?
            if case .document(let parsed) = read.content { document = parsed }
            let trackId = 1000 + tracks.count
            tracks.append(
                SubtitleTrack(
                    id: trackId,
                    streamIndex: -1,
                    title: file?.title ?? "\(name) (External)",
                    language: file?.language ?? tags.language ?? "und",
                    externalURL: url,
                    isForced: tags.isForced || file?.isForced == true,
                    isSDH: tags.isSDH || file?.isSDH == true,
                    isAutoGenerated: file?.isAutoGenerated == true,
                    format: SubtitleFileRead.isASS(url, file: file) || document?.assScript != nil ? .ass : .text
                ))
            loadedDocuments[trackId] = document
            return [trackId]
        }
    }

    /// What tells the encoding of a subtitle file besides its bytes: the user's choice and the language of its track
    /// (`language`), else the one in its name.
    func textEncodingHints(for track: SubtitleTrack, url: URL) -> TextFileEncoding.Hints {
        Self.textEncodingHints(for: url, language: track.language, encoding: effectiveEncoding(of: track))
    }

    /// `textEncodingHints(for:language:)` with the user's choice `encoding`.
    nonisolated static func textEncodingHints(
        for url: URL, language: String?, encoding: String.Encoding?
    ) -> TextFileEncoding.Hints {
        let given = language.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0 == "und" || $0.isEmpty ? nil : $0 }
        let effectiveLanguage = given ?? (url.isFileURL ? SidecarSubtitles.tags(of: url).language : nil)
        return TextFileEncoding.Hints(encoding: encoding, language: effectiveLanguage)
    }

    /// Adds the subtitle files of a load request or resolved page (`MediaLoadRequest.subtitleFiles`). Local files are
    /// listed as `read` read them (a file it hasn't is read here, on the calling actor); network ones are listed
    /// without being downloaded until their track is selected.
    func addSubtitleFiles(
        _ files: [MediaLoadRequest.SubtitleFile], defaultHeaders: [String: String],
        read: MediaSubtitleFiles, reusing cachedDocuments: [URL: SubtitleDocument] = [:]
    ) {
        for var file in files {
            // A blank language is none: "und" for a network file, the one its name tags for a local one.
            if file.language?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { file.language = nil }
            if file.url.isFileURL {
                addReadFile(
                    read[file.url]
                        ?? SubtitleFileRead.read(
                            file.url, file: file,
                            encoding: fileEncodings()[file.url.standardizedFileURL.path] ?? settings.encoding),
                    file: file)
                continue
            }
            if tracks.contains(where: { $0.externalURL == file.url }) { continue }
            let ext = file.url.pathExtension.lowercased()
            // Pictures are read by FFmpeg from a file of its own (`EmbeddedSubtitleReader`).
            guard !SidecarSubtitles.bitmapExtensions.contains(ext) else {
                AppLog.warning(.subtitles, "Bitmap subtitles over the network aren't supported: \(file.url)")
                continue
            }
            let trackId = 1000 + tracks.count
            let cached = cachedDocuments[file.url]
            let format: SubtitleFormat =
                (file.format == .ass || ext == "ass" || ext == "ssa" || cached?.assScript != nil) ? .ass : .text
            let language = file.language ?? "und"
            let title =
                file.title
                ?? Self.fallbackTitle(
                    language: language, isAutoGenerated: file.isAutoGenerated, number: tracks.count + 1)
            let (inferredForced, inferredSDH) = MediaDemuxer.subtitleFlags(title: title, disposition: 0)
            tracks.append(
                SubtitleTrack(
                    id: trackId,
                    streamIndex: -1,
                    title: title,
                    language: language,
                    externalURL: file.url,
                    isForced: file.isForced || inferredForced,
                    isSDH: file.isSDH || inferredSDH,
                    isAutoGenerated: file.isAutoGenerated,
                    format: format
                ))
            externalHeaders[trackId] = file.headers ?? defaultHeaders
            if let cached {
                loadedDocuments[trackId] = cached
            }
        }
    }

    /// The title of a network file given none: its language's name in the user's ("English (auto-generated)").
    static func fallbackTitle(language: String, isAutoGenerated: Bool, number: Int) -> String {
        guard language != "und", !language.isEmpty else { return "Subtitle \(number)" }
        let name =
            Locale.current.localizedString(forIdentifier: language)?.capitalized(with: .current)
            ?? language.uppercased()
        return isAutoGenerated ? "\(name) (auto-generated)" : name
    }

    /// Decodes `data` into a `SubtitleDocument` as ASS, WebVTT, or SRT; `nil` for bytes that aren't text.
    /// `collapsingRollUp` is for auto-generated WebVTT captions (`SubtitleDocument.parseWebVTT`).
    nonisolated static func parseTextSubtitle(
        data: Data, url: URL, format: SubtitleFormat, collapsingRollUp: Bool = false, hints: TextFileEncoding.Hints
    ) -> SubtitleDocument? {
        guard !TextFileEncoding.looksBinary(data),
            let content = TextFileEncoding.decode(data, hints: hints)
        else { return nil }
        let text = content.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = url.pathExtension.lowercased()
        if format == .ass || ext == "ass" || ext == "ssa" || trimmed.hasPrefix("[Script Info]") {
            return SubtitleDocument.parseASS(text)
        }
        if ext == "vtt" || trimmed.hasPrefix("WEBVTT") {
            return SubtitleDocument.parseWebVTT(text, collapsingRollUp: collapsingRollUp)
        }
        return SubtitleDocument.parseSRT(text)
    }

    /// Adds the subtitle files found next to a local media file as tracks (`MediaSubtitleFiles.sidecars`).
    func addSidecarFiles(_ read: MediaSubtitleFiles) {
        let ids = read.sidecars.flatMap { url in read[url].map { addReadFile($0) } ?? [] }
        if !ids.isEmpty {
            AppLog.info(.subtitles, "Found \(ids.count) subtitle file(s) next to the media")
        }
    }
}

// MARK: - Encoding

extension SubtitleController {
    /// Whether the text encoding of `trackId` can be chosen: a text file
    public func canSetEncoding(ofTrack trackId: Int?) -> Bool {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return false }
        // A file of its own: tracks of a container (`streamIndex` names one) are UTF-8, and the choice is by file.
        return track.isExternal && track.streamIndex < 0 && track.format != .bitmap
    }

    /// The encoding the user chose for `trackId`'s file; `nil` for the default (`settings.encoding`, else detected).
    public func encoding(ofTrack trackId: Int?) -> String.Encoding? {
        tracks.first(where: { $0.id == trackId }).flatMap { trackEncodings[key(of: $0)] }
    }

    /// What `track`'s file is read in unless its bytes tell: its own choice, else the default.
    func effectiveEncoding(of track: SubtitleTrack) -> String.Encoding? {
        trackEncodings[key(of: track)] ?? settings.encoding
    }

    /// Reads the file of `trackId` in `encoding`, as the user chooses by hand (`nil` goes back to the default); the
    /// choice is kept for the file with the track. Files differ in encoding, as tracks do in language, so it is the
    /// track's own. A track that isn't a text file (`canSetEncoding`) is left as it is.
    public func setEncoding(_ encoding: String.Encoding?, ofTrack trackId: Int) {
        guard canSetEncoding(ofTrack: trackId), let track = tracks.first(where: { $0.id == trackId }),
            self.encoding(ofTrack: trackId) != encoding
        else { return }
        trackEncodings[key(of: track)] = encoding
        AppLog.info(
            .subtitles,
            "Encoding of subtitle track \(trackId) set to \(encoding.flatMap(TextFileEncoding.name(of:)) ?? "default")")
        host?.saveCurrentPlaybackProgress()
        reread([track])
    }

    /// Takes a new default encoding (the settings'), and reads the files that have none of their own in it.
    func setDefaultEncoding(_ encoding: String.Encoding?) {
        guard settings.encoding != encoding else { return }
        settings.encoding = encoding
        reread(tracks.filter { trackEncodings[key(of: $0)] == nil })
    }

    /// Reads the text files among `tracks` again, in their encodings now, and redraws those on screen (main and
    /// second). The network ones are downloaded again when shown; the local ones are read here, off the main actor.
    private func reread(_ tracks: [SubtitleTrack]) {
        let affected = tracks.filter { $0.isExternal && $0.format != .bitmap }
        guard !affected.isEmpty else { return }
        let media = mediaGeneration
        // Reads under way are in the old encoding: their documents must not land.
        for track in affected {
            loads[track.id]?.cancel()
            loads[track.id] = nil
        }
        let network = affected.filter { $0.externalURL?.isFileURL != true }
        for track in network {
            loadedDocuments[track.id] = nil
            if let url = track.externalURL { remoteDocumentCache[url] = nil }
        }
        reload(trackIds: Set(network.map(\.id)))
        let locals = affected.compactMap {
            track -> (track: SubtitleTrack, url: URL, encoding: String.Encoding?)? in
            guard let url = track.externalURL, url.isFileURL else { return nil }
            return (track, url, effectiveEncoding(of: track))
        }
        guard !locals.isEmpty else { return }
        // A newer choice for a track replaces the read of this one.
        var generations: [Int: Int] = [:]
        for source in locals {
            readGenerations[source.track.id, default: 0] += 1
            generations[source.track.id] = readGenerations[source.track.id]
        }
        Task { [weak self] in
            let reads = await Task.detached(priority: .userInitiated) {
                locals.map { source -> (Int, SubtitleFileRead) in
                    // As the file was listed: its language, kind and format guide how it is read.
                    let file = MediaLoadRequest.SubtitleFile(
                        url: source.url, language: source.track.language, isAutoGenerated: source.track.isAutoGenerated,
                        format: source.track.format == .ass ? .ass : .text)
                    return (source.track.id, SubtitleFileRead.read(source.url, file: file, encoding: source.encoding))
                }
            }.value
            guard let self, self.mediaGeneration == media else { return }
            var done: Set<Int> = []
            for (id, read) in reads where self.readGenerations[id] == generations[id] {
                switch read.content {
                case .document(let document): self.loadedDocuments[id] = document
                case .ffmpegText, .bitmap, nil: self.loadedDocuments[id] = nil
                }
                done.insert(id)
            }
            self.reload(trackIds: done)
        }
    }

    /// Shows the tracks among `ids` that are on screen again, reading their files if their documents were dropped.
    private func reload(trackIds ids: Set<Int>) {
        if let id = selectedTrackId, ids.contains(id) {
            let wasAutomatic = selectionIsAutomatic
            select(trackId: id, persistHistory: false)
            selectionIsAutomatic = wasAutomatic
        }
        if let id = secondary.selectedTrackId, ids.contains(id) { secondary.reload() }
    }
}

// MARK: - Reading a track whole

extension SubtitleController {
    /// The read of `track`'s document for a track that isn't the selected one: its file, or the stream out of the media
    /// (every packet of it, as `EmbeddedSubtitleReader.extractEmbeddedSubtitles` reads); `nil` for a track that has
    /// nothing to read from (no media). An external track's read is the one `select` runs.
    func documentReader(for track: SubtitleTrack) -> (@Sendable (FFmpegInterrupt) async -> SubtitleDocument?)? {
        let demuxer = host?.demuxer
        guard let url = track.externalURL else {
            guard let path = host?.currentSourcePath, track.streamIndex >= 0 else { return nil }
            let headers = host?.currentHeaders ?? [:]
            let streamIndex = track.streamIndex
            return { interrupt in
                EmbeddedSubtitleReader.extractEmbeddedSubtitles(
                    url: path, headers: headers, streamIndex: streamIndex, interrupt: interrupt)
            }
        }
        let streamIndex = track.streamIndex
        if track.format == .bitmap {
            // Pictures are read when the track is selected, as the pictures of a DVD run to tens of megabytes.
            return { interrupt in
                EmbeddedSubtitleReader.extractEmbeddedSubtitles(
                    url: url.path, headers: [:], streamIndex: streamIndex, interrupt: interrupt)
            }
        }
        // MicroDVD counts frames: without a rate of its own, the video's is the one.
        let frameRate = demuxer.flatMap { $0.hasVideo ? 1 / $0.readingDescription(\.nominalFrameDuration) : nil }
        let hints = textEncodingHints(for: track, url: url)
        if url.isFileURL {
            // A format FFmpeg reads; the other local files are read whole when added.
            return { interrupt in
                FFmpegTextSubtitles.read(url: url, frameRate: frameRate, hints: hints, interrupt: interrupt)
            }
        }
        let headers = externalHeaders[track.id] ?? host?.currentHeaders ?? [:]
        let remote = RemoteSubtitle(
            url: url, headers: headers, format: track.format, isAutoGenerated: track.isAutoGenerated,
            frameRate: frameRate, hints: hints)
        return { interrupt in await remote.read(interrupt: interrupt) }
    }

    /// The document of an external track already read (or downloaded), `nil` for any other.
    func cachedDocument(of track: SubtitleTrack) -> SubtitleDocument? {
        guard track.isExternal else { return nil }
        return loadedDocuments[track.id] ?? track.externalURL.flatMap { remoteDocumentCache[$0] }
    }

    /// Keeps the document read for the second track, as `loadDocument` does for the selected one.
    func cache(_ document: SubtitleDocument, of track: SubtitleTrack) {
        guard let url = track.externalURL else { return }
        loadedDocuments[track.id] = document
        if !url.isFileURL { remoteDocumentCache[url] = document }
    }
}
