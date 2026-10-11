import Foundation
import NitsCore
import SwiftUI

@MainActor
public protocol PlayerActions: AnyObject {
    var renderMode: RenderMode { get set }
    var metalSharpness: Float { get set }
    var isMuted: Bool { get }
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
    func toggleDebugHUD()
    func toggleQuickSettings()
    func toggleFullscreen()
    func exitFullscreen()
    func promptJumpToTime()
    func dismissJumpToTime()
}

extension PlayerActions {
    public var canJumpToTime: Bool { true }
    public var isJumpToPresented: Bool { false }
    public var isQuickSettingsPresented: Bool { false }
    public func promptJumpToTime() {}
    public func dismissJumpToTime() {}
    public func toggleQuickSettings() {}
    public func play() {}
    public func pause() {}
    public func seek(to seconds: Double) {}
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
