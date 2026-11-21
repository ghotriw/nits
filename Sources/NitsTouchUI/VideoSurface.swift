#if os(iOS)
    import NitsCore
    import SwiftUI

    /// The engine's picture: a bare `UIKitVideoHostView`, with the controls and gestures drawn over it by `PlayerScreen`.
    struct VideoSurface: UIViewRepresentable {
        let engine: PlayerEngine

        func makeUIView(context: Context) -> UIKitVideoHostView {
            UIKitVideoHostView(engine: engine)
        }

        func updateUIView(_ view: UIKitVideoHostView, context: Context) {
            // Read here so that a change of fit, fill or zoom updates the view.
            _ = engine.videoGeometry
            view.updateMode()
        }
    }
#endif
