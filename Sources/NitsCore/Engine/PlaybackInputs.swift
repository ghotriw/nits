import Foundation

/// The inputs one media plays from: its own (the picture, its audio and subtitle tracks, HLS variants) and audio files
/// added to it, each read by a demuxer of its own. Lists the audio tracks of all of them and routes the one selected:
/// audio feeding reads it from `audioSource`, and the media's demuxer gets no audio track while a file's plays.
///
/// Each demuxer keeps its own locks and read-ahead thread, and none is taken while another's is held: two inputs add
/// no lock order. Main actor only; what runs elsewhere (seeks on `seekQueue`, the feeders) takes the demuxers it needs
/// first.
@MainActor
final class PlaybackInputs {
    /// An audio file added to the media.
    struct ExternalAudio {
        let url: URL
        /// `nil` for a file declared (`declareExternalAudio`) and not opened yet.
        var demuxer: MediaDemuxer?
        /// What a declared file is opened with once its track is selected.
        let headers: [String: String]
        let httpRequestSize: Int?
        /// Its tracks are numbered from here in `audioTracks` (`externalTrackIdBase` apart for each file).
        let firstTrackId: Int
        /// Its tracks as `audioTracks` lists them (`listedTracks`): renumbered, marked as the file's.
        let tracks: [MediaDemuxer.AudioTrack]
    }

    /// The media's own input.
    let main: MediaDemuxer
    private(set) var externalAudio: [ExternalAudio] = []
    /// The file the selected track is in; `nil` when it is the media's own (or none is selected).
    private(set) var selectedExternal: MediaDemuxer?
    /// The selected track's id in `audioTracks`; -1 without one.
    private(set) var selectedAudioTrackId: Int

    /// Ids of a file's tracks start here, a file's `externalTrackIdBase` apart, clear of the media's own (0...).
    static let firstExternalTrackId = 2000
    static let externalTrackIdBase = 100

    init(main: MediaDemuxer) {
        self.main = main
        selectedAudioTrackId = main.selectedAudioTrackIndex
    }

    /// The media's audio tracks, then the files', in the order they were added.
    var audioTracks: [MediaDemuxer.AudioTrack] {
        main.readingDescription(\.audioTracks) + externalAudio.flatMap(\.tracks)
    }

