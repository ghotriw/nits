@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import QuartzCore
import os

/// The master clock: an `AVSampleBufferRenderSynchronizer`, whose rate changes are applied on a queue of their own.
///
/// `setRate` waits for the audio renderer's queue, which takes its lock while it starts, stops or flushes, and a
/// pause that came just after a start (a second press of an arrow key) blocked the caller for up to 700 ms. The
/// caller was the main thread or the display link's, so the picture and the UI stood still with it. Here a change
/// is recorded at once and applied in order behind the caller's back.
///
/// `currentTime()` is the clock as the latest change makes it, for the engine and the display link alike:
/// - A clock asked to hold reads as held at that position, applied or not.
/// - A clock asked to run reads as standing at its start until the change is applied and the synchronizer has come
///   to it. The synchronizer itself keeps showing the old position for a while after `setRate` returns (until the
///   audio device runs, tens to hundreds of ms), and a reader taking that for the clock would drop every frame from
///   the new position as late. Not projected forward: the synchronizer holds the clock back while the audio device
///   starts, and a clock that ran ahead of it would step back.
/// - A synchronizer that never comes within `settlingTimeout` of applying the change is read as it is.
final class PlaybackClock: @unchecked Sendable {
    let synchronizer = AVSampleBufferRenderSynchronizer()

    /// How long after a start is applied the synchronizer may stay outside the window of its start. After it the
    /// clock is read as it is, so a clock that does not settle never hangs the picture.
    static let settlingTimeout: TimeInterval = 0.35
    /// How far from its start the synchronizer may read and still count as having come to it.
    static let settlingTolerance: TimeInterval = 0.15

    private struct State {
        /// The latest change asked for.
        var rate: Float = 0
        var time: CMTime = .invalid
        var requested = 0
        /// The latest change applied: `applied < requested` while one is in the queue.
        var applied = 0
        var appliedAt: TimeInterval = 0
        /// The synchronizer has come to the start of the change applied.
        var hasSettled = true
        /// The change keeps a running clock where it is (a new rate): nothing to wait for, the synchronizer is read as it
        /// runs.
        var isContinuous = false

        var isPending: Bool { applied < requested }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.nits.playback-clock", qos: .userInteractive)

    /// The rate last asked for.
    var rate: Float { state.withLock { $0.rate } }

    /// Where the clock is, or where it was asked to hold or start.
    ///
    /// The synchronizer is read outside the lock: it takes the audio renderer's locks inside, and a reader that waited
    /// for them would hold everyone else behind `state`.
    func currentTime() -> CMTime {
        let snapshot = state.withLock { $0 }
        guard snapshot.time.isNumeric, !snapshot.isContinuous else { return synchronizer.currentTime() }
        if snapshot.rate == 0 || snapshot.isPending { return snapshot.time }
        if snapshot.hasSettled { return synchronizer.currentTime() }

        let reading = synchronizer.currentTime()
        let start = snapshot.time.seconds
        let elapsed = max(0, CACurrentMediaTime() - snapshot.appliedAt)
        // From the start on, and not further than the clock could have run: a reading short of the start (a start
        // scheduled for a host time still ahead) is not the clock yet, and one far past it is the old position.
        let isSettled =
            reading.isNumeric && reading.seconds >= start
            && reading.seconds <= start + Double(snapshot.rate) * elapsed + Self.settlingTolerance
        if isSettled || elapsed >= Self.settlingTimeout {
            state.withLock {
                if $0.requested == snapshot.requested { $0.hasSettled = true }
            }
            return reading
        }
        return snapshot.time
    }

    /// Records the change and applies it behind earlier ones.
    ///
    /// - Parameter keepsRunning: The change gives a running clock a new rate where it stands, so there is no start to
    ///   wait for: the synchronizer is read as it runs. Said by the caller; deciding it here would take a reading of
    ///   the synchronizer on the caller's thread, which can wait for the audio renderer.
    func setRate(
        _ rate: Float, time: CMTime, atHostTime hostTime: CMTime? = nil, keepsRunning: Bool = false
    ) {
        let number = state.withLock { state -> Int in
            // Only a clock that runs and has settled keeps running: one still on its way to a start is read from that
            // start, whatever the new rate.
            let wasRunning = state.rate > 0 && !state.isPending && (state.hasSettled || state.isContinuous)
            state.isContinuous = rate > 0 && keepsRunning && wasRunning
            state.rate = rate
            state.time = time
            state.requested += 1
            state.hasSettled = rate == 0 || state.isContinuous
            return state.requested
        }
        let synchronizer = synchronizer
        queue.async { [state] in
            if let hostTime {
                synchronizer.setRate(rate, time: time, atHostTime: hostTime)
            } else {
                synchronizer.setRate(rate, time: time)
            }
            state.withLock {
                $0.applied = number
                $0.appliedAt = CACurrentMediaTime()
            }
        }
    }

    /// Returns once every change made so far has been applied.
    func waitUntilApplied() {
        queue.sync {}
    }
}
