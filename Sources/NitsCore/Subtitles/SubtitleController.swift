import CoreGraphics
import Foundation
import Observation

/// What `SubtitleController` needs of the player it shows subtitles for; `PlayerEngine` is one, held weakly.
@MainActor
protocol SubtitleHost: AnyObject {
    /// The demuxer of the media playing; `nil` before one opens.
    var demuxer: MediaDemuxer? { get }
    /// Path or URL of the stream playing (a resolved page's, `PlayerEngine.currentSourcePath`), and the HTTP headers
    /// it opened with.
    var currentSourcePath: String? { get }
    var currentHeaders: [String: String] { get }
    /// Playback position shown, in seconds.
    var currentTime: Double { get }
    /// The master clock now, which runs ahead of `currentTime` between its updates.
    var clockSeconds: Double { get }
    /// The picture subtitles are drawn over, which libass places ASS coordinates in.
    var subtitleVideo: SubtitleVideo { get }
    /// Whether playback runs and its time is settled (playing, loaded, no seek landing): what animates libass.
    var isPresentingContinuously: Bool { get }
    var isPlaying: Bool { get }
    func saveCurrentPlaybackProgress()
    /// Reads the media again from the frame shown, for a track read only while selected (an HLS rendition).
    func rereadFromCurrentFrame()
    /// Reports a change of the tracks or their selection (`PlayerEngine.onTracksChanged`), held back while deferred.
    func tracksDidChange()
    /// Runs `body` with track change reports held back, reported once after it.
    func deferringTracksChanged(_ body: () -> Void)
}

/// The picture subtitles are drawn over, as `SubtitleHost` reports it.
struct SubtitleVideo: Equatable {
    var width = 0
    var height = 0
    var sampleAspectRatio = RationalAspectRatio.square
    var geometry = VideoGeometrySettings()
    /// Seconds per frame of the video, for redrawing libass animations a frame on.
    var frameDuration = 1.0 / 24.0
}

/// How plain-text subtitles are drawn, and ASS dialogue under `SubtitleController.assStyleOverride`.
public struct SubtitleStyle: Equatable, Sendable {
    public var fontName: String
    public var fontSize: Double
    public var fontWeight: String
    public var textColorHex: String
    public var backgroundColorHex: String
    public var backgroundOpacity: Double

    public init(
        fontName: String = SubtitleSystemFont.rounded.rawValue, fontSize: Double = 24, fontWeight: String = "Semibold",
        textColorHex: String = "#FFFFFF", backgroundColorHex: String = "#000000", backgroundOpacity: Double = 0.65
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.textColorHex = textColorHex
        self.backgroundColorHex = backgroundColorHex
        self.backgroundOpacity = backgroundOpacity
    }
}

/// The subtitles of the media playing: its tracks, the one selected, what is on screen and how it is drawn. Owns every
/// read of them, the libass renderer and the cues shown; the player tells it when media loads (`mediaDidLoad`), when
/// time moves (`timeDidChange`) and when the media goes (`reset`).
@MainActor
@Observable
public final class SubtitleController {
    /// What the controller reads from the player's configuration besides the style.
    public struct Settings: Equatable, Sendable {
        /// Encoding to read subtitle files in when their bytes don't tell; `nil` detects it.
        public var encoding: String.Encoding?
        /// Languages that choose the subtitles a media starts with.
        public var trackLanguages: TrackLanguagePreferences

        public init(encoding: String.Encoding? = nil, trackLanguages: TrackLanguagePreferences = .init()) {
            self.encoding = encoding
            self.trackLanguages = trackLanguages
        }
    }

    /// When time moved, for `timeDidChange(to:_:)`.
    enum TimeChange {
        /// Playback's time tick, a seek's preview of its target, or a frame step: show what is due.
        case tick
        /// A seek landed: show what is due, and read in a window what playback reads after.
        case seekLanded
        /// A load applied its start time; the track was chosen before it: show what is due, and read in a window.
        case mediaStarted
    }

    @ObservationIgnored weak var host: (any SubtitleHost)?
    @ObservationIgnored public var settings: Settings

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    // MARK: Tracks

