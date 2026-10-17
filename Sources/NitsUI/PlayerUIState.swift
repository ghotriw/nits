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
    public var sidePanel: PlayerSidePanel? {
        didSet {
            if let sidePanel, sidePanel.isPlaylistPanelTab {
                lastPlaylistPanelTab = sidePanel
            }
        }
    }
    /// The playlist panel's tab last shown this session; see `togglePlaylist()`.
    public private(set) var lastPlaylistPanelTab: PlayerSidePanel = .playlist
    /// Picture in Picture can start now (reported by the host that owns PiP).
    public var isPictureInPicturePossible: Bool = false
    /// Starts or stops Picture in Picture; set by the host that owns it, `nil` hides the control.
    @ObservationIgnored public var togglePictureInPicture: (() -> Void)?
    public var selectedQuickSettingsTab: QuickSettingsTab = .video
    public let osd: OSDManager
    public let controlsConfig: ControlsConfiguration
    public let actionButton: ActionButtonPresenter

    public init(
        isFullscreen: Bool = false,
        osd: OSDManager = OSDManager(),
        controlsConfig: ControlsConfiguration = ControlsConfiguration.shared,
        actionButton: ActionButtonPresenter = ActionButtonPresenter()
    ) {
        self.isFullscreen = isFullscreen
        self.osd = osd
        self.controlsConfig = controlsConfig
        self.actionButton = actionButton
    }

    public var isQuickSettingsPresented: Bool { sidePanel == .quickSettings }

    /// Whether the playlist entry point (control bar button, `P`, View menu) shows as active: its tab is open, or
    /// either tab while it stands for the whole panel.
    public var isPlaylistPresented: Bool {
        opensWholePlaylistPanel(.playlist) ? sidePanel?.isPlaylistPanelTab == true : sidePanel == .playlist
    }

    /// Whether the chapters entry point shows as active; see `isPlaylistPresented`.
    public var isChaptersPresented: Bool {
        opensWholePlaylistPanel(.chapters) ? sidePanel?.isPlaylistPanelTab == true : sidePanel == .chapters
    }

    /// Opens `panel`, replacing any other open panel (or switching the playlist panel's tab), or
    /// closes it if it is already open.
    public func toggleSidePanel(_ panel: PlayerSidePanel) {
        sidePanel = sidePanel == panel ? nil : panel
    }

    public func toggleQuickSettings() {
        toggleSidePanel(.quickSettings)
    }

    /// Toggles the playlist panel from its playlist entry point (control bar button, `P`, View menu).
    ///
    /// With both tab buttons on the control bar each opens its own tab. When the other tab's button isn't there,
    /// this one stands for the whole panel, like the quick settings button: it reopens the tab last shown this
    /// session and closes the panel on either tab.
    public func togglePlaylist() {
        togglePlaylistPanel(from: .playlist)
    }

    /// Toggles the playlist panel from its chapters entry point; see `togglePlaylist()`.
    public func toggleChapters() {
        togglePlaylistPanel(from: .chapters)
    }

    private func togglePlaylistPanel(from tab: PlayerSidePanel) {
        guard opensWholePlaylistPanel(tab) else {
            toggleSidePanel(tab)
            return
        }
        sidePanel = sidePanel?.isPlaylistPanelTab == true ? nil : lastPlaylistPanelTab
    }

    /// Whether `tab`'s entry point stands for the whole playlist panel: the other tab has no control bar button.
    private func opensWholePlaylistPanel(_ tab: PlayerSidePanel) -> Bool {
        let otherTabButton: ControlBarItem = tab == .chapters ? .playlist : .chapters
        return !controlsConfig.isEnabled(otherTabButton)
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
