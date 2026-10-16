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
    var isSidePanelPresented: Bool { get }
    var hasNextTrack: Bool { get }
    var hasPreviousTrack: Bool { get }
    var hasChapters: Bool { get }
    var isChaptersPresented: Bool { get }

    var seekStepSeconds: Double { get }

    func togglePlayPause()
    func play()
    func pause()
    func seek(to seconds: Double)
    func stepFrameForward()
    func stepFrameBackward()
    func seekRelative(by seconds: Double)
    func seekForward()
    func seekBackward()
    func stepVolume(by delta: Float)
    func toggleMute()
    func setPlaybackRate(_ rate: Double)
    func stepPlaybackRate(by delta: Double)
    func resetPlaybackRate()
    func stepSubtitleDelay(by delta: Double)
    func toggleDebugHUD()
    func toggleQuickSettings()
    func togglePlaylist()
    func closeSidePanel()
    func playNextTrack()
    func playPreviousTrack()
    func toggleChapters()
    func nextChapter()
    func previousChapter()
    func toggleFullscreen()
    func exitFullscreen()
    var isPictureInPictureActive: Bool { get }
    var canTogglePictureInPicture: Bool { get }
    func togglePictureInPicture()
    func promptJumpToTime()
    func dismissJumpToTime()
}

extension PlayerActions {
    public var playbackRate: Double {
        get { 1.0 }
        set {}
    }
    public var canJumpToTime: Bool { true }
    public var isJumpToPresented: Bool { false }
    public var isQuickSettingsPresented: Bool { false }
    public var isPlaylistPresented: Bool { false }
    public var isSidePanelPresented: Bool { false }
    public var hasNextTrack: Bool { false }
    public var hasPreviousTrack: Bool { false }
    public var hasChapters: Bool { false }
    public var isChaptersPresented: Bool { false }
    public func seekForward() {
        seekRelative(by: seekStepSeconds)
    }
    public func seekBackward() {
        seekRelative(by: -seekStepSeconds)
    }
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
