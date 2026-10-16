import AVFoundation
import Foundation

@testable import NitsCore

extension PlayerEngine {
    /// Engine for tests, with silent audio output and its own in-memory defaults.
    ///
    /// Only the renderer is silenced, so the engine's `volume` / `isMuted` stay as configured and tests can assert
    /// on them. The audio device still runs, so the synchronizer clock behaves as in real playback. With the shared
    /// defaults, a test would resume wherever another test (or an earlier run) left the same synthetic file.
    @MainActor
    static func makeForTesting(
        configuration: PlayerConfiguration = PlayerConfiguration(),
        userDefaults: UserDefaults = InMemoryUserDefaults()
    ) -> PlayerEngine {
        let engine = PlayerEngine(configuration: configuration, userDefaults: userDefaults)
        engine.audioRenderer.volume = 0
        return engine
    }

    /// Waits until the master clock passes `seconds`.
    ///
    /// After `play()` the synchronizer holds the clock until the audio device is running. A device that was idle
    /// (notably a Bluetooth route such as AirPods) takes several hundred milliseconds to start, so tests must not
    /// assume the clock moves a fixed time after `play()`.
    @MainActor
    func waitForClock(toPass seconds: Double, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if synchronizer.currentTime().seconds > seconds { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return synchronizer.currentTime().seconds > seconds
    }

    /// Polls `condition` until it holds or `timeout` expires; returns its final value.
    @MainActor
    func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
