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

public protocol PlayerEngineProtocol: AnyObject, Sendable {
    @MainActor var playbackState: PlaybackState { get }
    @MainActor var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)? { get set }
    @MainActor var onPlaybackStateChanged: ((_ state: PlaybackState) -> Void)? { get set }
    @MainActor var onRelativeSeekResolved: ((_ offset: Double, _ currentTime: Double) -> Void)? { get set }
    @MainActor var currentTime: Double { get }
    @MainActor var pendingSeekTime: Double? { get }
    @MainActor var duration: Double { get }
    @MainActor var isPlaying: Bool { get }
    @MainActor var isLoaded: Bool { get }
    @MainActor var isLoading: Bool { get }
    @MainActor var loadError: String? { get }
    @MainActor var mediaTitle: String { get set }
    @MainActor var artworkData: Data? { get }
    @MainActor var artworkURL: URL? { get }
    @MainActor var hasVideo: Bool { get }
    @MainActor var videoWidth: Int { get }
    @MainActor var videoHeight: Int { get }
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

    @MainActor var volume: Float { get set }
    @MainActor var isMuted: Bool { get set }
    @MainActor var playbackRate: Double { get set }
    @MainActor var seekStepSeconds: Double { get set }
    @MainActor var exactSeekOnSinglePress: Bool { get set }
    @MainActor var enableOSD: Bool { get set }
    @MainActor var showDebugHUD: Bool { get set }
    @MainActor var audioTracks: [MediaDemuxer.AudioTrack] { get }
    @MainActor var selectedAudioTrackId: Int { get }
    @MainActor var subtitleTracks: [SubtitleTrack] { get }
    @MainActor var selectedSubtitleTrackId: Int? { get }
    @MainActor var currentSubtitleText: String? { get }
    @MainActor var currentSubtitleCue: SubtitleCue? { get }
    @MainActor var currentSubtitleCues: [SubtitleCue] { get }
    @MainActor var subtitleFontSize: Double { get set }
    @MainActor var subtitleFontName: String { get set }
    @MainActor var subtitleFontWeight: String { get set }
    @MainActor var subtitleTextColorHex: String { get set }
    @MainActor var subtitleBgColorHex: String { get set }
    @MainActor var subtitleBgOpacity: Double { get set }

    @MainActor func selectSubtitleTrack(id: Int?)
    @MainActor func loadExternalSubtitle(url: URL)

    @MainActor func load(path: String)
    @MainActor func load(path: String, title: String?)
    @MainActor func load(path: String, headers: [String: String])
    @MainActor func load(path: String, title: String?, headers: [String: String], startTime: Double?)
    @MainActor func load(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String],
        startTime: Double?,
        audioTrack: String?,
        subtitleTrack: String?
    )
    @MainActor func loadAsync(path: String) async
    @MainActor func loadAsync(path: String, title: String?) async
    @MainActor func loadAsync(path: String, headers: [String: String]) async
    @MainActor func loadAsync(path: String, title: String?, headers: [String: String], startTime: Double?) async
    @MainActor func loadAsync(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String],
        startTime: Double?,
        audioTrack: String?,
        subtitleTrack: String?
    ) async
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
    @MainActor func toggleDebugHUD()
    @MainActor func renderCurrentFrame()
    @MainActor func selectAudioTrack(id: Int)
    @MainActor var playlist: PlaylistManager { get }
    @MainActor func playNext()
    @MainActor func playPrevious()
    @MainActor func playPlaylistItem(id: UUID)
    @MainActor func removePlaylistItem(id: UUID)
}

extension PlayerEngineProtocol {
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
}

extension PlayerEngineProtocol {
    public var isDisplaySleepDisabled: Bool { false }
}
