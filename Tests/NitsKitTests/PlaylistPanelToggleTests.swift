import Testing

@testable import NitsUI

@Suite("Playlist panel entry points")
@MainActor
struct PlaylistPanelToggleTests {
    private func makeState(bar items: [ControlBarItem]) -> PlayerUIState {
        let config = ControlsConfiguration(userDefaults: nil)
        config.items = items
        return PlayerUIState(controlsConfig: config)
    }

    @Test("With both tab buttons on the bar, each opens and closes its own tab")
    func bothButtonsAreTabSpecific() {
        let state = makeState(bar: [.playPause, .timeline, .chapters, .playlist])

        state.toggleChapters()
        #expect(state.sidePanel == .chapters)
        state.toggleChapters()
        #expect(state.sidePanel == nil)

        // The chapters tab shown last does not change what the playlist button opens.
        state.togglePlaylist()
        #expect(state.sidePanel == .playlist)
        #expect(state.isPlaylistPresented && !state.isChaptersPresented)
        // From the playlist tab the chapters button switches tabs instead of closing.
        state.toggleChapters()
        #expect(state.sidePanel == .chapters)
    }

    @Test("Without a chapters button, the playlist button reopens the tab shown last and closes either")
    func playlistButtonStandsForThePanel() {
        let state = makeState(bar: [.playPause, .timeline, .playlist])

        state.togglePlaylist()
        #expect(state.sidePanel == .playlist)
        // Switching tabs inside the panel.
        state.sidePanel = .chapters
        #expect(state.isPlaylistPresented, "The playlist button stays active on the chapters tab")
        state.togglePlaylist()
        #expect(state.sidePanel == nil, "The playlist button closes the panel on either tab")

        state.togglePlaylist()
        #expect(state.sidePanel == .chapters, "The playlist button reopens the tab shown last")

        // `C` / the View menu still open chapters explicitly, from the playlist tab too.
        state.sidePanel = .playlist
        state.toggleChapters()
        #expect(state.sidePanel == .chapters)
    }

    @Test("Without a playlist button, the chapters button stands for the panel")
    func chaptersButtonStandsForThePanel() {
        let state = makeState(bar: [.playPause, .timeline, .chapters])

        state.toggleChapters()
        #expect(state.sidePanel == .playlist, "Nothing shown yet this session: the panel opens on its first tab")
        state.toggleChapters()
        #expect(state.sidePanel == nil)
    }

    @Test("Quick settings in between keep the playlist panel's last tab")
    func quickSettingsDoNotResetTheTab() {
        let state = makeState(bar: [.playPause, .timeline, .playlist, .quickSettings])

        state.togglePlaylist()
        state.sidePanel = .chapters
        state.toggleQuickSettings()
        #expect(state.sidePanel == .quickSettings)
        state.togglePlaylist()
        #expect(state.sidePanel == .chapters)
    }
}