    /// The media's subtitle tracks: its own (embedded, closed captions) and the files added.
    public internal(set) var tracks: [SubtitleTrack] = [] {
        didSet {
            if oldValue != tracks { host?.tracksDidChange() }
        }
    }
    public internal(set) var selectedTrackId: Int? = nil {
        didSet {
            if oldValue != selectedTrackId { host?.tracksDidChange() }
        }
    }
    /// The selection was made on load by `TrackAutoSelection`, so it isn't saved for the file.
    @ObservationIgnored var selectionIsAutomatic = false

    // MARK: On screen

    /// The cues on screen, subtitle delay applied.
    public internal(set) var cues: [SubtitleCue] = [] {
        didSet {
            if oldValue != cues { onCuesChanged?(cues) }
        }
    }
    /// Called with the cues on screen (subtitle delay applied) whenever they change: a cue starts or ends, a seek or
    /// a track switch lands on other ones, and with `[]` when subtitles are off or the media stops. Not called per
    /// time tick. Cue `text` is plain; `rawPayload` carries an ASS event for hosts that draw it themselves.
    @ObservationIgnored public var onCuesChanged: (([SubtitleCue]) -> Void)?
    /// Bitmap subtitles (PGS, VobSub, DVB) and libass' pictures on screen, subtitle delay applied. Drawn by the
    /// player; hosts get no events for them (`onCuesChanged` reports `[]` meanwhile).
    public internal(set) var images: [SubtitleImageCue] = []
    /// The selected ASS track's script without its events (`AssScript.hostHeader`: styles, play resolution, embedded
    /// fonts), for a host that draws ASS itself from the cues' `rawPayload` lines; `nil` for other tracks. There before
    /// the track's first cue is reported.
    public var assHeader: String? { activeDocument?.assScript?.hostHeader }
    /// The fonts the media attaches for the selected ASS track (Matroska attachments), which its styles may name.
    public var assFonts: [AssScript.Font] { activeDocument?.assScript?.fonts ?? [] }
    /// Whether libass draws the selected track, so its text cues (`cues`) aren't to be drawn again.
    public internal(set) var isDrawingAuthored = false

    // MARK: Timing and drawing

    /// Seconds subtitles are shifted by: positive shows them later, negative earlier. Set with `setDelay`.
    public internal(set) var delay: Double = 0
    public static let delayRange: ClosedRange<Double> = -30.0...30.0
    /// The style also applies to ASS dialogue with `assStyleOverride`: a change redraws it, but of the weight, which
    /// libass doesn't take.
    public var style = SubtitleStyle() {
        didSet {
            var drawn = oldValue
            drawn.fontWeight = style.fontWeight
            if drawn != style { restyleAuthored() }
        }
    }
    /// Draw ASS / SSA subtitles with libass as authored; off draws their text in `style`.
    public var usesAuthoredStyles: Bool = true {
        didSet {
            if oldValue != usesAuthoredStyles { syncAuthored() }
        }
    }
    /// Show only the forced sets of bitmap tracks (PGS, VobSub): the signs and foreign-language lines a Blu-ray keeps
    /// inside its full track. Text tracks don't mark them and show as usual; so does a track flagged forced as a whole.
    public var showsOnlyForced: Bool = false {
        didSet {
            if oldValue != showsOnlyForced { updateShown(at: host?.currentTime ?? 0) }
        }
    }
    /// How much of `style` replaces an ASS script's own on its dialogue, when libass draws it.
    public var assStyleOverride: AssStyleOverride = .none {
        didSet {
            if oldValue != assStyleOverride { redrawAuthored() }
        }
    }
    /// Size of ASS dialogue and picture subtitles against the script's or the disc's (`scaleRange`); plain text has
    /// `style.fontSize`.
    public var scale: Double = 1.0 {
        didSet { if oldValue != scale { redrawAuthored() } }
    }
    public static let scaleRange: ClosedRange<Double> = 0.5...2.0
    /// Height of bottom subtitles in percent of the picture from its top (0-100): 100 keeps them where they are, lower
    /// raises them (mpv's `sub-pos`). Applies to every kind of subtitle.
    public var position: Double = 100 {
        didSet { if oldValue != position { redrawAuthored() } }
    }
    /// `scale` as applied: clamped to `scaleRange`, 1 when it isn't a number.
    public var effectiveScale: Double {
        let range = Self.scaleRange
        return scale.isFinite ? min(max(scale, range.lowerBound), range.upperBound) : 1
    }
    /// How far bottom subtitles are raised, as a fraction of the picture's height (`position`).
    public var raise: Double {
        position.isFinite ? (100 - min(max(position, 0), 100)) / 100 : 0
    }
    /// Size in pixels of the area subtitles are drawn on (the visible picture), reported by the view that draws them.
    /// Until it is set, ASS subtitles show as plain text, as for a host that draws its own.
    public var renderSize: CGSize = .zero {
        didSet {
            if oldValue != renderSize { syncAuthored() }
        }
    }

