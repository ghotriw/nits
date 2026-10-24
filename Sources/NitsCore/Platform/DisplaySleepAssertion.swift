/// Keeps the display awake and the screen saver off for as long as it lives; deinit releases it.
///
/// Each platform provides one in `Platform/<os>/` as `PlatformDisplaySleepAssertion`.
@MainActor
protocol DisplaySleepAssertion: AnyObject {
    /// `nil` when the system refuses the assertion.
    init?(reason: String)
}
