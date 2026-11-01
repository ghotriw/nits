import Testing

/// Runs tests that play media in real time one at a time, across suites; everything else stays parallel.
///
/// These tests assert on clock and display-link timing (dropped frames, clock continuity, seek landings while
/// playing). Run alongside each other they share the main actor, the audio device and the decoders, so a slow CI
/// runner turns ordinary scheduling delays into failures. `.serialized` only orders the tests within one suite.
///
/// Apply it to a suite (it is recursive) or to single tests; nesting both is fine. It implies `.hostDependent`.
///
/// A test gets `playTimeLimit` from the moment its turn comes, not from its start: a `.timeLimit` counts the wait for
/// the tests ahead of it too, and once the real-time tests of a full run added up to about a minute, the last in line
/// failed by the limit while playing a few seconds each (another one, whichever came last, every time a test was
/// added). Suites with this trait give `.timeLimit` only as a backstop for the whole queue (`backstopTimeLimit`).
struct RealtimePlaybackTrait: SuiteTrait, TestTrait, TestScoping {
    /// How long a test may play once its turn has come.
    static let playTimeLimit: Duration = .seconds(60)
    var isRecursive: Bool { true }

    /// Scopes each test case, not the suite or the test function around them, so a parameterized test lets other
    /// suites run between its cases.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        // Real-time playback is host-dependent by definition; see `HostDependentTrait`.
        try HostDependentTrait.cancelIfSkipped()
        if Self.isHoldingGate {
            try await function()
            return
        }
        await Self.gate.acquire()
        do {
            try await Self.$isHoldingGate.withValue(true) { try await Self.withPlayTimeLimit(function) }
        } catch {
            await Self.gate.release()
            throw error
        }
        await Self.gate.release()
    }

    /// Runs `function`, cancelling it and recording an issue if it takes longer than `playTimeLimit`, as `.timeLimit`
    /// does (a test that ignores cancellation is left to the suite's backstop).
    private static func withPlayTimeLimit(_ function: @Sendable () async throws -> Void) async throws {
        // The group awaits both tasks before it returns, so `function` does not outlive the call.
        let isWithinLimit = try await withoutActuallyEscaping(function) { function in
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await function()
                    return true
                }
                group.addTask {
                    try await Task.sleep(for: playTimeLimit)
                    return false
                }
                defer { group.cancelAll() }
                return try await group.next() ?? true
            }
        }
        if !isWithinLimit {
            Issue.record(
                "Time limit was exceeded: \(playTimeLimit) of playing, the wait for the other real-time tests not counted"
            )
        }
    }

    @TaskLocal private static var isHoldingGate = false
    private static let gate = AsyncGate()
}

extension Trait where Self == RealtimePlaybackTrait {
    /// See `RealtimePlaybackTrait`.
    static var realtimePlayback: Self { Self() }
}

extension Trait where Self == TimeLimitTrait {
    /// A suite of real-time tests' `.timeLimit`: room for the whole queue of them, should it hang. Each test's own limit
    /// is `RealtimePlaybackTrait.playTimeLimit`, from its turn.
    static var backstopTimeLimit: Self { .timeLimit(.minutes(10)) }
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