    // MARK: Documents and reads

    /// The selected track's cues and script. Setting it updates the libass renderer's script without rendering
    /// (`renderIfReady: false`), so callers that assign a document must follow with `updateShown(at:)` (or
    /// `show(_:at:)`) to draw at the target timestamp without queuing a duplicate render pass.
    // Nothing observes it; the macro would compare whole documents (events, fonts) on every set.
    @ObservationIgnored var activeDocument: SubtitleDocument? = nil {
        didSet { syncAuthored(renderIfReady: false) }
    }
    /// The documents of tracks read whole (files), by track id.
    @ObservationIgnored var loadedDocuments: [Int: SubtitleDocument] = [:]
    /// Downloaded remote subtitle documents keyed by URL, kept across a page's video-format switches (`mediaDidLoad`)
    /// and so by `reset()`; `discardDownloadedDocuments()` drops them when playback stops.
    @ObservationIgnored var remoteDocumentCache: [URL: SubtitleDocument] = [:]
    /// HTTP headers for external subtitle tracks (`MediaLoadRequest.SubtitleFile`), by track id.
    @ObservationIgnored var externalHeaders: [Int: [String: String]] = [:]
    /// `MediaDemuxer.liveSubtitleVersion` of the live document shown; a new one is fetched when it changes.
    @ObservationIgnored var lastObservedLiveVersion = -1
    /// Subtitle tracks being read in the background, by track id: one read per track, cancelled once the track is no
    /// longer selected or the media closes.
    @ObservationIgnored var loads: [Int: Load] = [:]
    /// The window read of the selected embedded track around the time shown (`refreshEmbedded`).
    @ObservationIgnored var windowRead: Load?
    /// The merge of what playback read of the selected track before it was chosen (`refreshEmbedded`): never
    /// cancelled, as nothing else brings it; window reads wait for it.
    @ObservationIgnored var stashMerge: Task<Void, Never>?
    /// The read of the file's own index of subtitle streams (`EmbeddedSubtitleReader.readIndex`), once per media:
    /// cancelled only with it, so seeks in a row don't restart it; window reads wait for it.
    @ObservationIgnored var indexLoad: Load?
    /// Counts `reset()`s, so files `addExternal(urls:)` read for media since left aren't added to the next.
    @ObservationIgnored var mediaGeneration = 0

    // MARK: libass

    @ObservationIgnored var authoredRenderer: AssSubtitleRenderer?
    @ObservationIgnored var authoredRendererTrackId: Int?
    @ObservationIgnored var authoredScript: AssScript?
    /// Counts renderer starts and drops, so a renderer made in the background for a track since left is thrown away.
    @ObservationIgnored var authoredGeneration = 0
    @ObservationIgnored var isAuthoredRenderRunning = false
    /// How long a libass call may run before it counts as stuck (`watchLibass`): a frame takes milliseconds, a new
    /// script's first fonts a fraction of a second.
    @ObservationIgnored var libassStallTimeout: Duration = .seconds(5)
    /// A libass call has run past `libassStallTimeout`: the media's ASS tracks show their text cues.
    @ObservationIgnored var isLibassStalled = false
    /// This controller's libass calls not yet back, run or waiting for the queue (`watchLibass`).
    @ObservationIgnored var libassCallsInFlight = 0
    /// The check for a stuck libass call (`watchLibass`), while one is under way.
    @ObservationIgnored var libassWatch: Task<Void, Never>?
    @ObservationIgnored var pendingAuthoredRenderTime: Double?
    /// A render a video frame on is due (`scheduleAuthoredAnimationFrame`).
    @ObservationIgnored var isAuthoredAnimationFrameScheduled = false

