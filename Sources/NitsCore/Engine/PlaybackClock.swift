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

    /// A clock that runs on host time alone, while the audio is flushed and refilled behind it (`startProvisional`):
    /// the picture does not wait for the audio device. `handOver` gives the position to the synchronizer.
    private struct Provisional {
        var time: CMTime
        var hostSeconds: TimeInterval
        var rate: Float
        /// Set by `handOver`: the host time the synchronizer takes the position over at.
        var handOverAt: TimeInterval?

        func position(at host: TimeInterval) -> CMTime {
            time + CMTime(seconds: max(0, host - hostSeconds) * Double(rate), preferredTimescale: 1_000_000)
        }
    }

    private struct State {
        /// The latest change asked for.
        var rate: Float = 0
        var time: CMTime = .invalid
        var provisional: Provisional?
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
        if let provisional = snapshot.provisional { return provisionalTime(provisional, snapshot: snapshot) }
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

    /// The rate the clock runs at as `currentTime()` reads it: a provisional clock's, which the synchronizer (held at
    /// rate 0 meanwhile) does not show.
    var readRate: Float {
        if let provisional = state.withLock({ $0.provisional }) { return provisional.rate }
        return Float(CMTimebaseGetRate(synchronizer.timebase))
    }

    /// Every change made so far has been applied to the synchronizer.
    var isIdle: Bool { state.withLock { !$0.isPending } }

    /// Whether the clock runs on host time alone, until the synchronizer takes it over.
    var isProvisional: Bool { state.withLock { $0.provisional != nil } }

    /// Starts the clock at `time` on host time, with the synchronizer held there at rate 0. For a seek that resumes: the
    /// picture runs at once and the audio device, which can take hundreds of milliseconds to come back, joins later
    /// (`handOver`).
    func startProvisional(at time: CMTime, rate: Float) {
        let now = CACurrentMediaTime()
        let number = state.withLock { state -> Int in
            state.rate = rate
            state.time = time
            state.requested += 1
            state.hasSettled = false
            state.isContinuous = false
            state.provisional = Provisional(time: time, hostSeconds: now, rate: rate)
            return state.requested
        }
        let synchronizer = synchronizer
        queue.async { [state] in
            synchronizer.setRate(0, time: time)
            state.withLock {
                $0.applied = number
                $0.appliedAt = CACurrentMediaTime()
            }
        }
    }

    /// A new rate for a clock that is provisional: it goes on from where it is, at the new rate, with the synchronizer
    /// left as it is (held), for the join to take over at that rate. `false` when the clock is not provisional, or the
    /// synchronizer has been given it already.
    func changeProvisionalRate(to rate: Float) -> Bool {
        let now = CACurrentMediaTime()
        return state.withLock { state in
            guard let provisional = state.provisional, provisional.handOverAt == nil else { return false }
            let time = provisional.position(at: now)
            state.provisional = Provisional(time: time, hostSeconds: now, rate: rate)
            state.rate = rate
            state.time = time
            return true
        }
    }

    /// Gives the provisional clock to the synchronizer, to take over at `now + lead` (the output latency, so the sound
    /// reaches the ear when the clock reaches it) at the position the provisional clock holds then. Returns that host
    /// time, or `nil` when the clock is not provisional (a newer change replaced it).
    @discardableResult
    func handOver(after lead: TimeInterval) -> TimeInterval? {
        let now = CACurrentMediaTime()
        let handOver = state.withLock { state -> (rate: Float, time: CMTime, host: TimeInterval, number: Int)? in
            guard var provisional = state.provisional, provisional.handOverAt == nil else { return nil }
            let host = now + lead
            let time = provisional.position(at: host)
            provisional.handOverAt = host
            state.provisional = provisional
            state.rate = provisional.rate
            state.time = time
            state.requested += 1
            state.hasSettled = false
            return (provisional.rate, time, host, state.requested)
        }
        guard let handOver else { return nil }
        let synchronizer = synchronizer
        queue.async { [state] in
            synchronizer.setRate(
                handOver.rate, time: handOver.time,
                atHostTime: CMTime(seconds: handOver.host, preferredTimescale: 1_000_000_000))
            state.withLock {
                $0.applied = handOver.number
                $0.appliedAt = CACurrentMediaTime()
            }
        }
        return handOver.host
    }

    /// The provisional clock's position, until the synchronizer has taken over: from the host time it was given
    /// (`handOver`) on, once it reads where the provisional clock is, or has had `settlingTimeout` to.
    private func provisionalTime(_ provisional: Provisional, snapshot: State) -> CMTime {
        let now = CACurrentMediaTime()
        let projected = provisional.position(at: now)
        guard let handOverAt = provisional.handOverAt, now >= handOverAt, !snapshot.isPending else { return projected }
        let reading = synchronizer.currentTime()
        let isSettled = reading.isNumeric && abs(reading.seconds - projected.seconds) <= Self.settlingTolerance
        guard isSettled || now - handOverAt >= Self.settlingTimeout else { return projected }
        state.withLock {
            if $0.requested == snapshot.requested {
                $0.provisional = nil
                $0.hasSettled = true
            }
        }
        return reading
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
            state.provisional = nil
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
