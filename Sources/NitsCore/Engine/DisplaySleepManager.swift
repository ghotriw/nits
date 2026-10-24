import Foundation

/// Prevents the display from dimming/sleeping and screen saver from activating
/// while video playback is actively in progress.
@MainActor
public final class DisplaySleepManager {
    /// Held while sleep is disabled; dropping it lets the display sleep again.
    private var assertion: PlatformDisplaySleepAssertion?
    private let reason: String

    public init(reason: String = "Nits Video Playback") {
        self.reason = reason
    }

    /// Whether display sleep and screen saver are currently disabled.
    public var isSleepDisabled: Bool {
        assertion != nil
    }

    /// Disables display sleep and screen saver if not already disabled.
    public func disableDisplaySleep() {
        guard assertion == nil else { return }
        assertion = PlatformDisplaySleepAssertion(reason: reason)
    }

    /// Enables display sleep and screen saver if currently disabled.
    public func enableDisplaySleep() {
        assertion = nil
    }

    /// Updates display sleep state based on active video playback.
    /// Display sleep is only prevented when actively playing video.
    /// For audio-only playback, display sleep is permitted to preserve power.
    public func update(isPlaying: Bool, hasVideo: Bool) {
        if isPlaying && hasVideo {
            disableDisplaySleep()
        } else {
            enableDisplaySleep()
        }
    }
}
