import Foundation
import NitsCore
import Observation

/// What the main menu shows of a player, as values: `PlayerCommands` reads only this.
///
/// The menu's `body` depends on whatever it reads, and every time it runs SwiftUI rebuilds the main menu, which closes
/// a submenu the pointer is in. Read straight from the engine, the menu would depend on far more than it shows: Next
/// on every item of the playlist (whose durations come in a few times a second while a long one is probed), the video
/// items on the whole `MediaInfo` (rewritten by an HLS variant switch), Actual Zoom on every step of a pan. As one
/// value, compared (`PlayerMenuStateMirror`), it changes only when something the menu shows does.
public struct PlayerMenuState: Equatable, Sendable {
    /// Whether there is a player at all: without one, every item is off.
    public var hasPlayer = false

    // Playback
    public var hasNextTrack = false
    public var hasPreviousTrack = false
    public var hasChapters = false
    public var seekStepSeconds = PlayerConfiguration.defaultSeekStepSeconds
    public var canJumpToTime = false

    // Audio
    public var isMuted = false

    // Subtitles
    public var isMediaLoaded = false
    public var subtitleTracks: [SubtitleTrack] = []
    public var selectedSubtitleTrackId: Int?
    public var subtitleEncoding: String.Encoding?
    public var canSetSubtitleEncoding = false
    public var subtitleDelay = 0.0
    public var secondarySubtitleCandidates: [SubtitleTrack] = []
    public var selectedSecondarySubtitleTrackId: Int?
    public var secondarySubtitleEncoding: String.Encoding?
    public var canSetSecondarySubtitleEncoding = false
    public var secondarySubtitleDelay = 0.0

    // Video
    public var renderMode = RenderMode.default
    public var hasVideo = false
    public var aspectRatio: RationalAspectRatio?
    public var crop: RationalAspectRatio?
    public var scaling: VideoScaling
    /// No zoom and no pan: Actual Zoom has nothing to reset.
    public var isZoomReset: Bool

    // View
    public var isPlaylistPresented = false
    public var isPlaylistAvailable = false
    public var isChaptersPresented = false
    public var isQuickSettingsPresented = false
    public var showDebugHUD = false
    public var supportsFullscreen = false
    public var isPictureInPictureActive = false
    public var canTogglePictureInPicture = false

    /// No player: everything off, the picture's layout a new player's.
    public init() {
        self.init(geometry: VideoGeometrySettings())
    }

    /// Of the picture's layout, what the menu shows: not the pan itself, which changes at every step of a drag.
    private init(geometry: VideoGeometrySettings) {
        aspectRatio = geometry.aspectRatio
        crop = geometry.crop
        scaling = geometry.scaling
        isZoomReset = geometry.zoom == 1.0 && geometry.pan == .zero
    }

    @MainActor
    public init(_ actions: any PlayerActions) {
        self.init(geometry: actions.videoGeometry)
        hasPlayer = true
        hasNextTrack = actions.hasNextTrack
        hasPreviousTrack = actions.hasPreviousTrack
        hasChapters = actions.hasChapters
        seekStepSeconds = actions.seekStepSeconds
        canJumpToTime = actions.canJumpToTime

        isMuted = actions.isMuted

        isMediaLoaded = actions.isMediaLoaded
        subtitleTracks = actions.subtitleTracks
        selectedSubtitleTrackId = actions.selectedSubtitleTrackId
        subtitleEncoding = actions.subtitleEncoding
        canSetSubtitleEncoding = actions.canSetSubtitleEncoding
        subtitleDelay = actions.subtitleDelay
        secondarySubtitleCandidates = actions.secondarySubtitleCandidates
        selectedSecondarySubtitleTrackId = actions.selectedSecondarySubtitleTrackId
        secondarySubtitleEncoding = actions.secondarySubtitleEncoding
        canSetSecondarySubtitleEncoding = actions.canSetSecondarySubtitleEncoding
        secondarySubtitleDelay = actions.secondarySubtitleDelay

        renderMode = actions.renderMode
        hasVideo = actions.hasVideo

        isPlaylistPresented = actions.isPlaylistPresented
        isPlaylistAvailable = actions.isPlaylistAvailable
        isChaptersPresented = actions.isChaptersPresented
        isQuickSettingsPresented = actions.isQuickSettingsPresented
        showDebugHUD = actions.showDebugHUD
        supportsFullscreen = actions.supportsFullscreen
        isPictureInPictureActive = actions.isPictureInPictureActive
        canTogglePictureInPicture = actions.canTogglePictureInPicture
    }
}

/// Keeps a `PlayerMenuState` up to date and publishes it only when it differs: observers of `state` (the menu) are
/// woken by what the menu shows, not by everything it is read from.
///
/// Reads the state under `withObservationTracking`; a change of anything read reads it again on the next turn of the
/// main actor (several changes in one turn, one read), and assigns it only if it differs. So everything read must be
/// observable: a value that is not would show stale until something observable changes.
@MainActor
@Observable
final class PlayerMenuStateMirror {
    private(set) var state = PlayerMenuState()
    @ObservationIgnored
    private var read: (@MainActor () -> PlayerMenuState)?

    init() {}

    /// Reads the state for the first time and from then on whenever it may have changed. Call it outside any
    /// observation tracking (not from a view's `body` or the menu's): a nested `withObservationTracking` takes in
    /// everything it reads into the outer one, so the outer observer would depend on all of it after all.
    func start(reading read: @escaping @MainActor () -> PlayerMenuState) {
        self.read = read
        refresh()
    }

    /// Stops reading: `state` keeps its last value. A refresh already scheduled does nothing and observes nothing, so
    /// the chain of observations ends with it.
    func stop() {
        read = nil
    }

    private func refresh() {
        guard let read else { return }
        let current = withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Called in the `willSet` of the change, before the value is written: read it once it is.
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        if current != state {
            state = current
        }
    }
}
