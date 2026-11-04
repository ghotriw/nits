import CFFmpeg
import Foundation
import os

/// Aborts blocking FFmpeg I/O (open, read, seek) on request or after an optional deadline. Once
/// installed on an `AVFormatContext`, FFmpeg polls it from inside those calls. Also keeps the last error
/// the owner recorded, so a caller that cancelled or timed out can still report why opening failed.
public final class FFmpegInterrupt: Sendable {
    private struct State: Sendable {
        var isCancelled = false
        /// Callers waiting to take the demuxer's input from a read that waits (`yieldIO`).
        var yielders = 0
        var deadline: ContinuousClock.Instant?
        var lastError: (code: Int32, message: String)?
    }

    private let state: OSAllocatedUnfairLock<State>

    /// - Parameter timeout: aborts I/O once this much time has passed; `nil` waits indefinitely (or until
    ///   `startTimeout(_:)`).
    public init(timeout: Duration? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(deadline: timeout.map { .now + $0 }))
    }

    /// Starts (or restarts) the deadline now. Work queued before it runs should arm its timeout when it starts, so
    /// time spent waiting for a busy queue does not count against it.
    public func startTimeout(_ timeout: Duration) {
        state.withLock { $0.deadline = .now + timeout }
    }

    /// `cancel()` was called. Doesn't include the deadline; see `shouldAbort`.
    public var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    /// Cancelled, or past the deadline: what FFmpeg's interrupt callback reports.
    public var shouldAbort: Bool {
        state.withLock { state in
            state.isCancelled || state.deadline.map { ContinuousClock.now >= $0 } ?? false
        }
    }

    public func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    /// A caller that is about to reposition the input (a seek) is waiting for a read to let go of it: FFmpeg's blocking
    /// calls are interrupted until `resumeIO()`. For a read that waits for a live stream's next segment, which would
    /// hold the input for as long as the stream stalls. Not part of `shouldAbort`: the waits of Swift code go on.
    func yieldIO() {
        state.withLock { $0.yielders += 1 }
    }

    /// A caller waits to reposition the input (`yieldIO`).
    var isYieldingIO: Bool {
        state.withLock { $0.yielders > 0 }
    }

    func resumeIO() {
        state.withLock { $0.yielders -= 1 }
    }

    /// What FFmpeg's interrupt callback reports: `shouldAbort`, or a caller waiting to reposition the input.
    var shouldInterruptFFmpeg: Bool {
        state.withLock { state in
            state.isCancelled || state.yielders > 0 || state.deadline.map { ContinuousClock.now >= $0 } ?? false
        }
    }

    public var lastError: (code: Int32, message: String)? {
        state.withLock { $0.lastError }
    }

    public func recordError(code: Int32, message: String) {
        state.withLock { $0.lastError = (code, message) }
    }

    /// Points `ctx`'s interrupt callback at this object. FFmpeg only takes a C callback with an
    /// unretained pointer, so the caller must keep `self` alive for as long as `ctx` is open.
    func install(on ctx: UnsafeMutablePointer<AVFormatContext>) {
        ctx.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<FFmpegInterrupt>.fromOpaque(opaque).takeUnretainedValue().shouldInterruptFFmpeg ? 1 : 0
        }
    }
}