    /// A subtitle track read in the background: its task, and the interrupt that aborts the FFmpeg I/O the task may be
    /// blocked in, which cancelling the task alone wouldn't.
    struct Load {
        let task: Task<Void, Never>
        let interrupt: FFmpegInterrupt

        func cancel() {
            interrupt.cancel()
            task.cancel()
        }
    }
}

// MARK: - Selection

extension SubtitleController {
    public func select(trackId id: Int?) {
        selectionIsAutomatic = false
        select(trackId: id, persistHistory: true)
        // An HLS subtitle rendition is a playlist of its own, read only while selected: read ahead, FFmpeg would start
        // it at the read position, up to the read-ahead limit past playback. Read it from the current frame instead,
        // as an audio track switch does. (Subtitles muxed with the video, and closed captions, come as they are read.)
        if let demuxer = host?.demuxer, demuxer.readsAhead, !demuxer.variants.isEmpty, let id,
            let track = tracks.first(where: { $0.id == id }), !track.isExternal,
            track.closedCaptionField == nil
        {
            host?.rereadFromCurrentFrame()
        }
    }

    func select(trackId id: Int?, persistHistory: Bool) {
        let demuxer = host?.demuxer
        guard let id else {
            // Disable subtitles
            cancelLoads()
            self.selectedTrackId = nil
            self.activeDocument = nil
            self.cues.removeAll()
            self.images.removeAll()
            self.lastObservedLiveVersion = -1
            demuxer?.selectSubtitleTrack(trackId: nil)
            if persistHistory {
                host?.saveCurrentPlaybackProgress()
            }
            return
        }

        guard let track = tracks.first(where: { $0.id == id }) else { return }
        // Skipping through tracks must not leave a whole-file read running for each one passed.
        cancelLoads(except: id)
        self.selectedTrackId = id
        // The previous track's cues (and libass script) go until this one's document is there.
        self.activeDocument = nil
        self.cues = []
        self.images = []
        demuxer?.selectSubtitleTrack(trackId: id)
        if persistHistory {
            host?.saveCurrentPlaybackProgress()
        }

        let now = host?.currentTime ?? 0
        if track.isExternal {
            self.activeDocument = loadedDocuments[id]
            self.updateShown(at: now)
            if activeDocument == nil, let url = track.externalURL {
                let streamIndex = track.streamIndex
                // Another file may have been opened meanwhile, with tracks of the same ids.
                let isCurrent: @MainActor @Sendable (SubtitleController) -> Bool = { controller in
                    controller.tracks.contains {
                        $0.id == id && $0.externalURL == url && $0.streamIndex == streamIndex
                    }
                }
                if track.format == .bitmap {
                    // Pictures are read when the track is selected, as the pictures of a DVD run to tens of megabytes.
                    loadDocument(
                        trackId: id,
                        read: { interrupt in
                            EmbeddedSubtitleReader.extractEmbeddedSubtitles(
                                url: url.path, headers: [:], streamIndex: streamIndex, interrupt: interrupt)
                        }, isCurrent: isCurrent)
                } else {
                    // MicroDVD counts frames: without a rate of its own, the video's is the one.
                    let frameRate = demuxer.flatMap {
                        $0.hasVideo ? 1 / $0.readingDescription(\.nominalFrameDuration) : nil
                    }
                    let hints = textEncodingHints(for: url, language: track.language)
                    if url.isFileURL {
                        // A format FFmpeg reads; the other local files are read whole when added.
                        loadDocument(
                            trackId: id,
                            read: { interrupt in
                                FFmpegTextSubtitles.read(
                                    url: url, frameRate: frameRate, hints: hints, interrupt: interrupt)
                            }, isCurrent: isCurrent)
                    } else {
                        let headers = externalHeaders[id] ?? host?.currentHeaders ?? [:]
                        let remote = RemoteSubtitle(
                            url: url, headers: headers, format: track.format,
                            isAutoGenerated: track.isAutoGenerated, frameRate: frameRate, hints: hints)
                        loadDocument(
                            trackId: id, read: { interrupt in await remote.read(interrupt: interrupt) },
                            isCurrent: isCurrent)
                    }
                }
            }
        } else if let demuxer {
            // Embedded tracks come from the packets playback reads, as in mpv and VLC: a read of the whole file would
            // read every byte of it (Matroska ignores discarded streams), minutes on a network volume. A window read
            // fills in the cue on screen now.
            self.lastObservedLiveVersion = demuxer.liveSubtitleVersion
            self.activeDocument = demuxer.getLiveSubtitleDocument()
            self.updateShown(at: now)
            refreshEmbedded(around: now)
        }
    }
}