    /// The id in `audioTracks` of the file at `path`'s track of stream `streamIndex`, or its first; `nil` when that file
    /// isn't added.
    func audioTrackId(inFileAt path: String, streamIndex: Int?) -> Int? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let file = externalAudio.first(where: { $0.url == url }) else { return nil }
        return (file.tracks.first { $0.streamIndex == streamIndex } ?? file.tracks.first)?.id
    }

    /// Where audio feeding reads the selected track; `nil` when none is selected (or the media has no audio).
    var audioSource: (any AudioPacketSource)? {
        if let selectedExternal { return selectedExternal }
        return main.hasAudio && selectedAudioTrackId >= 0 ? main : nil
    }

    /// The selected track is in an added file: its input runs out (or ends) apart from the picture's.
    var isAudioSeparate: Bool { selectedExternal != nil }

    /// What aborts the files being opened (`openExternalAudio`), cancelled with the inputs.
    private var openings: [MediaDemuxer.InterruptContext] = []
    private var isCancelled = false

    /// Opens an audio file for its audio alone, off the main actor (it may be on a network), and adds it
    /// (`attachExternalAudio`). Returns its tracks: none when it can't be read or the inputs were cancelled meanwhile;
    /// `cancel()` aborts an opening stuck on a server.
    ///
    /// A load still applying its inputs passes its own `interrupt`, which aborts the opening with the load: these inputs
    /// aren't the engine's yet, so `PlayerEngine.stop()` doesn't `cancel()` them.
    func openExternalAudio(
        url: URL, headers: [String: String] = [:], interrupt: MediaDemuxer.InterruptContext? = nil
    ) async -> [MediaDemuxer.AudioTrack] {
        let url = url.isFileURL ? url.standardizedFileURL : url
        let declared = externalAudio.first { $0.url == url }
        // A file added again is the one added before, or being opened; one declared is opened with what it declared.
        if let declared, declared.demuxer != nil { return declared.tracks }
        if let opening = pendingOpenings[url] { return await opening.value }
        guard !isCancelled else { return [] }
        let opening = Task {
            await open(
                url: url, headers: declared?.headers ?? headers, httpRequestSize: declared?.httpRequestSize,
                isDeclared: declared != nil, interrupt: interrupt)
        }
        pendingOpenings[url] = opening
        defer { pendingOpenings[url] = nil }
        return await opening.value
    }

    /// Files being opened (`openExternalAudio`), by URL.
    private var pendingOpenings: [URL: Task<[MediaDemuxer.AudioTrack], Never>] = [:]

    private func open(
        url: URL, headers: [String: String], httpRequestSize: Int?, isDeclared: Bool,
        interrupt parent: MediaDemuxer.InterruptContext?
    ) async -> [MediaDemuxer.AudioTrack] {
        let interrupt = parent ?? MediaDemuxer.InterruptContext()
        openings.append(interrupt)
        defer { openings.removeAll { $0 === interrupt } }
        let opened = await Task.detached(priority: .userInitiated) {
            Self.openAudioFile(url, headers: headers, httpRequestSize: httpRequestSize, interrupt: interrupt)
        }.value
        // A declared file without the stream it declared (listed as the file's first) isn't the track listed.
        guard let opened, !isCancelled, !isDeclared || opened.audioTracks.contains(where: { $0.id == 0 }) else {
            opened?.cancel()
            if !isCancelled { AppLog.warning(.audio, "Can't read audio file \(url)") }
            return []
        }
        let added = attachExternalAudio(opened, url: url)
        AppLog.info(.audio, "Added \(added.count) audio track(s) from \(url.lastPathComponent)")
        return added
    }

    /// Opens the audio file at `url` for its audio alone (`MediaDemuxer(url:audioOnly:)`), a network one with
    /// `headers` and requests of `httpRequestSize`. Blocks while it reads; `nil` when it can't be read.
    nonisolated static func openAudioFile(
        _ url: URL, headers: [String: String], httpRequestSize: Int? = nil, interrupt: MediaDemuxer.InterruptContext
    ) -> MediaDemuxer? {
        let isFile = url.isFileURL
        return MediaDemuxer(
            url: isFile ? url.path : url.absoluteString, headers: isFile ? [:] : headers,
            httpRequestSize: httpRequestSize, interruptContext: interrupt, audioOnly: true)
    }

    /// Adds an audio file opened for its audio alone (`MediaDemuxer(url:audioOnly:)`); its tracks join
    /// `audioTracks`, none selected, listed with the `title` and `language` a request gives it. Returns them.
    @discardableResult
    func attachExternalAudio(
        _ demuxer: MediaDemuxer, url: URL, title: String? = nil, language: String? = nil
    ) -> [MediaDemuxer.AudioTrack] {
        let url = url.isFileURL ? url.standardizedFileURL : url
        // Nothing of it is read until one of its tracks is selected.
        demuxer.selectAudioTrack(trackId: nil)
        // Opened after being declared: it keeps the tracks listed.
        if let index = externalAudio.firstIndex(where: { $0.url == url }) {
            externalAudio[index].demuxer = demuxer
            return externalAudio[index].tracks
        }
        let firstTrackId = nextFirstTrackId
        let file = ExternalAudio(
            url: url, demuxer: demuxer, headers: [:], httpRequestSize: nil, firstTrackId: firstTrackId,
            tracks: Self.listedTracks(
                of: demuxer.audioTracks, from: url, firstId: firstTrackId, title: title, language: language))
        externalAudio.append(file)
        return file.tracks
    }

    /// Adds an audio file of one stream known beforehand (`MediaLoadRequest.AudioFile.declaredStream`) without opening
    /// it: its track is listed, and the file opens when the track is selected (`openExternalAudio`). Returns the track.
    @discardableResult
    func declareExternalAudio(_ file: MediaLoadRequest.AudioFile) -> MediaDemuxer.AudioTrack? {
        guard let stream = file.declaredStream else { return nil }
        let url = file.url.isFileURL ? file.url.standardizedFileURL : file.url
        if let added = externalAudio.first(where: { $0.url == url }) { return added.tracks.first }
        let firstTrackId = nextFirstTrackId
        let track = MediaDemuxer.AudioTrack(
            id: 0, streamIndex: 0, title: "", language: "", codecName: stream.codecName, channels: stream.channels,
            sampleRate: stream.sampleRate, isDefault: false)
        let file = ExternalAudio(
            url: url, demuxer: nil, headers: file.headers ?? [:], httpRequestSize: file.httpRequestSize,
            firstTrackId: firstTrackId,
            tracks: Self.listedTracks(
                of: [track], from: url, firstId: firstTrackId, title: file.title, language: file.language))
        externalAudio.append(file)
        return file.tracks.first
    }

    /// Where the next file's tracks are numbered from: past those of the files listed. The ids of a dropped last file
    /// (`dropUnopenedFile`) are free again; nothing lists them.
    private var nextFirstTrackId: Int {
        (externalAudio.map(\.firstTrackId).max()).map { $0 + Self.externalTrackIdBase } ?? Self.firstExternalTrackId
    }

    /// Takes a declared file out of the list, when it can't be opened and its track isn't to be offered.
    func dropUnopenedFile(at url: URL) {
        externalAudio.removeAll { $0.demuxer == nil && $0.url == url }
    }

    /// The file of track `id` when it is declared and not opened yet.
    func unopenedFile(ofTrack id: Int) -> URL? {
        externalAudio.first { $0.demuxer == nil && $0.tracks.contains { $0.id == id } }?.url
    }

    /// The track selected on load is in a file declared and not opened (`unopenedFile`): the file to open before the
    /// media starts, which `selectAudioTrackOnLoad` then selects from.
    func unopenedFileToStartWith(requested: String?, saved: PlaybackPreferences?, languages: [String]) -> URL? {
        loadChoice(requested: requested, saved: saved, languages: languages).flatMap { unopenedFile(ofTrack: $0.id) }
    }

    /// A file's tracks as listed with the media's: marked "(External)" after the stream's own title ("Director's
    /// Commentary") or, without one, the file's name; in the language its name tags when the stream tells none (the
    /// views add the language). Its default flag doesn't count against the media's tracks: the file's flags are of the
    /// file alone, and on a tie `TrackAutoSelection` keeps to the media's own.
    ///
    /// A request's `title` and `language` (`MediaLoadRequest.AudioFile`) come first: a host names its files as it
    /// wants them shown, and a signed URL's name ("videoplayback") tells nothing.
    static func listedTracks(
        of tracks: [MediaDemuxer.AudioTrack], from url: URL, firstId: Int, title: String? = nil,
        language: String? = nil
    ) -> [MediaDemuxer.AudioTrack] {
        let name = url.deletingPathExtension().lastPathComponent
        let taggedLanguage = url.isFileURL ? SidecarFiles.tags(of: url).language : nil
        let labelled = tracks.map { track in
            let isUnlabelled = track.language.isEmpty || track.language == "und"
            let streamLanguage = isUnlabelled ? (taggedLanguage ?? track.language) : track.language
            return (
                track: track, title: title ?? (track.title.isEmpty ? name : track.title),
                language: language ?? streamLanguage
            )
        }
        return labelled.map { entry in
            var shown = entry.title
            // Streams the list would show alike (stereo and 5.1 of one language, untitled): numbered apart.
            if labelled.filter({ $0.title == entry.title && $0.language == entry.language }).count > 1 {
                shown += " #\(entry.track.id + 1)"
            }
            if title == nil { shown += " (External)" }
            return entry.track.with(
                id: firstId + entry.track.id, title: shown, language: entry.language,
                isDefault: false, externalURL: url)
        }
    }

    /// Selects track `id` of `audioTracks`: in its file (the media's demuxer then gets none), or in the media; a choice
    /// to save. Returns whether `id` is a track. The caller re-reads from the current frame, as for any track switch.
    @discardableResult
    func selectAudioTrack(id: Int) -> Bool {
        if let file = externalAudio.first(where: {
            id >= $0.firstTrackId && id < $0.firstTrackId + Self.externalTrackIdBase
        }) {
            let trackId = id - file.firstTrackId
            // A declared file is opened first (`openExternalAudio`).
            guard let demuxer = file.demuxer, demuxer.audioTracks.contains(where: { $0.id == trackId }) else {
                return false
            }
            main.selectAudioTrack(trackId: nil)
            for other in externalAudio where other.demuxer !== demuxer {
                other.demuxer?.selectAudioTrack(trackId: nil)
            }
            demuxer.selectAudioTrack(trackId: trackId)
            // Read ahead as the media is (a network file), from its first selection on: unselected, it reads nothing.
            if main.readsAhead || demuxer.isNetworkSource { demuxer.startReadAhead() }
            selectedExternal = demuxer
        } else {
            guard main.readingDescription({ $0.audioTracks.contains { $0.id == id } }) else { return false }
            for file in externalAudio { file.demuxer?.selectAudioTrack(trackId: nil) }
            main.selectAudioTrack(trackId: id)
            selectedExternal = nil
        }
        selectedAudioTrackId = id
        isAudioSelectionAutomatic = false
        return true
    }

    /// The track the viewer chose in a file still opening: selected once it is, unless another is chosen meanwhile.
    var awaitedAudioTrackId: Int?

    /// The selected track was chosen on load by `TrackAutoSelection`: it isn't saved for the media, until it is chosen
    /// (`keepAudioSelection`) or another one is.
    private(set) var isAudioSelectionAutomatic = false

    /// Keeps the track picked on load for the media, whatever the language settings become.
    func keepAudioSelection() {
        isAudioSelectionAutomatic = false
    }

    // MARK: - Load and history

    /// Selects the track the media starts with, once its files are added: the request's (`requested`, a spec of
    /// `PlayerEngine.resolveAudioTrackId`), else the one saved for it (a file's by its path), else by
    /// `TrackAutoSelection` and the `languages`, marked automatic. None fitting leaves the demuxer's.
    func selectAudioTrackOnLoad(requested: String?, saved: PlaybackPreferences?, languages: [String]) {
        guard let choice = loadChoice(requested: requested, saved: saved, languages: languages) else { return }
        // The track the demuxer already has selected needs no switch, when it is the automatic choice.
        if !choice.isAutomatic || choice.id != selectedAudioTrackId {
            selectAudioTrack(id: choice.id)
            AppLog.info(.audio, choice.reason)
        }
        isAudioSelectionAutomatic = choice.isAutomatic
    }

    /// The track `selectAudioTrackOnLoad` starts with, and why.
    private func loadChoice(requested: String?, saved: PlaybackPreferences?, languages: [String]) -> (
        id: Int, reason: String, isAutomatic: Bool
    )? {
        let tracks = audioTracks
        if let spec = requested, let id = PlayerEngine.resolveAudioTrackId(spec, in: tracks) {
            return (id, "Using explicit audio track: \(id)", false)
        } else if saved?.audioTrackId == PlaybackRecord.externalAudio, let path = saved?.externalAudioPath,
            let id = audioTrackId(inFileAt: path, streamIndex: saved?.externalAudioStreamIndex)
        {
            return (id, "Restored external audio file from saved history: \(path)", false)
        } else if let id = saved?.audioTrackId, tracks.contains(where: { $0.id == id }) {
            return (id, "Restored audio track from saved history: \(id)", false)
        } else if let id = TrackAutoSelection.audioTrackId(in: tracks, languages: languages) {
            return (id, "Selected audio track \(id) by language and default flag", true)
        }
        return nil
    }

    /// Writes the selected track to persist; one chosen on load by `TrackAutoSelection` isn't. A file's track is saved
    /// by its path, as a subtitle file is: its id numbers the files added this time. One that isn't a local file (a
    /// host's signed URL) can't be opened again: the saved choice stays.
    func writeAudioPreferences(into preferences: inout PlaybackPreferences) {
        guard selectedAudioTrackId >= 0, !isAudioSelectionAutomatic else { return }
        let track = audioTracks.first { $0.id == selectedAudioTrackId }
        if let url = track?.externalURL {
            if url.isFileURL {
                preferences.audioTrackId = PlaybackRecord.externalAudio
                preferences.externalAudioPath = url.path
                preferences.externalAudioStreamIndex = track?.streamIndex
            }
        } else {
            preferences.audioTrackId = selectedAudioTrackId
        }
    }

    // MARK: - Reading

    /// The picture has been read to its end (or there is none).
    var isVideoEOF: Bool { main.isVideoEOF }
    /// The selected track has been read to its end (or none is selected).
    var isAudioEOF: Bool { audioSource?.isAudioEOF ?? true }
    /// Nothing more is coming from any input playback reads.
    var isEOF: Bool {
        guard let selectedExternal else { return main.isEOF }
        // Each stream's own end: media without a picture has nothing selected while a file's track plays, and is
        // never read to an end.
        return main.isVideoEOF && selectedExternal.isAudioEOF
    }

    /// Timeline second up to which what plays has been read ahead: the lesser of the picture's input and the selected
    /// file's (the file's alone without a picture).
    var readAheadSeconds: Double {
        guard let selectedExternal else { return main.readAheadSeconds }
        guard main.hasVideo else { return selectedExternal.readAheadSeconds }
        return min(main.readAheadSeconds, selectedExternal.readAheadSeconds)
    }

    /// Stops every input's reads (the media's and the files'), blocking I/O included, and the files being opened.
    func cancel() {
        isCancelled = true
        main.cancel()
        for file in externalAudio { file.demuxer?.cancel() }
        for opening in openings { opening.cancel() }
    }
}
