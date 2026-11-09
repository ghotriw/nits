import CoreMedia
import Foundation
import QuartzCore
import os

/// Brings the audio back after a seek that resumes, behind a picture that already runs.
///
/// A seek leaves the audio renderer holding sound from the old position. Flushing it restarts its audio queue and, with
/// it, the output device's IO (tens of milliseconds on built-in speakers, up to ~350 ms on a Bluetooth route), and then
/// it has to be refilled. The picture does not wait for that: after the seek the clock runs on host time alone
/// (`PlaybackClock.startProvisional`), and this joins the audio to it:
///
/// 1. The renderer is flushed while the synchronizer is held at rate 0 (a flush under a running one is the slow case).
/// 2. Audio is fed from the media's position of the moment, not from the seek's target: what the picture has passed
///    meanwhile is cut off, to the sample (`AudioSampleTrim`).
/// 3. Once the renderer holds enough past the point it will start at, the synchronizer takes the clock over
///    (`PlaybackClock.handOver`), one output latency ahead, as a resume from pause is scheduled.
///
/// A new seek, a pause or a load cancels it (`PlayerEngine.cancelPreroll()`), and a join of a series of seeks is only the
/// last one's. When the audio does not come in `timeout`, the picture is held and playback buffers, as any other run of
/// media that has run out does.
@MainActor
final class AudioJoin {
    /// How long the audio may take to come back before playback goes to buffering.
    static let timeout: Duration = .milliseconds(1500)
    static let pollInterval: Duration = .milliseconds(10)
    /// How long after the hand-over the join waits for the new audio to get ahead of the clock (see the end of `run`).
    static let settleTimeout: Duration = .seconds(1)

    private var task: Task<Void, Never>?
    /// The cut of the join under way; lifted when it ends, for the feeding run goes on feeding.
    private var cutIsActive: OSAllocatedUnfairLock<Bool>?

    var isActive: Bool { task != nil }

    /// What the renderer holds is not the audio for the position: a seek moved the position (and flushed the renderer, or
    /// will), and no join has completed since. Playing on from there is a join as well, or the clock would start over an
    /// empty or stale queue and `checkForStarvation` would hold it again. Set by a seek, cleared once a join's new audio
    /// is ahead of the clock (or the audio has ended), or a buffering resume.
    var isRendererStale = false

    func cancel() {
        task?.cancel()
        task = nil
        cutIsActive?.withLock { $0 = false }
        cutIsActive = nil
    }

    /// - Parameters:
    ///   - target: Where the media resumes.
    ///   - hasPicture: The clock runs provisionally from the picture's start; without a picture it starts once the audio
    ///     is there.
    func begin(on engine: PlayerEngine, from target: CMTime, hasPicture: Bool) {
        cancel()
        let isActive = OSAllocatedUnfairLock(initialState: true)
        cutIsActive = isActive
        task = Task { @MainActor [weak engine, weak self] in
            guard let engine else { return }
            let keepsCut = await Self.run(on: engine, from: target, hasPicture: hasPicture, isCutActive: isActive)
            guard !Task.isCancelled else { return }
            // Given up to buffering, the cut stays until the buffering resumes (`cancelPreroll()`): the held clock does
            // not run, and the renderer must not fill with the audio behind it.
            if !keepsCut { isActive.withLock { $0 = false } }
            self?.task = nil
        }
    }

    /// - Returns: The cut stays active (the join gave up to buffering, which holds the clock at a position).
    private static func run(
        on engine: PlayerEngine, from target: CMTime, hasPicture: Bool, isCutActive: OSAllocatedUnfairLock<Bool>
    ) async -> Bool {
        let sink = engine.audioSink
        let clock = engine.playbackClock

        // The change to rate 0 that the seek made goes first: a flush under a synchronizer that is still stopping
        // is as slow as one under a running one.
        while !clock.isIdle {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return false }
        }

