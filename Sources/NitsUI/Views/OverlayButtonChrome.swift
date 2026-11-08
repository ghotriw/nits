import SwiftUI

extension View {
    /// The look of the player's buttons over the picture (the action button's dismiss, the host's overlay buttons):
    /// material in `shape`, a hairline edge and a soft shadow, the whole shape taking the clicks.
    func overlayButtonChrome<S: Shape>(_ shape: S) -> some View {
        background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            .contentShape(shape)
            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 0)
    }
}
