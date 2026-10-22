import AppKit
import CoreMedia
import Foundation

public enum RenderMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "Auto (Display Adaptive)"
    case system = "Hardware Passthrough (Apple DisplayLayer)"
    case metalToneMap = "Metal Tone Mapping (BT.2390)"

    public var id: String { rawValue }
}

/// How interlaced video is turned into progressive frames.
public enum DeinterlaceMode: String, CaseIterable, Identifiable, Sendable {
    /// A frame per field (50 / 60 fps), except where the two fields show the same moment.
    case auto = "Auto (Frame per Field)"
    /// A frame per interlaced frame (25 / 30 fps), keeping the first field.
    case frameRate = "Frame per Frame"
    /// Frames are shown woven, as stored.
    case off = "Off"

    public var id: String { rawValue }
}

public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case completed
    case failed(String)
}

// MARK: - Granular Protocol Domains

/// Controls media transport, rate, volume, and playback lifecycle.
public protocol PlayerPlaybackControlling: AnyObject, Sendable {
    @MainActor var playbackState: PlaybackState { get }
    @MainActor var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)? { get set }
    @MainActor var onPlaybackStateChanged: ((_ state: PlaybackState) -> Void)? { get set }
    @MainActor var onRelativeSeekResolved: ((_ offset: Double, _ currentTime: Double) -> Void)? { get set }
    /// Called when `isBuffering` changes.
    @MainActor var onBufferingChanged: ((_ isBuffering: Bool) -> Void)? { get set }
    /// Called when a seek starts and when it settles (`isSeeking || pendingSeekTime != nil` changes).
    @MainActor var onSeekingChanged: ((_ isSeeking: Bool) -> Void)? { get set }
    @MainActor var currentTime: Double { get }
    /// Timeline second up to which media has been read ahead of `currentTime`; `duration` once read to the end.
    @MainActor var bufferedTime: Double { get }
    /// Playback is held until media data arrives again; `playbackState` stays `.playing` meanwhile.
    @MainActor var isBuffering: Bool { get }
    @MainActor var pendingSeekTime: Double? { get }
    @MainActor var isSeeking: Bool { get }
    @MainActor var duration: Double { get }
    @MainActor var isPlaying: Bool { get }
    @MainActor var isLoaded: Bool { get }
    @MainActor var isLoading: Bool { get }
    @MainActor var loadError: String? { get }
    @MainActor var mediaTitle: String { get set }
    @MainActor var artworkData: Data? { get }
    @MainActor var artworkURL: URL? { get }

    @MainActor var volume: Float { get set }
    @MainActor var isMuted: Bool { get set }
    @MainActor var playbackRate: Double { get set }
    @MainActor var seekStepSeconds: Double { get set }
    @MainActor var exactSeekOnSinglePress: Bool { get set }

    @MainActor func load(_ request: MediaLoadRequest)
    @MainActor func loadAsync(_ request: MediaLoadRequest) async
    @MainActor func stop()
    @MainActor func play()
    @MainActor func pause()
    @MainActor func togglePlayPause()
    @MainActor func seek(to seconds: Double)
    @MainActor func seek(to seconds: Double, exact: Bool)
    @MainActor @discardableResult func seekRelative(by seconds: Double) -> Double
    @MainActor func seekRelative(by seconds: Double, exact: Bool)
    @MainActor func stepFrameForward()
    @MainActor func stepFrameBackward()
    @MainActor func stepVolume(by delta: Float)
    @MainActor func toggleMute()
    @MainActor func setPlaybackRate(_ rate: Double)
    @MainActor func stepPlaybackRate(by delta: Double)
    @MainActor func resetPlaybackRate()
}

