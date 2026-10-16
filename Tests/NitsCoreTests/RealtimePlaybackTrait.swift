import Testing

/// Runs tests that play media in real time one at a time, across suites; everything else stays parallel.
///
/// These tests assert on clock and display-link timing (dropped frames, clock continuity, seek landings while
/// playing). Run alongside each other they share the main actor, the audio device and the decoders, so a slow CI
/// runner turns ordinary scheduling delays into failures. `.serialized` only orders the tests within one suite.
///
/// Apply it to a suite (it is recursive) or to single tests; nesting both is fine.
struct RealtimePlaybackTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    /// Scopes each test case, not the suite or the test function around them, so a parameterized test lets other
    /// suites run between its cases.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        if Self.isHoldingGate {
            try await function()
            return
        }
        await Self.gate.acquire()
        do {
            try await Self.$isHoldingGate.withValue(true) { try await function() }
        } catch {
            await Self.gate.release()
            throw error
        }
        await Self.gate.release()
    }

    @TaskLocal private static var isHoldingGate = false
    private static let gate = AsyncGate()
}

extension Trait where Self == RealtimePlaybackTrait {
    /// See `RealtimePlaybackTrait`.
    static var realtimePlayback: Self { Self() }
}

/// A FIFO mutex for async code: `acquire()` suspends instead of blocking a thread.
private actor AsyncGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            // Ownership passes straight to the next waiter; the gate stays locked.
            waiters.removeFirst().resume()
        }
    }
}
