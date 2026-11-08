import Testing

@testable import NitsUI

@Suite("Compact player UI state")
@MainActor
struct CompactPlayerUITests {
    private func makeState() -> PlayerUIState {
        let config = ControlsConfiguration(userDefaults: nil)
        config.items = [.playPause, .timeline, .chapters, .playlist, .quickSettings]
        return PlayerUIState(controlsConfig: config)
    }

    @Test("Becoming compact closes an open side panel")
    func compactClosesSidePanel() {
        let state = makeState()
        state.toggleQuickSettings()
        #expect(state.sidePanel == .quickSettings)

        state.isCompact = true
        #expect(state.sidePanel == nil)
    }

    @Test("While compact, side panels and Jump to Time don't open")
    func compactKeepsPanelsClosed() {
        let state = makeState()
        state.isCompact = true

        state.toggleQuickSettings()
        state.togglePlaylist()
        state.toggleChapters()
        state.toggleSidePanel(.playlist)
        #expect(state.sidePanel == nil)

        state.showJumpTo(wasPlaying: true)
        #expect(!state.isJumpToPresented)
        #expect(!state.wasPlayingBeforeJumpTo)
    }

    @Test("Leaving compact lets panels open again")
    func leavingCompactRestoresPanels() {
        let state = makeState()
        state.isCompact = true
        state.isCompact = false

        state.togglePlaylist()
        #expect(state.sidePanel == .playlist)
    }
}

@Suite("Compact player and Jump to Time")
@MainActor
struct CompactJumpToTests {
    @Test("Becoming compact closes Jump to Time and keeps what to resume")
    func compactClosesJumpTo() {
        let state = PlayerUIState(controlsConfig: ControlsConfiguration(userDefaults: nil))
        state.showJumpTo(wasPlaying: true)
        #expect(state.isJumpToPresented)

        state.isCompact = true
        #expect(!state.isJumpToPresented)
        #expect(state.wasPlayingBeforeJumpTo, "ContentView resumes the playback the dialog paused")
    }

    @Test("While compact, toggling Jump to Time reports it not presented")
    func compactToggleReportsNotPresented() {
        let state = PlayerUIState(controlsConfig: ControlsConfiguration(userDefaults: nil))
        state.isCompact = true
        let result = state.toggleJumpTo(isPlaying: true)
        #expect(!result.presented)
        #expect(!state.isJumpToPresented)
    }
}
