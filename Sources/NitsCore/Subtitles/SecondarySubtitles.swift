import Foundation
import Observation

/// The second subtitle track shown with the selected one (a translation above the dialogue), as mpv's
/// `secondary-sid` and IINA's second subtitle. Drawn as plain text at the top of the picture, whatever position its
/// cues ask for; while it is on, the selected track's text is drawn at the bottom the same way (`SubtitleController.textCues`),
/// as two tracks that each place themselves would overlap. Held by `SubtitleController`, which tells it when time
/// moves and when the media goes.
///
/// A file's track is read whole, in the background, when chosen. An embedded one is collected from the packets playback
/// reads, as the selected track is (`MediaDemuxer.secondarySubtitleTracker`): choosing it reads nothing more of the
/// file, a network volume included; a window read fills in the cue on screen now (`SubtitleController.refreshEmbedded`).
/// Only text tracks can be second (not pictures or closed captions).
@MainActor
@Observable
public final class SecondarySubtitles {
    /// The track shown second, `nil` for none. Set with `select(trackId:)`.
    public internal(set) var selectedTrackId: Int?
    /// The cues on screen (subtitle delay applied), already placed at the top.
    public internal(set) var cues: [SubtitleCue] = []

    public var isActive: Bool { selectedTrackId != nil }

    /// Distance of the track from the picture's top edge, as a fraction of its height (0-0.5).
    public var inset: Double = SecondarySubtitles.defaultInset {
        didSet {
            // A value from outside (defaults, a host) stays on the picture.
            let clamped =
                inset.isFinite
                ? min(max(inset, Self.insetRange.lowerBound), Self.insetRange.upperBound) : Self.defaultInset
            if clamped != inset { inset = clamped }
        }
    }
    public nonisolated static let defaultInset: Double = 0.05
    public nonisolated static let insetRange: ClosedRange<Double> = 0...0.5

    /// Seconds the track is shifted by, as `SubtitleController.delay` is the selected one's: its own, kept for the file.
    public internal(set) var delay: Double = 0

    @ObservationIgnored weak var controller: SubtitleController?
    @ObservationIgnored private var document: SubtitleDocument?
    @ObservationIgnored private var load: SubtitleController.Load?
    /// The key of the track as restored on load, not chosen by the user: kept in what is saved if it can't be read.
    @ObservationIgnored private var restoredKey: String?
    /// The track is the media's own, collected by the demuxer as playback reads.
    @ObservationIgnored private var isLive = false
    /// `MediaDemuxer.liveSubtitleVersion(of:)` of the document shown.
    @ObservationIgnored private var observedVersion = -1

    init() {}

    /// Whether `track` can be shown second: text, not pictures or captions in the video.
    public func canShow(_ track: SubtitleTrack) -> Bool {
        track.format != .bitmap && track.closedCaptionField == nil && !track.captionsInVideo
    }

    /// The tracks that can be shown second now: not the selected one.
    public var candidates: [SubtitleTrack] {
        guard let controller else { return [] }
        return controller.tracks.filter { canShow($0) && $0.id != controller.selectedTrackId }
    }

    /// Shows the track `id` second, or none for `nil`. Ignored for a track that can't be (`canShow`) or is the
    /// selected one.
    public func select(trackId id: Int?) {
        select(trackId: id, persist: true)
    }

    /// `persist` is false for the choice restored on load, which is already saved.
    func select(trackId id: Int?, persist: Bool) {
        guard let controller else { return }
        // Chosen again: nothing to redo.
        if persist, let id, id == selectedTrackId { return }
        let track = id.flatMap { id in controller.tracks.first { $0.id == id } }
        let usable = track.flatMap { canShow($0) && $0.id != controller.selectedTrackId ? $0 : nil }
        if id != nil, usable == nil { return }
        clear()
        if persist { controller.unrestoredSecondaryKey = nil }
        restoredKey = persist ? nil : usable.map(controller.key(of:))
        selectedTrackId = usable?.id
        delay = usable.map { controller.delay(of: $0) } ?? 0
        controller.secondaryDidChange()
        if persist { controller.host?.saveCurrentPlaybackProgress() }
        guard let track = usable else { return }
        if !track.isExternal {
            isLive = true
            controller.host?.demuxer?.selectSecondarySubtitleTrack(trackId: track.id)
            show(at: controller.shownSeconds - delay)
            controller.refreshEmbedded(around: controller.shownSeconds, of: .secondary)
            if persist { controller.rereadForRendition(trackId: track.id) }
        } else if let document = controller.cachedDocument(of: track) {
            self.document = document
            show(at: controller.shownSeconds - delay)
        } else if let read = controller.documentReader(for: track) {
            start(track, read: read)
        } else {
            fail(track.id)
        }
        AppLog.info(.subtitles, "Second subtitle track: \(track.id)")
    }

