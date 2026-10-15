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
            // Header: Tabs + Close Button
            HStack(spacing: 0) {
                ForEach(QuickSettingsTab.allCases) { tab in
                    let isSelected = uiState.selectedQuickSettingsTab == tab
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            uiState.selectedQuickSettingsTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 13, weight: .semibold))

                            if isSelected {
                                Text(tab.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .transition(.opacity.combined(with: .move(edge: .leading)))
                            }
                        }
                        .frame(minWidth: 24, minHeight: 30)
                        .padding(.horizontal, isSelected ? 10 : 8)
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .padding(.horizontal, isSelected ? 4 : 0)
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(Color.black.opacity(0.2))

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
