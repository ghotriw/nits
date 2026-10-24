#if os(macOS)
    import AppKit

    /// The main screen, for a display link before any `VideoHost` is attached.
    @MainActor
    enum PlatformScreen {
        static func makeMainDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
            NSScreen.main?.displayLink(target: target, selector: selector)
        }

        static var mainMaximumFramesPerSecond: Int? {
            NSScreen.main?.maximumFramesPerSecond
        }
    }
#endif
