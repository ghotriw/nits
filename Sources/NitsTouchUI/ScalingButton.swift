#if os(iOS)
    import NitsCore
    import SwiftUI

    /// Fit or fill: the picture inside the screen, or covering it with its edges cut (what the pinch does too).
    struct ScalingButton: View {
        let engine: PlayerEngine
        var onInteraction: () -> Void = {}

        var body: some View {
            let isFit = engine.videoGeometry.scaling == .fit
            Button {
                engine.setVideoScaling(isFit ? .fill : .fit)
                onInteraction()
            } label: {
                Image(systemName: isFit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isFit ? "Fill screen" : "Fit to screen")
        }
    }
#endif
