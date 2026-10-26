import SwiftUI

struct QuickSettingsSection<Trailing: View, Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let spacing: CGFloat
    private let hasTrailing: Bool
    private let trailing: Trailing
    private let content: Content

    private init(
        title: String?,
        systemImage: String?,
        spacing: CGFloat,
        hasTrailing: Bool,
        trailing: Trailing,
        content: Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.spacing = spacing
        self.hasTrailing = hasTrailing
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        // One container, so the header stays closer to its card than to the previous section.
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || hasTrailing {
                HStack {
                    if let title {
                        if let systemImage {
                            Label(title, systemImage: systemImage)
                        } else {
                            Text(title)
                        }
                    }
                    Spacer()
                    trailing
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .accessibilityAddTraits(.isHeader)
            }

            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
    }
}

extension QuickSettingsSection {
    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        spacing: CGFloat = 8,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, systemImage: systemImage, spacing: spacing,
            hasTrailing: true, trailing: trailing(), content: content())
    }
}

extension QuickSettingsSection where Trailing == EmptyView {
    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        spacing: CGFloat = 8,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, systemImage: systemImage, spacing: spacing,
            hasTrailing: false, trailing: EmptyView(), content: content())
    }
}
