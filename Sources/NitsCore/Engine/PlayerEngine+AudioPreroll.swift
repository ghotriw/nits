import CoreMedia
import Foundation

/// Audio before the clock starts, after a seek flushed the renderer.
///
/// A seek empties the audio renderer, and a start that does not wait for it to be refilled runs the clock on an empty
/// queue: `checkForStarvation` finds audio and frames short at its first tick and holds the clock again, with a
/// spinner, until the queues fill. (A start that blocked the main thread for the audio device used to give the feeders
/// that time by accident.) Waiting here instead starts the clock when the audio is there.
extension PlayerEngine {
    /// Whether the clock may start at `target`: the renderer holds enough audio past it, or nothing is owed. Only a
    /// renderer flushed by a seek is waited for; one that has been playing, paused, or just loaded is not.
    func isAudioReadyToStart(at target: CMTime) -> Bool {
        guard chaseSettling.isAudioRefillPending else { return true }
        guard hasAudioStream, let inputs, !inputs.isAudioEOF else {
            chaseSettling.isAudioRefillPending = false
            return true
        }
        // A flush owed or on its way: `bufferedEnd` is still the audio from before it, about to go.
        if chaseSettling.isAudioFlushPending || audioSink.isFlushOwed { return false }
        guard target.isNumeric else { return true }
        guard audioAhead(of: target) >= BufferingPolicy.audioAheadToStart(rate: playbackRate) else { return false }
        chaseSettling.isAudioRefillPending = false
        return true
    }

    /// Starts the pending clock once the audio is ready, when nothing else would: with no picture to present there is
    /// no display-link tick, and with one the tick waits for this to clear `awaitsAudio` (`startPendingClockIfPrerolled`).
    /// The preroll timeout still bounds it.
    func awaitAudioBeforeClockStart() {
        prerollAudioTask?.cancel()
        prerollAudioTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.prerollAudioPollInterval)
                guard !Task.isCancelled, let self,
                    let target = self.pendingClockStartLock.withLock({ $0?.targetTime })
                else { return }
                guard self.isAudioReadyToStart(at: target) else { continue }
                self.prerollAudioTask = nil
                let startsHere = !self.media.hasVideo || self.displayLink == nil || (self.inputs?.isVideoEOF ?? true)
                let pending = self.pendingClockStartLock.withLock { state -> PendingClockStart? in
                    guard var pending = state else { return nil }
                    pending.awaitsAudio = false
                    if startsHere {
                        state = nil
                    } else {
                        state = pending
                    }
                    return startsHere ? pending : nil
                }
                if let pending {
                    self.startSynchronizerClock(
                        at: pending.targetTime, rate: pending.rate, startDelay: pending.startDelay)
                    self.updateAwaitingClockStart()
                    AppLog.debug(.engine, "Preroll: audio ready; starting clock at \(pending.targetTime.seconds)s")
                }
                return
            }
        }
    }

    static let prerollAudioPollInterval: Duration = .milliseconds(10)
}
