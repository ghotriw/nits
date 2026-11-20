#if os(iOS)
    import UIKit

    /// The main screen, for a display link before any `VideoHost` is attached. A stub until the iOS platform layer task.
    @MainActor
    enum PlatformScreen {
        static func makeMainDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
            nil
        }

        static var mainMaximumFramesPerSecond: Int? {
            nil
        }
    }
#endif