        // Asked of the HAL off the main actor, and after the device has stopped: while it stops the query waits for it.
        let maxLatency = PlayerEngine.maxOutputLatencyAlignment
        let latency = await Task.detached {
            min(PlatformAudioOutputRoute.currentOutputLatency() ?? 0, maxLatency)
        }.value
        guard !Task.isCancelled else { return false }

        // Flushed only when the audio it holds reaches past where the new audio starts (on the clock's timeline): a
        // flush restarts the output's IO on some routes (multichannel to AirPods: ~0.5 s before the device runs again).
        // Audio that ends before the start is dropped by the synchronizer as late once the clock runs, so a seek forward
        // past it, or a series of them, keeps the device running. The start only moves on from here.
        let startsAt =
            hasPicture
            ? clock.currentTime() + CMTime(seconds: latency * Double(clock.readRate), preferredTimescale: 1_000_000)
            : target
        let needsFlush = Self.needsFlush(
            bufferedEnd: sink.bufferedEnd, startsAt: startsAt, isFlushOwed: sink.isFlushOwed,
            isEnqueuePending: sink.pendingStart != nil)
        if needsFlush { sink.expectFlush() }
        AppLog.debug(
            .engine,
            "Audio join \(needsFlush ? "flushes" : "keeps") the renderer: its audio ends at "
                + "\(sink.bufferedEnd.map { String(format: "%.3f", $0.seconds) } ?? "-")s, the new starts at "
                + "\(String(format: "%.3f", startsAt.seconds))s")
        // Not played before the clock gets to where the audio will be heard: the clock's position, one latency on (at
        // the rate it runs at, which a change of speed moves). In the media's time, which the audio delay shifts from
        // the clock's. Without a picture the clock starts at `target`, and all of the audio from there is heard.
        let heldAt = OSAllocatedUnfairLock<CMTime?>(initialState: nil)
        let cut: @Sendable () -> CMTime? = { [clock, sink] in
            guard isCutActive.withLock({ $0 }) else { return nil }
            // Buffering holds the clock: audio is wanted from where it stands.
            if let held = heldAt.withLock({ $0 }) { return held - sink.currentDelay }
            guard hasPicture else { return nil }
            let lead = CMTime(seconds: latency * Double(clock.readRate), preferredTimescale: 1_000_000)
            return clock.currentTime() + lead - sink.currentDelay
        }
        let flush: @Sendable () -> Void = { sink.flush() }
        let prepare: (@Sendable () -> Void)? = needsFlush ? flush : nil
        let isFed = engine.startFeedingAudio(prepare: prepare, cut: cut)
        if !isFed {
            if needsFlush { sink.withdrawExpectedFlush() }
            engine.audioJoin.isRendererStale = false
            engine.startSynchronizerClock(at: target, rate: engine.playbackRate, startDelay: 0)
            return false
        }

