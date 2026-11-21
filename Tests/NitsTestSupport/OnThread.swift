import Foundation

/// Runs `work`, which blocks, on a thread of its own, as the demuxer's read thread does: not in the cooperative pool, whose
/// one thread (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) it would hold while waiting for a task that needs it.
public func onThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: work()) }
    }
}
