import Foundation
import Observation

@Observable
@MainActor
public final class PlayerUIState {
    public var isFullscreen: Bool
    public var controlsVisibilityTrigger: Int = 0
    public var isJumpToPresented: Bool = false
    public var wasPlayingBeforeJumpTo: Bool = false
    /// The side panel currently open, if any.
    public var sidePanel: PlayerSidePanel?
    /// Picture in Picture can start now (reported by the host that owns PiP).
    public var isPictureInPicturePossible: Bool = false
    /// Starts or stops Picture in Picture; set by the host that owns it, `nil` hides the control.
    @ObservationIgnored public var togglePictureInPicture: (() -> Void)?
    public var selectedQuickSettingsTab: QuickSettingsTab = .video
    public let osd: OSDManager
    public let controlsConfig: ControlsConfiguration

    public init(
        isFullscreen: Bool = false,
        osd: OSDManager = OSDManager(),
        controlsConfig: ControlsConfiguration = ControlsConfiguration.shared
    ) {
        self.isFullscreen = isFullscreen
        self.osd = osd
        self.controlsConfig = controlsConfig
    }

    public var isQuickSettingsPresented: Bool { sidePanel == .quickSettings }

    public var isPlaylistPresented: Bool { sidePanel == .playlist }

    public var isChaptersPresented: Bool { sidePanel == .chapters }

    /// Opens `panel`, replacing any other open panel (or switching the playlist panel's tab), or
    /// closes it if it is already open.
    public func toggleSidePanel(_ panel: PlayerSidePanel) {
        sidePanel = sidePanel == panel ? nil : panel
    }

    public func toggleQuickSettings() {
        toggleSidePanel(.quickSettings)
    }

    public func togglePlaylist() {
        toggleSidePanel(.playlist)
    }

    public func toggleChapters() {
        toggleSidePanel(.chapters)
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
