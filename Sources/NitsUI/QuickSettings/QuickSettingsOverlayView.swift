import NitsCore
import SwiftUI

public struct QuickSettingsOverlayView: View {
    public let engine: PlayerEngine
    @Bindable public var uiState: PlayerUIState
    public var onClose: () -> Void

    public init(engine: PlayerEngine, uiState: PlayerUIState, onClose: @escaping () -> Void) {
        self.engine = engine
        self.uiState = uiState
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            SidePanelTabBar(
                tabs: QuickSettingsTab.allCases.map { SidePanelTab(id: $0, title: $0.title, iconName: $0.iconName) },
                selection: uiState.selectedQuickSettingsTab,
                onSelect: { uiState.selectedQuickSettingsTab = $0 },
                onClose: onClose
            )

            Divider()
                .overlay(Color.white.opacity(0.1))

            // Body: Scrollable Tab Content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    switch uiState.selectedQuickSettingsTab {
                    case .video:
                        QuickVideoPane(engine: engine)
                    case .audio:
                        QuickAudioPane(engine: engine)
                    case .subtitles:
                        QuickSubtitlesPane(engine: engine)
                    case .info:
                        QuickMediaInfoPane(engine: engine)
                    }
                }
                .padding(16)
            }
        }
    }
}
