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
        let demuxer: MediaDemuxer
        /// Its tracks are numbered from here in `audioTracks` (`externalTrackIdBase` apart for each file).
        let firstTrackId: Int
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
        main.readingDescription(\.audioTracks)
            + externalAudio.flatMap { file in
                file.demuxer.audioTracks.map { $0.with(id: file.firstTrackId + $0.id, externalURL: file.url) }
            }
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
    func openExternalAudio(url: URL, headers: [String: String] = [:]) async -> [MediaDemuxer.AudioTrack] {
        guard !isCancelled else { return [] }
        let interrupt = MediaDemuxer.InterruptContext()
        openings.append(interrupt)
        defer { openings.removeAll { $0 === interrupt } }
        let path = url.isFileURL ? url.path : url.absoluteString
        let opened = await Task.detached(priority: .userInitiated) {
            MediaDemuxer(url: path, headers: headers, interruptContext: interrupt, audioOnly: true)
        }.value
        guard let opened, !isCancelled else {
            opened?.cancel()
            if opened == nil, !isCancelled { AppLog.warning(.audio, "Can't read audio file \(url)") }
            return []
        }
        let added = attachExternalAudio(opened, url: url)
        AppLog.info(.audio, "Added \(added.count) audio track(s) from \(url.lastPathComponent)")
        return added
    }

    /// Adds an audio file opened for its audio alone (`MediaDemuxer(url:audioOnly:)`); its tracks join
    /// `audioTracks`, none selected. Returns them.
    @discardableResult
    func attachExternalAudio(_ demuxer: MediaDemuxer, url: URL) -> [MediaDemuxer.AudioTrack] {
        // Nothing of it is read until one of its tracks is selected.
        demuxer.selectAudioTrack(trackId: nil)
        let file = ExternalAudio(
            url: url, demuxer: demuxer,
            firstTrackId: Self.firstExternalTrackId + externalAudio.count * Self.externalTrackIdBase)
        externalAudio.append(file)
        return demuxer.audioTracks.map { $0.with(id: file.firstTrackId + $0.id, externalURL: url) }
    }

    /// Selects track `id` of `audioTracks`: in its file (the media's demuxer then gets none), or in the media. Returns
    /// whether `id` is a track. The caller re-reads from the current frame, as for any track switch.
    @discardableResult
    func selectAudioTrack(id: Int) -> Bool {
        if let file = externalAudio.first(where: {
            id >= $0.firstTrackId && id < $0.firstTrackId + Self.externalTrackIdBase
        }) {
            let trackId = id - file.firstTrackId
            guard file.demuxer.audioTracks.contains(where: { $0.id == trackId }) else { return false }
            main.selectAudioTrack(trackId: nil)
            for other in externalAudio where other.demuxer !== file.demuxer {
                other.demuxer.selectAudioTrack(trackId: nil)
            }
            file.demuxer.selectAudioTrack(trackId: trackId)
            // Read ahead as the media is (a network file), from its first selection on: unselected, it reads nothing.
            if main.readsAhead || file.demuxer.isNetworkSource { file.demuxer.startReadAhead() }
            selectedExternal = file.demuxer
        } else {
            guard main.readingDescription({ $0.audioTracks.contains { $0.id == id } }) else { return false }
            for file in externalAudio { file.demuxer.selectAudioTrack(trackId: nil) }
            main.selectAudioTrack(trackId: id)
            selectedExternal = nil
        }
        selectedAudioTrackId = id
        return true
    }

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
        for file in externalAudio { file.demuxer.cancel() }
        for opening in openings { opening.cancel() }
    }
}
