import os

/// The generation token of the engine's seeks and frame-step pumps. Each one, and every media reset, starts a new
/// generation on the main actor; work it queued on `seekQueue` checks it there and drops what a newer one superseded.
/// Behind a lock, so the `isSuperseded` closures that run off the main actor can capture it.
final class SeekGeneration: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    var current: Int { lock.withLock { $0 } }

    /// Starts a new generation, superseding the current one, and returns it.
    @discardableResult
    func advance() -> Int {
        lock.withLock {
            $0 += 1
            return $0
        }
    }

    func isCurrent(_ id: Int) -> Bool {
        lock.withLock { $0 == id }
    }
}
