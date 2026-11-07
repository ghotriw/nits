import Foundation
import Testing

/// Lets only a few tests that read from a `TestHTTPServer` run at a time, across suites; everything else stays parallel.
///
/// Such a test opens and reads a network demuxer synchronously, holding a thread of the cooperative pool while the
/// server answers. `.serialized` orders the tests within one suite only: the HTTP, HLS and DASH suites ran side by side
/// until every thread of the pool (12 on a 12-core machine) was held by one, and the async tests of the run (waiting
/// on the clock, the main actor, a task) had none to go on with, failing by their timeouts some 16 s in. The wait for a
/// turn is an `await`, which holds no thread.
///
/// Apply it to a suite (it is recursive) or to single tests. A real-time test (`.realtimePlayback`) skips it: those run
/// one at a time already, and holding a turn of each while waiting for the other could hold both forever.
struct NetworkServerTrait: SuiteTrait, TestTrait, TestScoping {
    /// How many such tests run at once: a third of the pool, at least one (a CI runner's three cores give one).
    static let concurrentTests = max(1, ProcessInfo.processInfo.activeProcessorCount / 3)
    var isRecursive: Bool { true }

    /// Scopes each test case, so a parameterized test lets other suites run between its cases.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil || test.traits.contains { $0 is RealtimePlaybackTrait } ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        if Self.isHoldingTurn {
            try await function()
            return
        }
        await Self.turns.acquire()
        do {
            try await Self.$isHoldingTurn.withValue(true) { try await function() }
        } catch {
            await Self.turns.release()
            throw error
        }
        await Self.turns.release()
    }

    @TaskLocal private static var isHoldingTurn = false
    private static let turns = AsyncSemaphore(count: concurrentTests)
}

extension Trait where Self == NetworkServerTrait {
    /// See `NetworkServerTrait`.
    static var networkServer: Self { Self() }
}

/// A FIFO counting semaphore for async code: `acquire()` suspends instead of blocking a thread.
private actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        available = count
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            // The turn passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}
