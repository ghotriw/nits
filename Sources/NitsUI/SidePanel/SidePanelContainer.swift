import SwiftUI

/// Trailing-edge chrome shared by every `PlayerSidePanel`: fixed width, full height, material
/// background with a leading hairline and shadow. Content supplies its own header.
///
/// Always dark, like the rest of the player HUD: content is drawn in light colours, and a
/// system-appearance material over bright video would turn light and wash it out.
struct SidePanelContainer<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.25))
            .background(.regularMaterial)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 24, x: -8, y: 0)
            .environment(\.colorScheme, .dark)
    }
}
