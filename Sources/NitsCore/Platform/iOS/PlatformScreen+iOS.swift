#if os(iOS)
    import UIKit

    /// The main screen, for a display link before any `VideoHost` is attached: the screen of the first window scene in
    /// the foreground (`UIScreen.main` is deprecated), else of any connected one.
    @MainActor
    enum PlatformScreen {
        private static var screen: UIScreen? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
        }

        static func makeMainDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
            screen?.displayLink(withTarget: target, selector: selector)
        }

        static var mainMaximumFramesPerSecond: Int? {
            screen?.maximumFramesPerSecond
        }
    }
#endif
