import SwiftUI

struct QuickSettingsPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    let valueLabel: String
    @Binding var selection: SelectionValue
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        valueLabel: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.valueLabel = valueLabel
        self._selection = selection
        self.content = content
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                content()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(valueLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .quickSettingsFieldBackground()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(valueLabel)
    }
}

extension View {
    /// The rounded, lightly filled background shared by the pane's pickers and text fields.
    func quickSettingsFieldBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
    }
}