/// Metadata, format properties, display tracking, and Metal tone-mapping rendering controls.
public protocol PlayerVideoControlling: AnyObject, Sendable {
    @MainActor var hasVideo: Bool { get }
    @MainActor var videoWidth: Int { get }
    @MainActor var videoHeight: Int { get }
    @MainActor var nominalFrameDuration: Double { get }
    @MainActor var sampleAspectRatio: RationalAspectRatio { get }
    @MainActor var displayAspectRatio: Double { get }
    /// Aspect ratio override, crop, scaling, zoom and pan of the picture; presentation only.
    @MainActor var videoGeometry: VideoGeometrySettings { get set }
    /// `displayAspectRatio` with the aspect override and crop of `videoGeometry` applied.
    @MainActor var contentAspectRatio: Double { get }
    @MainActor var videoCodecName: String { get }
    @MainActor var videoBitDepth: Int { get }
    @MainActor var videoColorPrimaries: String { get }
    @MainActor var videoTransferFunction: String { get }
    @MainActor var videoDolbyVisionProfile: String? { get }
    @MainActor var videoSourcePeakNits: Float { get }

    @MainActor var renderMode: RenderMode { get set }
    /// Whether the loaded video is interlaced (declares a field order, or is standard-definition DV).
    @MainActor var isInterlacedContent: Bool { get }
    /// Applies to interlaced content; changing it re-seeks to the current frame.
    @MainActor var deinterlaceMode: DeinterlaceMode { get set }
    @MainActor var isHDRDisplay: Bool { get set }
    @MainActor var isToneMappingPermitted: Bool { get set }
    nonisolated var activeRenderMode: RenderMode { get }
    @MainActor var isDisplaySleepDisabled: Bool { get }

    @MainActor var metalExposure: Float { get set }
    @MainActor var metalShadowLift: Float { get set }
    @MainActor var metalTargetNits: Float { get set }
    @MainActor var targetNitsScale: Float { get set }
    @MainActor var baseAdaptiveTargetNits: Float { get }
    @MainActor var metalSharpness: Float { get set }
    @MainActor var applyDolbyVisionTrims: Bool { get set }

    @MainActor var droppedFramesCount: Int { get }
    @MainActor var pipelineDroppedFramesCount: Int { get }
    @MainActor var speedSkippedFramesCount: Int { get }
    @MainActor var thumbnailManager: ThumbnailManager { get }

    @MainActor func renderCurrentFrame()
}

/// Track selection and inspection for audio and subtitle streams.
public protocol PlayerTrackControlling: AnyObject, Sendable {
    /// Called when the audio or subtitle tracks or HLS variants, or the selected ones, change (once per load and per
    /// `stop()`, and when a variant switch is asked for and when it plays).
    @MainActor var onTracksChanged: (() -> Void)? { get set }
    @MainActor var audioTracks: [MediaDemuxer.AudioTrack] { get }
    @MainActor var selectedAudioTrackId: Int { get }
    @MainActor func selectAudioTrack(id: Int)

    /// HLS variants, highest bandwidth first; empty for anything else.
    @MainActor var variants: [MediaDemuxer.StreamVariant] { get }
    @MainActor var selectedVariantId: Int? { get }
    /// Switches to a variant that `isSwitchable` and turns adaptive bitrate off.
    @MainActor func selectVariant(id: Int)
    /// Adaptive bitrate chooses the variant (network sources with variants).
    @MainActor var canSelectAutomaticVariant: Bool { get }
    @MainActor var isVariantAutomatic: Bool { get }
    @MainActor func selectAutomaticVariant()

    /// Seconds audio is shifted against the picture: positive plays it later, negative earlier.
    @MainActor var audioDelay: Double { get }
    @MainActor func setAudioDelay(_ seconds: Double)
    @MainActor func stepAudioDelay(by delta: Double)
    @MainActor func resetAudioDelay()

    @MainActor var subtitleTracks: [SubtitleTrack] { get }
    @MainActor var selectedSubtitleTrackId: Int? { get }
    @MainActor func selectSubtitleTrack(id: Int?)
    @MainActor func loadExternalSubtitle(url: URL)
    /// Adds subtitle files as tracks and selects the last one that could be read.
    @MainActor func loadExternalSubtitles(urls: [URL])

    /// Seconds subtitles are shifted by: positive shows them later, negative earlier.
    @MainActor var subtitleDelay: Double { get }
    @MainActor func setSubtitleDelay(_ seconds: Double)
    @MainActor func stepSubtitleDelay(by delta: Double)
    @MainActor func resetSubtitleDelay()
}

