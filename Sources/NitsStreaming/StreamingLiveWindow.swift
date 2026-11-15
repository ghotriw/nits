/// The part of a live stream that can be played, as the client's playlist model tells it: from the first segment listed to
/// the end of the last, in seconds on the timeline of the packets. NitsCore turns it into its public `LiveWindow`.
package struct StreamingLiveWindow: Equatable, Sendable {
    /// Start of the oldest segment listed: the farthest back a seek goes.
    package var start: Double
    /// End of the newest segment listed: the live edge.
    package var end: Double
    /// The playlist had slid when it was read (its first segment is not the stream's first).
    package var hasSlid: Bool
    /// The playlist ended: this is its last window.
    package var hasEnded: Bool
    /// How far behind the edge the stream says it is meant to be played, when it says (a DASH manifest's
    /// `suggestedPresentationDelay`).
    package var holdBack: Double?

    package init(start: Double, end: Double, hasSlid: Bool = false, hasEnded: Bool = false, holdBack: Double? = nil) {
        self.start = start
        self.end = end
        self.hasSlid = hasSlid
        self.hasEnded = hasEnded
        self.holdBack = holdBack
    }
}
