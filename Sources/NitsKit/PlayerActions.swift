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

    func togglePlayPause()
    func play()
    func pause()
    func seek(to seconds: Double)
    func stepFrameForward()
    func stepFrameBackward()
    func seekRelative(by seconds: Double)
    func stepVolume(by delta: Float)
    func toggleMute()
    func setPlaybackRate(_ rate: Double)
    func stepPlaybackRate(by delta: Double)
    func resetPlaybackRate()
    func toggleDebugHUD()
    func toggleQuickSettings()
    func toggleFullscreen()
    func exitFullscreen()
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
    public func promptJumpToTime() {}
    public func dismissJumpToTime() {}
    public func toggleQuickSettings() {}
    public func play() {}
    public func pause() {}
    public func seek(to seconds: Double) {}
    public func setPlaybackRate(_ rate: Double) {}
    public func stepPlaybackRate(by delta: Double) {}
    public func resetPlaybackRate() {}
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
