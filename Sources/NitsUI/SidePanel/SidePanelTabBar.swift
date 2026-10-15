import SwiftUI

/// One tab of a `SidePanelTabBar`.
struct SidePanelTab<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let iconName: String
    /// Short trailing label shown next to the title of the selected tab (e.g. an item count).
    var badge: String? = nil
    /// Shows a spinner in place of the badge.
    var isBusy: Bool = false
}

/// Header shared by the side panels: tabs on the leading edge (the selected one shows its title,
/// the others only their icon), optional accessory buttons, and the close button.
struct SidePanelTabBar<ID: Hashable, Accessory: View>: View {
    let tabs: [SidePanelTab<ID>]
    let selection: ID
    let onSelect: (ID) -> Void
    let onClose: () -> Void
    @ViewBuilder let accessory: Accessory

    init(
        tabs: [SidePanelTab<ID>],
        selection: ID,
        onSelect: @escaping (ID) -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.tabs = tabs
        self.selection = selection
        self.onSelect = onSelect
        self.onClose = onClose
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                accessory

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
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.2))
    }

    private func tabButton(_ tab: SidePanelTab<ID>) -> some View {
        let isSelected = tab.id == selection
        return Button {
            guard !isSelected else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                onSelect(tab.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 13, weight: .semibold))

                if isSelected {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .transition(.opacity.combined(with: .move(edge: .leading)))

                    if tab.isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    } else if let badge = tab.badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .transition(.opacity)
                    }
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
}
