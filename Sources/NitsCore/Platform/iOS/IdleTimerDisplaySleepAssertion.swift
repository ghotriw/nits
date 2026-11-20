#if os(iOS)
    import Foundation

    typealias PlatformDisplaySleepAssertion = IdleTimerDisplaySleepAssertion

    /// Keeps the screen on through `UIApplication.isIdleTimerDisabled`. A compiling stub until the iOS platform layer task.
    final class IdleTimerDisplaySleepAssertion: DisplaySleepAssertion {
        init?(reason: String) {}
    }
#endif