/// Container chapter markers and navigation.
public protocol PlayerChapterControlling: AnyObject, Sendable {
    @MainActor var chapters: [MediaChapter] { get }
    @MainActor var currentChapterIndex: Int? { get }
    @MainActor func seekToChapter(_ chapter: MediaChapter)
    @MainActor @discardableResult func nextChapter() -> MediaChapter?
    @MainActor @discardableResult func previousChapter() -> MediaChapter?
}

/// Host-provided action buttons ("Skip Intro", "Next Episode") shown for spans of the timeline.
public protocol PlayerActionButtonControlling: AnyObject, Sendable {
    @MainActor var actionButtons: [PlaybackActionButton] { get set }
    @MainActor var activeActionButton: PlaybackActionButton? { get }
    @MainActor var onActionButton: ((_ id: String) -> Void)? { get set }
    @MainActor func performActionButton(_ button: PlaybackActionButton)
}

/// Visual formatting, styling, and text state for subtitle rendering.
public protocol PlayerSubtitleStyling: AnyObject, Sendable {
    @MainActor var currentSubtitleText: String? { get }
    @MainActor var currentSubtitleCue: SubtitleCue? { get }
    @MainActor var currentSubtitleCues: [SubtitleCue] { get }
    /// Called with the cues on screen whenever they change (not per time tick).
    @MainActor var onSubtitleCuesChanged: (([SubtitleCue]) -> Void)? { get set }
    /// Bitmap subtitles on screen; the player draws them.
    @MainActor var currentSubtitleImages: [SubtitleImageCue] { get }
    /// The selected ASS track's script without events, ending in an `[Events]` section whose `Format:` the cues'
    /// `rawPayload` lines follow; `nil` for other tracks. Available before the track's first cue is reported.
    @MainActor var subtitleAssHeader: String? { get }
    /// Fonts the media attaches for the selected ASS track.
    @MainActor var subtitleAssFonts: [AssScript.Font] { get }
    /// Draw ASS / SSA subtitles with libass as authored (default) instead of as plain text in the style below.
    @MainActor var usesAuthoredSubtitleStyles: Bool { get set }
    /// Show only the forced sets of bitmap tracks (PGS, VobSub); text tracks are left as they are.
    @MainActor var showsOnlyForcedSubtitles: Bool { get set }
    /// How much of the subtitle style replaces an ASS script's own on its dialogue (libass' selective override).
    @MainActor var assStyleOverride: AssStyleOverride { get set }
    /// Size of ASS dialogue and picture subtitles (0.5-2); plain text has `subtitleFontSize`.
    @MainActor var subtitleScale: Double { get set }
    /// Height of bottom subtitles in percent of the picture from its top; 100 leaves them in place.
    @MainActor var subtitlePosition: Double { get set }
    /// Size in pixels of the area subtitles are drawn on; libass draws ASS subtitles once it is set.
    @MainActor var subtitleRenderSize: CGSize { get set }
    /// Whether libass draws the selected track, so its text cues aren't to be drawn again.
    @MainActor var isDrawingAuthoredSubtitles: Bool { get }
    @MainActor var subtitleFontSize: Double { get set }
    @MainActor var subtitleFontName: String { get set }
    @MainActor var subtitleFontWeight: String { get set }
    @MainActor var subtitleTextColorHex: String { get set }
    @MainActor var subtitleBgColorHex: String { get set }
    @MainActor var subtitleBgOpacity: Double { get set }
}

/// Playlist management, queues, and sequential navigation, through the playlist or a host's own queue.
public protocol PlayerPlaylistControlling: AnyObject, Sendable {
    @MainActor var playlist: PlaylistManager { get }
    @MainActor var onTrackNavigation: ((_ direction: TrackNavigationDirection) -> Void)? { get set }
    @MainActor var trackNavigation: TrackNavigation { get set }
    @MainActor var canPlayNext: Bool { get }
    @MainActor var canPlayPrevious: Bool { get }
    @MainActor @discardableResult func playNext() -> String?
    @MainActor @discardableResult func playPrevious() -> String?
    @MainActor func playPlaylistItem(id: UUID)
    @MainActor func removePlaylistItem(id: UUID)
}

