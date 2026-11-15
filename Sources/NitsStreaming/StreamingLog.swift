import Foundation
import os

/// The client's log, which NitsCore backs with its own (`AppLog`): the client knows no logging of its host, so it
/// writes through a sink NitsCore installs and the level below which a line is dropped before its text is built.
/// Until a sink is installed lines are dropped (the client's own tests).
package enum StreamingLog {
    package enum Level: Int, Sendable, Comparable {
        case debug, info, notice, warning, error

        package static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Where a line goes: its level, text, and the file and line that wrote it.
    package typealias Sink = @Sendable (Level, String, String, Int) -> Void

    private struct State: Sendable {
        var sink: Sink?
        var threshold = Level.debug
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Installs the sink (replacing one installed before).
    package static func install(_ sink: @escaping Sink) {
        state.withLock { $0.sink = sink }
    }

    /// The level below which lines are dropped. Kept apart from the sink: the host's level changes at any time, also
    /// before the sink is installed.
    package static func setThreshold(_ level: Level) {
        state.withLock { $0.threshold = level }
    }

    package static func log(_ level: Level, _ message: () -> String, file: String = #file, line: Int = #line) {
        guard let sink = state.withLock({ $0.sink != nil && level >= $0.threshold ? $0.sink : nil }) else { return }
        sink(level, message(), file, line)
    }

    package static func debug(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(.debug, message, file: file, line: line)
    }

    package static func info(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(.info, message, file: file, line: line)
    }

    package static func warning(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(.warning, message, file: file, line: line)
    }

    package static func error(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(.error, message, file: file, line: line)
    }
}
