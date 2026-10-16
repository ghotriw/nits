import Foundation
import os

/// Lightweight thread-safe box for unit tests and testing callbacks.
/// Conforms to Sendable and uses Apple's native OSAllocatedUnfairLock (per AGENTS.md Section 3.4).
final class LockIsolated<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        self.lock = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Value {
        lock.withLock { $0 }
    }

    func withValue<R: Sendable>(_ body: @Sendable (inout Value) -> R) -> R {
        lock.withLock { body(&$0) }
    }
}

/// `UserDefaults` that lives only in memory, so stores built on it neither persist between test runs nor leave
/// preference files behind (a named suite writes `~/Library/Preferences/<suite>.plist`).
final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<[String: Any]>(uncheckedState: [:])

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        storage.withLockUnchecked { $0[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage.withLockUnchecked { $0[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        storage.withLockUnchecked { $0[defaultName] = nil }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        storage.withLockUnchecked { $0 }
    }
}