/// UI diagnostic overlays and HUD display options.
public protocol PlayerUIOverlayControlling: AnyObject, Sendable {
    @MainActor var enableOSD: Bool { get set }
    @MainActor var showDebugHUD: Bool { get set }
    @MainActor func toggleDebugHUD()
}

// MARK: - Unified Engine Protocol

/// Unified player engine contract composed of granular functional domains.
public protocol PlayerEngineProtocol:
    PlayerPlaybackControlling,
    PlayerVideoControlling,
    PlayerTrackControlling,
    PlayerChapterControlling,
    PlayerActionButtonControlling,
    PlayerSubtitleStyling,
    PlayerPlaylistControlling,
    PlayerUIOverlayControlling
{}

// MARK: - Default Implementations & Convenience Extensions

extension PlayerPlaybackControlling {
    @MainActor
    public func seek(to seconds: Double) {
        seek(to: seconds, exact: true)
    }

    @MainActor
    @discardableResult
    public func seekRelative(by seconds: Double) -> Double {
        seekRelative(by: seconds, exact: false)
        return seconds
    }

    @MainActor
    public func setPlaybackRate(_ rate: Double) {}

    @MainActor
    public func stepPlaybackRate(by delta: Double) {}

    @MainActor
    public func resetPlaybackRate() {}

    @MainActor
    public func load(path: String) {
        load(MediaLoadRequest(path: path))
    }

    @MainActor
    public func load(path: String, title: String?) {
        load(MediaLoadRequest(path: path, title: title))
    }

    @MainActor
    public func load(path: String, headers: [String: String]) {
        load(MediaLoadRequest(path: path, headers: headers))
    }

    @MainActor
    public func load(path: String, title: String?, headers: [String: String], startTime: Double?) {
        load(MediaLoadRequest(path: path, title: title, headers: headers, startTime: startTime))
    }

    @MainActor
    public func load(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String],
        startTime: Double?,
        audioTrack: String?,
        subtitleTrack: String?
    ) {
        load(
            MediaLoadRequest(
                path: path,
                title: title,
                artworkData: artworkData,
                artworkURL: artworkURL,
                headers: headers,
                startTime: startTime,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack
            ))
    }

    @MainActor
    public func loadAsync(path: String) async {
        await loadAsync(MediaLoadRequest(path: path))
    }

    @MainActor
    public func loadAsync(path: String, title: String?) async {
        await loadAsync(MediaLoadRequest(path: path, title: title))
    }

    @MainActor
    public func loadAsync(path: String, headers: [String: String]) async {
        await loadAsync(MediaLoadRequest(path: path, headers: headers))
    }

    @MainActor
    public func loadAsync(path: String, title: String?, headers: [String: String], startTime: Double?) async {
        await loadAsync(MediaLoadRequest(path: path, title: title, headers: headers, startTime: startTime))
    }

    @MainActor
    public func loadAsync(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String],
        startTime: Double?,
        audioTrack: String?,
        subtitleTrack: String?
    ) async {
        await loadAsync(
            MediaLoadRequest(
                path: path,
                title: title,
                artworkData: artworkData,
                artworkURL: artworkURL,
                headers: headers,
                startTime: startTime,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack
            ))
    }
}

extension PlayerVideoControlling {
    public var isDisplaySleepDisabled: Bool { false }
    @MainActor public var videoGeometry: VideoGeometrySettings {
        get { VideoGeometrySettings() }
        set {}
    }
    @MainActor public var contentAspectRatio: Double { displayAspectRatio }
}

/// Display layer geometry while Picture in Picture uses it (see `PlayerEngine.pictureInPictureLayerGeometry`).
public enum PictureInPictureLayerGeometry: Equatable, Sendable {
    /// PiP mirrors the layer 1:1 without scaling, so the layer takes the PiP window's content size (points).
    case pipWindow(CGSize)
    /// Handing back: the layer covers just the video's aspect-fit rect, which PiP animates its window onto.
    /// A full-view layer of another aspect ratio would leave a band beside the video during that animation.
    case videoRect
}
