import Foundation
import NitsCore
import os

/// How long the wait helpers give a condition by default. They return as soon as it holds, so this only bounds a
/// failing test; it is generous because CI runners are several times slower than a dev machine.
public let testWaitTimeout: Duration = .seconds(10)

/// Polls `condition` until it holds or `timeout` expires; returns its final value.
@MainActor
public func waitUntil(timeout: Duration = testWaitTimeout, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// `UserDefaults` that lives only in memory, so stores built on it neither persist between test runs nor leave
/// preference files behind (a named suite writes `~/Library/Preferences/<suite>.plist`).
public final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<[String: Any]>(uncheckedState: [:])

    public init() {
        super.init(suiteName: nil)!
    }

    public override func object(forKey defaultName: String) -> Any? {
        storage.withLockUnchecked { $0[defaultName] }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        storage.withLockUnchecked { $0[defaultName] = value }
    }

    public override func removeObject(forKey defaultName: String) {
        storage.withLockUnchecked { $0[defaultName] = nil }
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        storage.withLockUnchecked { $0 }
    }
}

extension PlayerEngine {
    /// Engine for tests, with silent audio output, in-memory stores and no folder playlist.
    ///
    /// Only the renderer is silenced, so the engine's `volume` / `isMuted` stay as configured and tests can assert
    /// on them. The audio device still runs, so the synchronizer clock behaves as in real playback. With the shared
    /// defaults, a test would resume wherever another test (or an earlier run) left the same synthetic file, and the
    /// shared duration cache is the app's own. A folder playlist would make every load probe the durations of all
    /// synthetic media next to it, and reaching the end would load the next one.
    @MainActor
    public static func makeForTesting(
        configuration: PlayerConfiguration = PlayerConfiguration(),
        userDefaults: UserDefaults = InMemoryUserDefaults()
    ) -> PlayerEngine {
        var configuration = configuration
        configuration.autoLoadFolderMedia = false
        let engine = PlayerEngine(
            configuration: configuration, userDefaults: userDefaults,
            durationCache: MediaDurationCache(fileURL: nil))
        engine.audioRenderer.volume = 0
        return engine
    }

    /// See the free `testWaitTimeout`.
    public nonisolated static let testWaitTimeout: Duration = NitsTestSupport.testWaitTimeout
}
