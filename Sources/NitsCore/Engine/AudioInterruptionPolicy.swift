/// What the engine owes the user after the system takes the audio away (a call, Siri, an alarm) and hands it back.
///
/// An interruption pauses what was playing, and its end resumes it only when the system says to (`shouldResume`) and
/// nothing since asked for something else: a user who paused or started playback during the interruption has decided.
struct AudioInterruptionPolicy: Equatable {
    /// Playing when the interruption began, and not touched since.
    private(set) var resumesAtEnd = false
    private(set) var isInterrupted = false

    /// The interruption began; `isPlaying` is what the engine was doing. One that begins before the first has ended
    /// (Siri during a call) never takes the wish to resume away: by then the engine is paused by the first, and the
    /// video that played before it is what the end should bring back. Playing again meanwhile (the user's doing) and
    /// interrupted anew is playing at an interruption like any other.
    mutating func began(isPlaying: Bool) {
        isInterrupted = true
        resumesAtEnd = resumesAtEnd || isPlaying
    }

    /// The user asked for playback or a pause meanwhile: the end resumes nothing.
    mutating func userChangedPlayback() {
        resumesAtEnd = false
    }

    /// The interruption ended; whether to play.
    mutating func ended(shouldResume: Bool) -> Bool {
        defer { reset() }
        return isInterrupted && shouldResume && resumesAtEnd
    }

    mutating func reset() {
        self = AudioInterruptionPolicy()
    }
}