        // The wait for the audio counts from the picture's start (its first frame can take a while on a slow source),
        // and from the beginning without a picture.
        var waitStart: ContinuousClock.Instant? = hasPicture ? nil : .now
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return false }
            if hasPicture, waitStart == nil, clock.isProvisional { waitStart = .now }
            // An enqueue that has waited `fullAfter` on the renderer has met a full one.
            let isFull = sink.isRendererFull()
            if isReady(engine, clock: clock, latency: latency, target: target, hasPicture: hasPicture, isFull: isFull) {
                break
            }
            if let waitStart, ContinuousClock.now - waitStart >= timeout {
                let held = hasPicture ? clock.currentTime() : target
                heldAt.withLock { $0 = held }
                engine.holdForBuffering(at: held, because: "the audio did not come back")
                return true
            }
        }
        guard !Task.isCancelled else { return false }

        // The cut stays on until the join ends (`begin` lifts it): what a kept renderer takes only after the hand-over is
        // still cut to where the clock is by then.
        if hasPicture {
            // The output latency as it is when the clock is handed over, not as it was when the join began: the route can
            // have changed since (AirPods connected, the device's profile switched).
            let handOverLatency = await Task.detached {
                min(PlatformAudioOutputRoute.currentOutputLatency() ?? 0, maxLatency)
            }.value
            guard !Task.isCancelled else { return false }
            // The detector learns of the start first, as in `startSynchronizerClock`: a device run that begins after it
            // is what `AudioOutputInterruptionDetector` counts.
            engine.audioOutputInterruptionLock.withLock { $0.clockStarted(at: .now) }
            // A newer change of the clock (a pause, a seek) has replaced the provisional clock meanwhile: nothing is left to
            // join.
            guard clock.handOver(after: handOverLatency) != nil else {
                engine.audioOutputInterruptionLock.withLock { $0.clockStopped() }
                return false
            }
            AppLog.debug(.engine, "Audio joined the clock \(String(format: "%.0f", handOverLatency * 1000)) ms ahead")
        } else {
            let startLatency = await Task.detached {
                min(PlatformAudioOutputRoute.currentOutputLatency() ?? 0, maxLatency)
            }.value
            guard !Task.isCancelled else { return false }
            engine.startSynchronizerClock(at: target, rate: engine.playbackRate, startDelay: startLatency)
            AppLog.debug(.engine, "Audio ready; starting the clock at \(String(format: "%.3f", target.seconds))s")
        }

        // A renderer kept full of the old audio takes the new only once the clock runs and drops the old as late: until
        // the new is ahead of the clock, the join stays on, so `checkForStarvation` does not take the gap for media
        // run out (without a picture, it would hold the clock on a renderer that, held, never makes room).
        // The renderer holds the audio for the position only from then on (`isRendererStale`): a pause before it, with
        // the old audio still in, plays on through a join again, not over a renderer that a held clock never empties.
        // Ahead by as much as a start needs, not by the low watermark itself: left at the watermark, the clock moving on
        // by the next check of `checkForStarvation` reads as audio run out (seen at 1.7x: the join left with 0.257 s
        // ahead against a watermark of 0.255 s, and the clock was held 2 ms later, with the old audio still in).
        let settleStart = ContinuousClock.now
        while !Task.isCancelled, ContinuousClock.now - settleStart < settleTimeout {
            let now = clock.currentTime()
            if engine.inputs?.isAudioEOF ?? true
                || (now.isNumeric
                    && engine.audioAhead(of: now) >= BufferingPolicy.audioAheadToStart(rate: engine.playbackRate))
            {
                engine.audioJoin.isRendererStale = false
                break
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    /// Whether the renderer must be flushed before audio from `startsAt` (the clock's timeline) is fed: it holds audio
    /// that reaches past it (a seek back, or forward within what was fed), a flush is owed, or an enqueue is still in
    /// flight (its buffer may yet land after the decision). Audio that ends by `startsAt` is late once the clock gets
    /// there, and the synchronizer drops it.
    nonisolated static func needsFlush(
        bufferedEnd: CMTime?, startsAt: CMTime, isFlushOwed: Bool, isEnqueuePending: Bool
    ) -> Bool {
        if isFlushOwed || isEnqueuePending { return true }
        guard let bufferedEnd else { return false }
        guard bufferedEnd.isNumeric, startsAt.isNumeric else { return true }
        return bufferedEnd > startsAt
    }

    private static func isReady(
        _ engine: PlayerEngine, clock: PlaybackClock, latency: TimeInterval, target: CMTime, hasPicture: Bool,
        isFull: Bool
    ) -> Bool {
        // The picture's start comes first: its clock is the one the audio joins.
        if hasPicture, !clock.isProvisional { return false }
        guard let inputs = engine.inputs else { return true }
        if inputs.isAudioEOF { return true }
        // The renderer takes only so much with the synchronizer held: full (of the new audio, or of the old that a kept
        // renderer drops as late once the clock runs) is as much as there is room for.
        if isFull { return true }
        let rate = Double(hasPicture ? clock.readRate : Float(engine.playbackRate))
        let startsAt =
            hasPicture
            ? clock.currentTime() + CMTime(seconds: latency * rate, preferredTimescale: 1_000_000) : target
        guard startsAt.isNumeric else { return true }
        return engine.audioAhead(of: startsAt) >= BufferingPolicy.audioAheadToStart(rate: rate)
    }
}
