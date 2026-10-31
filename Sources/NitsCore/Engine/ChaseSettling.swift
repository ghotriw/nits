import Foundation

/// What the seeks of a burst decide among themselves, and what a seek leaves the audio renderer: how long a resume
/// waits for more seeks (the debounce), whether the renderer is owed a flush, and whether the audio has been refilled
/// since (`PlayerEngine.isAudioReadyToStart`). Reset with the media.
///
/// Not `Sendable`: kept on the main actor by `PlayerEngine`, which owns the seeks.
struct ChaseSettling {
    /// A seek that follows another within this resumes playback only after it, so key-hold repeats (every 40–70 ms)
    /// do not start and stop the clock each time.
    static let burstDebounce: Duration = .milliseconds(300)

    private var lastRequestAt: ContinuousClock.Instant?
    /// How long the resume waits after the seek lands: the debounce for a seek in a burst, none for one on its own, as
    /// mpv's `MPSEEK_FLAG_DELAY` waits just while a burst is on.
    private(set) var resumeDelay: Duration = .zero
    /// A seek that resumes playback leaves the audio renderer unflushed: the clock is held and nothing feeds it until
    /// the resume (or `startFeeding()`), which flushes first. Flushing at each landing restarted the renderer's audio
    /// queue once per press of a burst.
    var isAudioFlushPending = false
    /// The renderer was flushed by a seek and the audio has not been refilled since: the clock does not start before it
    /// has (`PlayerEngine.isAudioReadyToStart`), or it runs on an empty queue and `checkForStarvation` holds it again.
    var isAudioRefillPending = false

    /// The resume that is past its wait (flushing the renderer, then starting the feeders and the clock) can no longer be
    /// restarted: a restart would skip the flush it has under way, and its audio would be erased after the clock starts.
    private var settleToken = 0
    private var committedSettle: Int?
    var isSettleCommitted: Bool { committedSettle != nil }

    /// A resume is scheduled; returns its token. Replaces whatever was scheduled before.
    mutating func beginSettle() -> Int {
        settleToken += 1
        committedSettle = nil
        return settleToken
    }

    /// The resume of `token` is past its wait.
    mutating func commitSettle(_ token: Int) {
        if token == settleToken { committedSettle = token }
    }

    /// The resume of `token` is done or gave up.
    mutating func endSettle(_ token: Int) {
        if committedSettle == token { committedSettle = nil }
    }

    /// A newer seek, or a stop, supersedes the resume, committed or not.
    mutating func abandonSettle() {
        settleToken += 1
        committedSettle = nil
    }

    /// The burst is over (the key that made it was released): the resume waits for nothing more.
    mutating func endBurst() {
        resumeDelay = .zero
    }

    /// A seek is requested.
    mutating func noteRequest(at instant: ContinuousClock.Instant = .now) {
        let isBurst = lastRequestAt.map { instant - $0 < Self.burstDebounce } ?? false
        lastRequestAt = instant
        resumeDelay = isBurst ? Self.burstDebounce : .zero
    }

    mutating func reset() {
        self = ChaseSettling()
    }
}