// MARK: - Delay

extension SubtitleController {
    /// Shifts subtitles by `seconds` (clamped to `delayRange`, rounded to milliseconds) and saves the delay for the
    /// file. One delay serves all of the file's subtitle tracks.
    public func setDelay(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let range = Self.delayRange
        let clamped = min(max((seconds * 1000).rounded() / 1000, range.lowerBound), range.upperBound)
        guard clamped != delay else { return }
        delay = clamped
        AppLog.info(.subtitles, "Subtitle delay changed to \(clamped)s")
        let now = host?.currentTime ?? 0
        updateShown(at: now)
        // The track is due at another time now, which may lie outside what was read.
        refreshEmbedded(around: now)
        host?.saveCurrentPlaybackProgress()
    }

    public func stepDelay(by delta: Double) {
        setDelay(delay + delta)
    }

    public func resetDelay() {
        setDelay(0)
    }
}

// MARK: - Lifecycle

extension SubtitleController {
    /// Takes the media's subtitles away: its tracks, what is on screen (hosts get `[]`), the libass renderer, the
    /// documents read and the reads still running.
    func reset() {
        mediaGeneration += 1
        cancelLoads()
        // A merge still running is for the media left (it checks the demuxer); the next one's reads needn't wait.
        stashMerge = nil
        indexLoad?.cancel()
        indexLoad = nil
        // The next media tries libass again; if its queue is still stuck, the watch finds it so again.
        isLibassStalled = false
        selectedTrackId = nil
        selectionIsAutomatic = false
        delay = 0
        activeDocument = nil
        cues.removeAll()
        images.removeAll()
        loadedDocuments.removeAll()
        externalHeaders.removeAll()
        lastObservedLiveVersion = -1
        tracks = []
    }

    /// Drops the remote documents `reset()` keeps for the next load of the same page (`remoteDocumentCache`).
    func discardDownloadedDocuments() {
        remoteDocumentCache.removeAll()
    }

    /// Takes the tracks of media just opened (its demuxer is the host's now) and chooses one: the request's, else the
    /// one saved for the file, else by `TrackAutoSelection` (none when nothing fits). Restores the saved delay first,
    /// as the track picks its cues with it, and adds the subtitle files of the request/page and next to a local file.
    /// The local ones are those `readFiles` read (`MediaSubtitleFiles.Lookup` of `subtitleFiles`, the media's path and
    /// `saved`), before the load was applied.
    func mediaDidLoad(
        tracks: [SubtitleTrack], subtitleFiles: [MediaLoadRequest.SubtitleFile] = [],
        defaultHeaders: [String: String] = [:], readFiles: MediaSubtitleFiles, saved: PlaybackPreferences?,
        requestedTrack: String?, audioLanguage: String?
    ) {
        // Keep remote subtitle documents already downloaded for the same URLs (e.g. when switching a page's video
        // format), so the active track stays shown without re-downloading.
        let currentRemoteURLs = Set(subtitleFiles.map(\.url).filter { !$0.isFileURL })
        remoteDocumentCache = remoteDocumentCache.filter { currentRemoteURLs.contains($0.key) }
        let previousRemoteDocuments = remoteDocumentCache
        // Again, after the load's own reset: a file added while the media opened in the background is selected, with
        // its document, under an id (1000 + count) the new media's files are given too.
        reset()
        self.tracks = tracks
        // Set directly, not via `setDelay`: nothing to re-save, and the track below picks its cues with it.
        let savedDelay = saved?.subtitleDelay ?? 0
        delay = savedDelay.isFinite ? min(max(savedDelay, Self.delayRange.lowerBound), Self.delayRange.upperBound) : 0
        if delay != 0 {
            AppLog.info(.subtitles, "Restored subtitle delay from saved history: \(delay)s")
        }
        addSubtitleFiles(
            subtitleFiles, defaultHeaders: defaultHeaders, read: readFiles, reusing: previousRemoteDocuments)
        // Before the saved selection: a saved external file that is one of them maps to the same track.
        addSidecarFiles(readFiles)

        let chosen: Bool
        if let spec = requestedTrack, let preference = PlayerEngine.resolveSubtitleSelection(spec, in: self.tracks) {
            switch preference {
            case .disable:
                select(trackId: nil, persistHistory: false)
                AppLog.info(.subtitles, "Explicit subtitle selection: disabled")
            case .select(let trackId):
                select(trackId: trackId, persistHistory: false)
                AppLog.info(.subtitles, "Using explicit subtitle track: \(trackId)")
            }
            chosen = true
        } else {
            chosen = restoreSelection(from: saved, among: self.tracks, readFiles: readFiles)
        }
        if !chosen {
            selectionIsAutomatic = true
            if let trackId = TrackAutoSelection.subtitleTrackId(
                in: self.tracks, audioLanguage: audioLanguage, preferences: settings.trackLanguages,
                systemLanguages: Locale.preferredLanguages)
            {
                select(trackId: trackId, persistHistory: false)
                AppLog.info(.subtitles, "Selected subtitle track \(trackId) by language and flags")
            }
        }
    }

