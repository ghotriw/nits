import Foundation
import NitsCore
import os

/// Runs yt-dlp once and collects what it writes, without blocking a thread: pipes are read as they fill (a page's JSON
/// is hundreds of KB, past a pipe's buffer), the exit is awaited through `terminationHandler`. Cancelling the task
/// terminates the process.
enum YTDLPProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// How long the output may still come after the exit: a process yt-dlp started (Deno) that outlived it would
    /// hold the pipes open.
    static let drainTimeout: DispatchTimeInterval = .seconds(1)

    static func run(
        _ executable: URL, arguments: [String], path: String, timeout: Duration
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let run = Run(process: process, stdout: stdout, stderr: stderr)

        let timer = Task {
            try await Task.sleep(for: timeout)
            run.terminate(timedOut: true)
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            run.terminate(timedOut: false)
        }
    }

    /// One run's state, shared by the pipes' and the process's handlers and the cancellation.
    private final class Run: @unchecked Sendable {
        // `Process` is driven only under `state`'s lock: launched once, terminated only once launched (it raises
        // otherwise). The pipes are read under it too, so that `finish` never closes one a handler is reading.
        private let process: Process
        private let stdout: Pipe
        private let stderr: Pipe

        private struct State {
            var isLaunched = false
            var isTerminated = false
            var timedOut = false
            var stdout = Data()
            var stderr = Data()
            var openPipes = 2
            var arePipesClosed = false
            var exitStatus: Int32?
            var continuation: CheckedContinuation<Output, any Error>?
            var timeout: Duration = .zero
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        init(process: Process, stdout: Pipe, stderr: Pipe) {
            self.process = process
            self.stdout = stdout
            self.stderr = stderr
        }

        func start(timeout: Duration, continuation: CheckedContinuation<Output, any Error>) {
            stdout.fileHandleForReading.readabilityHandler = { [self] handle in
                received(on: handle, isStdout: true)
            }
            stderr.fileHandleForReading.readabilityHandler = { [self] handle in
                received(on: handle, isStdout: false)
            }
            process.terminationHandler = { [self] process in
                let status = process.terminationStatus
                state.withLock { $0.exitStatus = status }
                finishIfDone()
                DispatchQueue.global().asyncAfter(deadline: .now() + YTDLPProcess.drainTimeout) { [self] in
                    finish()
                }
            }
            let failure: (any Error)? = state.withLock { state in
                state.continuation = continuation
                state.timeout = timeout
                // Cancelled before it started.
                guard !state.isTerminated else { return CancellationError() }
                do {
                    try process.run()
                    state.isLaunched = true
                    return nil
                } catch {
                    return MediaResolutionError(
                        "Can't run yt-dlp: \(error.localizedDescription)", isAboutPage: false)
                }
            }
            if let failure {
                let continuation = state.withLock { state in
                    defer { state.continuation = nil }
                    return state.continuation
                }
                continuation?.resume(throwing: failure)
                closePipes()
            }
        }

        /// Stops yt-dlp and what it started (Deno; Python under the standalone `yt-dlp_macos`'s PyInstaller loader),
        /// which would otherwise run on, orphaned: `Process` launches it as a process group of its own and
        /// `terminate()` signals the whole group, which its descendants stay in unless they leave it (`setsid`).
        func terminate(timedOut: Bool) {
            state.withLock { state in
                guard !state.isTerminated, state.exitStatus == nil else { return }
                state.isTerminated = true
                state.timedOut = timedOut
                if state.isLaunched { process.terminate() }
            }
        }

        private func received(on handle: FileHandle, isStdout: Bool) {
            let isAtEnd = state.withLock { state in
                guard !state.arePipesClosed else { return false }
                let data = handle.availableData
                guard !data.isEmpty else {
                    state.openPipes -= 1
                    return true
                }
                if isStdout { state.stdout.append(data) } else { state.stderr.append(data) }
                return false
            }
            if isAtEnd {
                handle.readabilityHandler = nil
                finishIfDone()
            }
        }

        private func finishIfDone() {
            let isDone = state.withLock { $0.exitStatus != nil && $0.openPipes <= 0 }
            if isDone { finish() }
        }

        /// Resumes the run's task, once: with the output, or why there is none. The pipes close then: one still held
        /// open (by a process yt-dlp left behind) would otherwise keep its handler, and this run, until that exits.
        private func finish() {
            let (continuation, result): (CheckedContinuation<Output, any Error>?, Result<Output, any Error>) =
                state.withLock { state in
                    defer { state.continuation = nil }
                    let result: Result<Output, any Error>
                    if state.timedOut {
                        result = .failure(
                            MediaResolutionError(
                                "yt-dlp didn't answer in \(state.timeout.components.seconds) s", isAboutPage: false))
                    } else if state.isTerminated {
                        result = .failure(CancellationError())
                    } else {
                        result = .success(
                            Output(status: state.exitStatus ?? -1, stdout: state.stdout, stderr: state.stderr))
                    }
                    return (state.continuation, result)
                }
            continuation?.resume(with: result)
            closePipes()
        }

        private func closePipes() {
            let isFirst = state.withLock { state in
                defer { state.arePipesClosed = true }
                return !state.arePipesClosed
            }
            guard isFirst else { return }
            for pipe in [stdout, stderr] {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
            }
        }
    }
}
