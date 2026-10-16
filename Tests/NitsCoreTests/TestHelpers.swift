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
