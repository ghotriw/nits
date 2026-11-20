#if os(iOS)
    import UIKit

    typealias PlatformDisplaySleepAssertion = IdleTimerDisplaySleepAssertion

    /// Keeps the screen on through `UIApplication.isIdleTimerDisabled` while any assertion lives: the timer is disabled
    /// by a count, so two players (or a player and a host) release it only when both are done.
    final class IdleTimerDisplaySleepAssertion: DisplaySleepAssertion {
        /// Assertions alive.
        private(set) static var heldCount = 0

        init?(reason: String) {
            Self.heldCount += 1
            Self.apply()
        }

        isolated deinit {
            Self.heldCount -= 1
            Self.apply()
        }

        private static func apply() {
            UIApplication.shared.isIdleTimerDisabled = heldCount > 0
        }
    }
#endif
