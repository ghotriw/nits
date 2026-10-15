import AppKit
import CoreMedia
import Foundation

public enum RenderMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "Auto (Display Adaptive)"
    case system = "Hardware Passthrough (Apple DisplayLayer)"
    case metalToneMap = "Metal Tone Mapping (BT.2390)"

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
    @MainActor var currentTime: Double { get }
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
    @MainActor var videoCodecName: String { get }
    @MainActor var videoBitDepth: Int { get }
    @MainActor var videoColorPrimaries: String { get }
    @MainActor var videoTransferFunction: String { get }
    @MainActor var videoDolbyVisionProfile: String? { get }
    @MainActor var videoSourcePeakNits: Float { get }

    @MainActor var renderMode: RenderMode { get set }
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

    @MainActor var droppedFramesCount: Int { get }
    @MainActor var pipelineDroppedFramesCount: Int { get }
    @MainActor var speedSkippedFramesCount: Int { get }
    @MainActor var thumbnailManager: ThumbnailManager { get }

    @MainActor func renderCurrentFrame()
}

/// Track selection and inspection for audio and subtitle streams.
public protocol PlayerTrackControlling: AnyObject, Sendable {
    @MainActor var audioTracks: [MediaDemuxer.AudioTrack] { get }
    @MainActor var selectedAudioTrackId: Int { get }
    @MainActor func selectAudioTrack(id: Int)

    @MainActor var subtitleTracks: [SubtitleTrack] { get }
    @MainActor var selectedSubtitleTrackId: Int? { get }
    @MainActor func selectSubtitleTrack(id: Int?)
    @MainActor func loadExternalSubtitle(url: URL)
}

/// Container chapter markers and navigation.
public protocol PlayerChapterControlling: AnyObject, Sendable {
    @MainActor var chapters: [MediaChapter] { get }
    @MainActor var currentChapterIndex: Int? { get }
    @MainActor func seekToChapter(_ chapter: MediaChapter)
    @MainActor @discardableResult func nextChapter() -> MediaChapter?
    @MainActor @discardableResult func previousChapter() -> MediaChapter?
}

/// Visual formatting, styling, and text state for subtitle rendering.
public protocol PlayerSubtitleStyling: AnyObject, Sendable {
    @MainActor var currentSubtitleText: String? { get }
    @MainActor var currentSubtitleCue: SubtitleCue? { get }
    @MainActor var currentSubtitleCues: [SubtitleCue] { get }
    @MainActor var subtitleFontSize: Double { get set }
    @MainActor var subtitleFontName: String { get set }
    @MainActor var subtitleFontWeight: String { get set }
    @MainActor var subtitleTextColorHex: String { get set }
    @MainActor var subtitleBgColorHex: String { get set }
    @MainActor var subtitleBgOpacity: Double { get set }
}

/// Playlist management, queues, and sequential navigation.
public protocol PlayerPlaylistControlling: AnyObject, Sendable {
    @MainActor var playlist: PlaylistManager { get }
    @MainActor func playNext()
    @MainActor func playPrevious()
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
}

/// Display layer geometry while Picture in Picture uses it (see `PlayerEngine.pictureInPictureLayerGeometry`).
public enum PictureInPictureLayerGeometry: Equatable, Sendable {
    /// PiP mirrors the layer 1:1 without scaling, so the layer takes the PiP window's content size (points).
    case pipWindow(CGSize)
    /// Handing back: the layer covers just the video's aspect-fit rect, which PiP animates its window onto.
    /// A full-view layer of another aspect ratio would leave a band beside the video during that animation.
    case videoRect
}