    /// The track can't be shown: it is given up, so the main track isn't kept at the bottom, nor libass off, for nothing.
    private func fail(_ id: Int) {
        AppLog.warning(.subtitles, "Can't read second subtitle track \(id)")
        guard selectedTrackId == id else { return }
        if let restoredKey { controller?.unrestoredSecondaryKey = restoredKey }
        restoredKey = nil
        clear()
        selectedTrackId = nil
        delay = 0
        controller?.secondaryDidChange()
    }

    /// Reads the track again (its text was read in another encoding).
    func reload() {
        if let id = selectedTrackId { select(trackId: id, persist: false) }
    }

    /// Takes the track away if it is `id`, for it to become the main one: the caller redraws.
    func release(trackId id: Int) {
        if selectedTrackId == id { reset() }
    }

    /// Takes the second track away, with the media.
    func reset() {
        clear()
        restoredKey = nil
        selectedTrackId = nil
        delay = 0
    }

    private func clear() {
        load?.cancel()
        load = nil
        document = nil
        if isLive {
            isLive = false
            observedVersion = -1
            controller?.host?.demuxer?.selectSecondarySubtitleTrack(trackId: nil)
            controller?.secondaryReads.cancelWindow()
        }
        if !cues.isEmpty { cues = [] }
    }

    private func start(_ track: SubtitleTrack, read: @escaping @Sendable (FFmpegInterrupt) async -> SubtitleDocument?) {
        let id = track.id
        let generation = controller?.mediaGeneration
        let interrupt = FFmpegInterrupt()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let document = await read(interrupt)
            await MainActor.run {
                guard let self, !interrupt.isCancelled, !Task.isCancelled, self.selectedTrackId == id,
                    self.controller?.mediaGeneration == generation
                else { return }
                self.load = nil
                guard let document else {
                    self.fail(id)
                    return
                }
                self.controller?.cache(document, of: track)
                self.document = document
                self.show(at: (self.controller?.shownSeconds ?? 0) - self.delay)
            }
        }
        load = SubtitleController.Load(task: task, interrupt: interrupt)
    }

    /// Shows what is due at `seconds` on the track's own timeline (the delay is applied).
    func show(at seconds: Double) {
        if isLive, let demuxer = controller?.host?.demuxer {
            // Collected as playback reads: a new document only when the version changes.
            let version = demuxer.liveSubtitleVersion(of: .secondary)
            if version != observedVersion || document == nil {
                observedVersion = version
                document = demuxer.liveSubtitleDocument(of: .secondary)
            }
        }
        let due = (document?.activeCues(at: seconds) ?? []).map {
            // Their own ids could be the selected track's: the overlay tells cues apart by id.
            SubtitleCue(
                id: -$0.id - 1, startTime: $0.startTime, endTime: $0.endTime, text: $0.text, alignment: .topCenter)
        }
        if due != cues { cues = due }
    }
}

// MARK: - Delay

extension SecondarySubtitles {
    /// Shifts the track by `seconds` (clamped to `SubtitleController.delayRange`, rounded to milliseconds) and saves the
    /// delay for the track. Nothing without a second track.
    public func setDelay(_ seconds: Double) {
        guard let controller, let id = selectedTrackId, let track = controller.tracks.first(where: { $0.id == id })
        else { return }
        let clamped = SubtitleController.clampedDelay(seconds)
        guard clamped != delay else { return }
        delay = clamped
        controller.store(delay: clamped, of: track)
        show(at: controller.shownSeconds - clamped)
        // The track is due at another time now, which may lie outside what was read.
        if isLive { controller.refreshEmbedded(around: controller.shownSeconds, of: .secondary) }
    }

    public func stepDelay(by delta: Double) {
        setDelay(delay + delta)
    }

    public func resetDelay() {
        setDelay(0)
    }
}

// MARK: - Files

extension SecondarySubtitles {
    /// Adds a subtitle file as a track and shows it second; see `SubtitleController.addExternal(urls:)`. A file of
    /// pictures can't be second (`canShow`): it is added, not shown, and the result is `.unreadable`.
    @discardableResult
    public func addExternal(url: URL) async -> AddedSubtitleFiles {
        guard let controller else { return .mediaChanged }
        return await controller.addExternal(urls: [url], asSecondary: true)
    }
}
