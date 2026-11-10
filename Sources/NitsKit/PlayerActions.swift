import Foundation
import NitsCore
import SwiftUI

@MainActor
public protocol PlayerActions: AnyObject {
    var renderMode: RenderMode { get set }
    var metalSharpness: Float { get set }
    var isMuted: Bool { get }
    var playbackRate: Double { get set }
    var showDebugHUD: Bool { get }

    var canJumpToTime: Bool { get }
    var isJumpToPresented: Bool { get }
    var isQuickSettingsPresented: Bool { get }
    var isPlaylistPresented: Bool { get }
    /// Whether the playlist panel is offered; see `PlayerUIState.isPlaylistAvailable`.
    var isPlaylistAvailable: Bool { get }
    var isSidePanelPresented: Bool { get }
    var hasNextTrack: Bool { get }
    var hasPreviousTrack: Bool { get }
    var hasChapters: Bool { get }
    var isChaptersPresented: Bool { get }
    /// Whether a host action button ("Skip Intro") is on screen.
    var isActionButtonVisible: Bool { get }
    var hasVideo: Bool { get }
    var videoGeometry: VideoGeometrySettings { get }

    var seekStepSeconds: Double { get }

    /// What the main menu shows, which it reads alone (`PlayerCommands`). Changes only when something the menu shows
    /// does: a change that leaves it equal must not wake the menu, whose rebuild closes an open submenu. The default
    /// reads it anew each time, with no such filter.
    ///
    /// `PlayerSession`'s trails a change by one turn of the main actor (it is read again on the next one), which is
    /// fine for the menu, as a key press or a click comes on a later turn; but a host that reads it right after an
    /// action sees the value from before it.
    var menuState: PlayerMenuState { get }

    func togglePlayPause()
    func play()
    func pause()
    func seek(to seconds: Double)
    func stepFrameForward()
    func stepFrameBackward()
    func seekRelative(by seconds: Double)
    func seekForward()
    func seekBackward()
    /// An arrow key is pressed: its seeks (and its repeats') show frames, and playback resumes at `endScrubbing()`.
    func beginScrubbing()
    /// A key is released, or the window lost focus while the arrow was held.
    func endScrubbing()
    func stepVolume(by delta: Float)
    func toggleMute()
    func setPlaybackRate(_ rate: Double)
    func stepPlaybackRate(by delta: Double)
    func resetPlaybackRate()
    func stepSubtitleDelay(by delta: Double)
    func resetSubtitleDelay()
    func stepAudioDelay(by delta: Double)
    func toggleDebugHUD()
    func toggleQuickSettings()
    func togglePlaylist()
    func closeSidePanel()
    func playNextTrack()
    func playPreviousTrack()
    func toggleChapters()
    func nextChapter()
    func previousChapter()
    /// Whether the player is fullscreen; `esc` leaves it.
    var isFullscreen: Bool { get }
    /// Whether there is a fullscreen to toggle; `F` goes to the host when there is none.
    var supportsFullscreen: Bool { get }
    func toggleFullscreen()
    func exitFullscreen()
    var isPictureInPictureActive: Bool { get }
    var canTogglePictureInPicture: Bool { get }
    func togglePictureInPicture()
    func promptJumpToTime()
    func dismissJumpToTime()
    func pressActionButton()
    func dismissActionButton()
    func setVideoAspectRatio(_ ratio: RationalAspectRatio?)
    func setVideoCrop(_ ratio: RationalAspectRatio?)
    func setVideoScaling(_ scaling: VideoScaling)
    func cycleVideoAspectRatio()
    func cycleVideoScaling()
    func stepVideoZoom(by steps: Int)
    func resetVideoZoom()
    /// Saves the frame on screen as an image, as the render mode shows it.
    func captureFrame()

    // Subtitles
    /// Whether media is loaded, which subtitles are of.
    var isMediaLoaded: Bool { get }
    var subtitleTracks: [SubtitleTrack] { get }
    var selectedSubtitleTrackId: Int? { get }
    var selectedSecondarySubtitleTrackId: Int? { get }
    /// The tracks that can be shown second.
    var secondarySubtitleCandidates: [SubtitleTrack] { get }
    var subtitleDelay: Double { get }
    /// The encoding chosen for the main track's file; `nil` is the default. Not for a track of the media itself.
    var subtitleEncoding: String.Encoding? { get }
    var canSetSubtitleEncoding: Bool { get }
    var secondarySubtitleEncoding: String.Encoding? { get }
    var canSetSecondarySubtitleEncoding: Bool { get }
    func selectSubtitleTrack(_ id: Int?)
    func selectSecondarySubtitleTrack(_ id: Int?)
    /// Asks for a subtitle file and adds it to the media.
    func loadSubtitleFile()
    /// Asks for a subtitle file and shows it as the second track.
    func loadSecondarySubtitleFile()
    var secondarySubtitleDelay: Double { get }
    func stepSecondarySubtitleDelay(by delta: Double)
    func resetSecondarySubtitleDelay()
    func setSubtitleEncoding(_ encoding: String.Encoding?)
    func setSecondarySubtitleEncoding(_ encoding: String.Encoding?)
}

