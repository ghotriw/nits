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

/// What describes the media loaded, which the playback, video and chapter domains read.
public protocol PlayerMediaDescribing: AnyObject, Sendable {
    /// Duration, chapters and the video stream of the media loaded; empty while none is.
    @MainActor var media: MediaInfo { get }
}

/// Controls media transport, rate, volume, and playback lifecycle.
public protocol PlayerPlaybackControlling: PlayerMediaDescribing {
    @MainActor var playbackState: PlaybackState { get }
    @MainActor var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)? { get set }
    @MainActor var onPlaybackStateChanged: ((_ state: PlaybackState) -> Void)? { get set }
    /// Called once when a requested media or playlist finishes loading: `(request, historyKey, title, duration)`.
    @MainActor var onMediaLoaded:
        ((_ request: MediaLoadRequest, _ historyKey: String, _ title: String, _ duration: Double) -> Void)?
    { get set }
    @MainActor var onRelativeSeekResolved: ((_ offset: Double, _ currentTime: Double) -> Void)? { get set }
    /// Called when `isBuffering` changes.
    @MainActor var onBufferingChanged: ((_ isBuffering: Bool) -> Void)? { get set }
    /// Called when a seek starts and when it settles (`isSeeking || pendingSeekTime != nil` changes).
    @MainActor var onSeekingChanged: ((_ isSeeking: Bool) -> Void)? { get set }
    @MainActor var currentTime: Double { get }
    /// Timeline second up to which media has been read ahead of `currentTime`; `media.duration` once read to the end.
    @MainActor var bufferedTime: Double { get }
    /// Playback is held until media data arrives again; `playbackState` stays `.playing` meanwhile.
    @MainActor var isBuffering: Bool { get }
    @MainActor var pendingSeekTime: Double? { get }
    @MainActor var isSeeking: Bool { get }
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

/// Picture geometry, render mode, deinterlacing and Metal tone mapping; the video stream is `media.video`.
public protocol PlayerVideoControlling: PlayerMediaDescribing {
    @MainActor var nominalFrameDuration: Double { get }
    /// Aspect ratio override, crop, scaling, zoom and pan of the picture; presentation only.
    @MainActor var videoGeometry: VideoGeometrySettings { get set }
    /// `media.video.displayAspectRatio` with the aspect override and crop of `videoGeometry` applied.
    @MainActor var contentAspectRatio: Double { get }

    @MainActor var renderMode: RenderMode { get set }
    /// Applies to interlaced content; changing it re-seeks to the current frame.
    @MainActor var deinterlaceMode: DeinterlaceMode { get set }
    @MainActor var isHDRDisplay: Bool { get set }
    @MainActor var isToneMappingPermitted: Bool { get set }
    nonisolated var activeRenderMode: RenderMode { get }
    @MainActor var isDisplaySleepDisabled: Bool { get }

    /// The Metal path's tone mapping: exposure, shadow lift, target white, sharpness, Dolby Vision trims.
    @MainActor var toneMapping: ToneMapController { get }

    @MainActor var droppedFramesCount: Int { get }
    @MainActor var pipelineDroppedFramesCount: Int { get }
    @MainActor var speedSkippedFramesCount: Int { get }
    @MainActor var thumbnailManager: ThumbnailManager { get }

    @MainActor func renderCurrentFrame()
    /// The frame on screen as a still image, as the active render mode shows it; nil without a frame.
    @MainActor func captureFrame() async -> CapturedFrame?
}

/// Track selection and inspection for audio streams and HLS variants; subtitles are `PlayerSubtitleControlling`.
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

    /// The pictures a resolved page offers as files of its own (yt-dlp's), best first; empty for anything else.
    @MainActor var videoFormats: [VideoFormat] { get }
    @MainActor var selectedVideoFormatId: String? { get }
    /// Plays a picture of `videoFormats` instead, from the current frame; the audio and the rest stay.
    @MainActor func selectVideoFormat(id: String)

    /// Seconds audio is shifted against the picture: positive plays it later, negative earlier.
    @MainActor var audioDelay: Double { get }
    @MainActor func setAudioDelay(_ seconds: Double)
    @MainActor func stepAudioDelay(by delta: Double)
    @MainActor func resetAudioDelay()

    /// Adds audio files as tracks (a dub, a commentary) and selects the first track of the last file that could be
    /// read, which it returns (`nil`: none could). `onTracksChanged` reports the tracks and the selection once.
    @MainActor @discardableResult func loadExternalAudio(urls: [URL]) async -> MediaDemuxer.AudioTrack?
}

/// Container chapter markers and navigation.
public protocol PlayerChapterControlling: PlayerMediaDescribing {
    @MainActor var currentChapterIndex: Int? { get }
    @MainActor func seekToChapter(_ chapter: MediaChapter)
    @MainActor @discardableResult func nextChapter() -> MediaChapter?
    @MainActor @discardableResult func previousChapter() -> MediaChapter?
}

/// Host-provided action buttons ("Skip Intro", "Next Episode") shown for spans of the timeline.
public protocol PlayerActionButtonControlling: AnyObject, Sendable {
    @MainActor var actionButtons: [PlaybackActionButton] { get }
    @MainActor var activeActionButton: PlaybackActionButton? { get }
    @MainActor var onActionButton: ((_ id: String) -> Void)? { get set }
    @MainActor func performActionButton(_ button: PlaybackActionButton)
    @MainActor func setActionButtons(_ buttons: [PlaybackActionButton])
}

/// Subtitle tracks and selection, their delay, what is on screen and how it is drawn.
public protocol PlayerSubtitleControlling: AnyObject, Sendable {
    @MainActor var subtitles: SubtitleController { get }
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
    PlayerSubtitleControlling,
    PlayerPlaylistControlling,
    PlayerUIOverlayControlling
{}

// MARK: - Default Implementations & Convenience Extensions

extension PlayerPlaybackControlling {
    @MainActor
    public var onMediaLoaded:
        ((_ request: MediaLoadRequest, _ historyKey: String, _ title: String, _ duration: Double) -> Void)?
    {
        get { nil }
        set {}
    }

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
    @MainActor public var contentAspectRatio: Double { media.video.displayAspectRatio }
}

/// Display layer geometry while Picture in Picture uses it (see `PlayerEngine.pictureInPictureLayerGeometry`).
public enum PictureInPictureLayerGeometry: Equatable, Sendable {
    /// PiP mirrors the layer 1:1 without scaling, so the layer takes the PiP window's content size (points).
    case pipWindow(CGSize)
    /// Handing back: the layer covers just the video's aspect-fit rect, which PiP animates its window onto.
    /// A full-view layer of another aspect ratio would leave a band beside the video during that animation.
    case videoRect
}