    /// Shows what is due at `seconds` (playback time; the delay is applied here) and reads what a seek or a load
    /// leaves out.
    func timeDidChange(to seconds: Double, _ change: TimeChange) {
        switch change {
        case .tick:
            updateShown(at: seconds)
        case .seekLanded:
            updateShown(at: seconds)
            // A cue that started before where the seek landed (`noteSubtitleReadsStart`, on the seek queue) is read in
            // a window. Once per settled seek, not per scrub step, on its own demuxer.
            refreshEmbedded(around: seconds)
        case .mediaStarted:
            // The track was chosen before the start time was applied, its cues for 0: those due at the start. The cue
            // on screen at a resume point is read in a window (a start at 0 needs none, playback reads from there).
            updateShown(at: seconds)
            refreshEmbedded(around: seconds)
        }
    }

    /// Redraws what libass shows for a change of the picture it is drawn over (a forced aspect ratio), when it is
    /// drawing.
    func videoDidChange() {
        redrawAuthored()
    }
}

// MARK: - Configuration

extension SubtitleController {
    /// Takes the subtitle settings of `configuration`: the style, how ASS is drawn, and `settings`.
    func apply(_ configuration: PlayerConfiguration) {
        style = SubtitleStyle(
            fontName: configuration.subtitleFontName, fontSize: configuration.subtitleFontSize,
            fontWeight: configuration.subtitleFontWeight, textColorHex: configuration.subtitleTextColorHex,
            backgroundColorHex: configuration.subtitleBgColorHex, backgroundOpacity: configuration.subtitleBgOpacity)
        usesAuthoredStyles = configuration.usesAuthoredSubtitleStyles
        showsOnlyForced = configuration.showsOnlyForcedSubtitles
        assStyleOverride = configuration.assStyleOverride
        scale = configuration.subtitleScale
        position = configuration.subtitlePosition
        settings = Settings(encoding: configuration.subtitleEncoding, trackLanguages: configuration.trackLanguages)
    }
}

// MARK: - History

extension SubtitleController {
    /// Writes the selection and the delay to persist. Subtitles are `subtitlesOff` when disabled, a local file is
    /// saved by its path, and a network one by its language, title and kind (`ListedSubtitle`). A selection made on
    /// load by `TrackAutoSelection` isn't saved.
    func writePreferences(into preferences: inout PlaybackPreferences) {
        preferences.subtitleDelay = delay
        if selectionIsAutomatic {
            // Left as saved: nothing, or a track this file no longer has.
        } else if let id = selectedTrackId {
            let track = tracks.first { $0.id == id }
            if let track, track.isSidecar, let url = track.externalURL {
                preferences.subtitleTrackId = PlaybackRecord.externalSubtitle
                preferences.externalSubtitlePath = url.path
                preferences.externalSubtitleStreamIndex = track.streamIndex
            } else if let track, track.isExternal {
                preferences.subtitleTrackId = PlaybackRecord.listedSubtitle
                preferences.listedSubtitle = ListedSubtitle(
                    language: track.language, title: track.title, isAutoGenerated: track.isAutoGenerated)
            } else if track != nil {
                preferences.subtitleTrackId = id
            }
        } else {
            preferences.subtitleTrackId = PlaybackRecord.subtitlesOff
        }
    }

