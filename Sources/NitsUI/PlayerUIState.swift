import Foundation
import Observation

@Observable
@MainActor
public final class PlayerUIState {
    public var isFullscreen: Bool
    public var controlsVisibilityTrigger: Int = 0
    public var isJumpToPresented: Bool = false
    public var wasPlayingBeforeJumpTo: Bool = false
    public var isQuickSettingsPresented: Bool = false
    public var selectedQuickSettingsTab: QuickSettingsTab = .video
    public let osd: OSDManager

    public init(isFullscreen: Bool = false, osd: OSDManager = OSDManager()) {
        self.isFullscreen = isFullscreen
        self.osd = osd
    }

    public func toggleQuickSettings() {
        isQuickSettingsPresented.toggle()
    }

    public func showControlsTemporarily() {
        controlsVisibilityTrigger &+= 1
    }

    public func showJumpTo(wasPlaying: Bool) {
        wasPlayingBeforeJumpTo = wasPlaying
        isJumpToPresented = true
    }

    @discardableResult
    public func dismissJumpTo() -> Bool {
        isJumpToPresented = false
        let shouldResume = wasPlayingBeforeJumpTo
        wasPlayingBeforeJumpTo = false
        return shouldResume
    }

    public func toggleJumpTo(isPlaying: Bool) -> (presented: Bool, shouldResume: Bool) {
        if isJumpToPresented {
            let resume = dismissJumpTo()
            return (false, resume)
        } else {
            showJumpTo(wasPlaying: isPlaying)
            return (true, false)
        }
    }
}