extension PlayerActions {
    public func beginScrubbing() {}
    public func endScrubbing() {}
    public var playbackRate: Double {
        get { 1.0 }
        set {}
    }
    public var menuState: PlayerMenuState { PlayerMenuState(self) }
    public var canJumpToTime: Bool { true }
    public var isJumpToPresented: Bool { false }
    public var isQuickSettingsPresented: Bool { false }
    public var isPlaylistPresented: Bool { false }
    public var isPlaylistAvailable: Bool { true }
    public var isSidePanelPresented: Bool { false }
    public var hasNextTrack: Bool { false }
    public var hasPreviousTrack: Bool { false }
    public var hasChapters: Bool { false }
    public var isChaptersPresented: Bool { false }
    public var isActionButtonVisible: Bool { false }
    public var hasVideo: Bool { false }
    public var videoGeometry: VideoGeometrySettings { VideoGeometrySettings() }
    public func setVideoAspectRatio(_ ratio: RationalAspectRatio?) {}
    public func setVideoCrop(_ ratio: RationalAspectRatio?) {}
    public func setVideoScaling(_ scaling: VideoScaling) {}
    public func cycleVideoAspectRatio() {}
    public func cycleVideoScaling() {}
    public func stepVideoZoom(by steps: Int) {}
    public func resetVideoZoom() {}
    public func captureFrame() {}
    public func pressActionButton() {}
    public func dismissActionButton() {}
    public func seekForward() {
        seekRelative(by: seekStepSeconds)
    }
    public func seekBackward() {
        seekRelative(by: -seekStepSeconds)
    }
    public var isFullscreen: Bool { false }
    public var supportsFullscreen: Bool { true }
    public var isPictureInPictureActive: Bool { false }
    public var canTogglePictureInPicture: Bool { false }
    public func togglePictureInPicture() {}
    public func promptJumpToTime() {}
    public func dismissJumpToTime() {}
    public func toggleQuickSettings() {}
    public func togglePlaylist() {}
    public func closeSidePanel() {}
    public func playNextTrack() {}
    public func playPreviousTrack() {}
    public func toggleChapters() {}
    public func nextChapter() {}
    public func previousChapter() {}
    public func play() {}
    public func pause() {}
    public func seek(to seconds: Double) {}
    public func setPlaybackRate(_ rate: Double) {}
    public func stepPlaybackRate(by delta: Double) {}
    public func resetPlaybackRate() {}
    public func stepSubtitleDelay(by delta: Double) {}
    public func resetSubtitleDelay() {}
    public var isMediaLoaded: Bool { false }
    public var subtitleTracks: [SubtitleTrack] { [] }
    public var selectedSubtitleTrackId: Int? { nil }
    public var selectedSecondarySubtitleTrackId: Int? { nil }
    public var secondarySubtitleCandidates: [SubtitleTrack] { [] }
    public var subtitleDelay: Double { 0 }
    public var subtitleEncoding: String.Encoding? { nil }
    public var canSetSubtitleEncoding: Bool { false }
    public var secondarySubtitleEncoding: String.Encoding? { nil }
    public var canSetSecondarySubtitleEncoding: Bool { false }
    public func selectSubtitleTrack(_ id: Int?) {}
    public func selectSecondarySubtitleTrack(_ id: Int?) {}
    public func loadSubtitleFile() {}
    public func loadSecondarySubtitleFile() {}
    public var secondarySubtitleDelay: Double { 0 }
    public func stepSecondarySubtitleDelay(by delta: Double) {}
    public func resetSecondarySubtitleDelay() {}
    public func setSubtitleEncoding(_ encoding: String.Encoding?) {}
    public func setSecondarySubtitleEncoding(_ encoding: String.Encoding?) {}
    public func stepAudioDelay(by delta: Double) {}
}

public struct PlayerActionsKey: FocusedValueKey {
    public typealias Value = any PlayerActions
}

extension FocusedValues {
    public var playerActions: (any PlayerActions)? {
        get { self[PlayerActionsKey.self] }
        set { self[PlayerActionsKey.self] = newValue }
    }
}
