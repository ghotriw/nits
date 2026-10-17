import Foundation
import Testing

/// Marks tests whose result depends on the machine: hardware decoders, the audio renderer, Metal, or how quickly
/// async work gets scheduled. `.realtimePlayback` implies it.
///
/// With `NITS_SKIP_HOST_DEPENDENT_TESTS` set they are skipped. CI sets it for the step that gates the build:
/// a virtualised runner may lack a decoder profile or stall for seconds, so these run in a separate step that only
/// reports. Run them locally before pushing.
///
/// Apply it to a suite (it is recursive) or to single tests.
struct HostDependentTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try Self.cancelIfSkipped()
        try await function()
    }

    static func cancelIfSkipped() throws {
        if ProcessInfo.processInfo.environment["NITS_SKIP_HOST_DEPENDENT_TESTS"] != nil {
            try Test.cancel("Host-dependent test skipped (NITS_SKIP_HOST_DEPENDENT_TESTS)")
        }
    }
}

extension Trait where Self == HostDependentTrait {
    /// See `HostDependentTrait`.
    static var hostDependent: Self { Self() }
}
