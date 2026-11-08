import SwiftUI

/// The host's overlay buttons (`PlayerUIState.overlayButtons`) in their corners: the top trailing one and the bottom
/// leading one. They keep their place whether the controls are up or not, clear of the bars either way: one that moved
/// as the controls came up would slide from under the pointer that brought them up.
struct PlayerOverlayButtonsView: View {
    let uiState: PlayerUIState
    /// Whether the controls are on screen: `.withControls` buttons show only with them.
    var areControlsVisible: Bool
    /// Width taken by an open side panel; the top trailing buttons stay beside it.
    var trailingInset: CGFloat = 0
    /// Whether the pointer is over a button: the host keeps the controls up meanwhile, so a button doesn't go away
    /// from under it.
    @Binding var isHovered: Bool

    /// The buttons under the pointer, by `id`. A set rather than a flag: a button that goes away under the pointer
    /// reports no hover end, so the ones no longer shown are dropped from it.
    @State private var hoveredIDs: Set<String> = []

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
            corner(.topTrailing)
                // Below the windowed player's top bar (40 pt); fullscreen has none.
                .padding(.top, uiState.isFullscreen ? 28 : 52)
                .padding(.trailing, 28 + trailingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            corner(.bottomLeading)
                // Above the control bar, as the action button is while the bar is up.
                .padding(.bottom, 72)
                .padding(.leading, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .animation(.easeInOut(duration: 0.2), value: shown)
        .onChange(of: shown.map(\.id)) { _, ids in
            hoveredIDs.formIntersection(ids)
        }
        .onChange(of: hoveredIDs.isEmpty) { _, empty in
            isHovered = !empty
        }
        .onDisappear {
            hoveredIDs = []
            isHovered = false
        }
    }

    private var shown: [PlayerOverlayButton] {
        uiState.overlayButtons.filter { $0.visibility == .always || areControlsVisible }
    }

    private func corner(_ placement: PlayerOverlayButton.Placement) -> some View {
        HStack(spacing: 8) {
            ForEach(shown.filter { $0.placement == placement }) { button in
                overlayButton(button)
                    .onHover { hovering in
                        if hovering {
                            hoveredIDs.insert(button.id)
                        } else {
                            hoveredIDs.remove(button.id)
                        }
                    }
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func overlayButton(_ button: PlayerOverlayButton) -> some View {
        let action: @MainActor () -> Void = { uiState.onOverlayButton?(button.id) }
        let foreground = Color.white.opacity(button.isEnabled ? 0.9 : 0.4)
        if let systemImage = button.systemImage {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 36, height: 36)
                    .overlayButtonChrome(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!button.isEnabled)
            .help(button.title)
            .accessibilityLabel(button.title)
        } else {
            // The title is the label itself: no tooltip repeating it.
            Button(action: action) {
                Text(button.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .overlayButtonChrome(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!button.isEnabled)
        }
    }
}