    /// Selects the subtitles saved for the file, or none when they were turned off. Returns whether there was a
    /// selection to restore: a saved file that moved or a track the media no longer has leaves the choice to
    /// `TrackAutoSelection`.
    /// A saved file is one `readFiles` read (`MediaSubtitleFiles.Lookup.savedPath`).
    private func restoreSelection(
        from saved: PlaybackPreferences?, among tracks: [SubtitleTrack], readFiles: MediaSubtitleFiles
    ) -> Bool {
        guard let id = saved?.subtitleTrackId else { return false }
        if id == PlaybackRecord.subtitlesOff {
            select(trackId: nil, persistHistory: false)
            return true
        }
        if id == PlaybackRecord.externalSubtitle {
            // Not read when it moved since.
            guard let path = saved?.externalSubtitlePath, let read = readFiles[URL(fileURLWithPath: path)],
                let trackId = externalTrack(among: addReadFile(read), streamIndex: saved?.externalSubtitleStreamIndex)
            else {
                AppLog.warning(
                    .subtitles, "Saved external subtitle file is missing: \(saved?.externalSubtitlePath ?? "no path")")
                return false
            }
            select(trackId: trackId, persistHistory: false)
            AppLog.info(.subtitles, "Restored external subtitle file from saved history: \(path)")
            return true
        }
        if id == PlaybackRecord.listedSubtitle {
            guard let listed = saved?.listedSubtitle else { return false }
            // Of the files in its language and kind, the one of the same title, else the first; one of no language
            // is only told by its title.
            let matching = tracks.filter {
                $0.isExternal && !$0.isSidecar && $0.language == listed.language
                    && $0.isAutoGenerated == listed.isAutoGenerated
            }
            let sameTitle = matching.first { $0.title == listed.title }
            guard let track = sameTitle ?? (listed.language == "und" ? nil : matching.first) else {
                return false
            }
            select(trackId: track.id, persistHistory: false)
            AppLog.info(.subtitles, "Restored subtitle file '\(track.title)' from saved history")
            return true
        }
        guard tracks.contains(where: { $0.id == id }) else { return false }
        select(trackId: id, persistHistory: false)
        AppLog.info(.subtitles, "Restored subtitle track from saved history: \(id)")
        return true
    }

    /// The track of an external file to restore: the saved stream (one language of a VobSub index), else the first.
    func externalTrack(among ids: [Int], streamIndex: Int?) -> Int? {
        guard let streamIndex else { return ids.first }
        return ids.first { id in tracks.first { $0.id == id }?.streamIndex == streamIndex } ?? ids.first
    }
}

// MARK: - Showing

extension SubtitleController {
    func updateShown(at seconds: Double) {
        // A cue due at `t` shows at `t + delay`.
        let playbackSeconds = seconds
        let seconds = seconds - delay
        if let id = selectedTrackId,
            let track = tracks.first(where: { $0.id == id }),
            !track.isExternal,
            let demuxer = host?.demuxer
        {
            // Shown ahead of the picture, the track may be due past what playback has read: read on ahead of it,
            // unless a read is under way (no restart per time tick).
            if delay < 0, windowRead == nil {
                refreshEmbedded(around: playbackSeconds)
            }
            // Embedded tracks grow as playback reads them: refresh the document only when its version changes
            let currentVersion = demuxer.liveSubtitleVersion
            if currentVersion != self.lastObservedLiveVersion || self.activeDocument == nil {
                self.lastObservedLiveVersion = currentVersion
                self.activeDocument = demuxer.getLiveSubtitleDocument()
            }
            show(activeDocument, at: seconds)
            return
        }

        show(activeDocument, at: seconds)
    }

    private func show(_ document: SubtitleDocument?, at seconds: Double) {
        cues = document?.activeCues(at: seconds) ?? []
        if isDrawingAuthored {
            renderAuthored(at: seconds)
            return
        }
        var shown = document?.activeImageCues(at: seconds) ?? []
        if showsOnlyForced, !shown.isEmpty, tracks.first(where: { $0.id == selectedTrackId })?.isForced != true {
            shown = shown.compactMap { $0.forcedOnly() }
        }
        if shown != images { images = shown }
    }
}
