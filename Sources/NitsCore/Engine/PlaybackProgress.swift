/// Where the playback of the loaded media stands, as its history tells it (`PlayerEngine.playbackProgress`): what Nits
/// saves for resuming, and what a host that keeps progress of its own (a store, a media server) should save too.
///
/// For most media it is the engine's position against the duration. A live stream's history
/// (`MediaInfo.isLiveHistory`) is told in the stream's own time, which the engine's is shifted from
/// (`MediaInfo.timelineOrigin`), and against the stream as long as it is known now (to the end of its window), so the
/// same moment keeps its number as the window moves and the recording that follows counts it the same way.
public struct PlaybackProgress: Equatable, Sendable {
    /// Seconds into the media; for a live stream's history, the stream's own time.
    public var position: Double
    /// The media's duration; for a live stream's history, the stream's own time at the end of its window (or the
    /// position, if that is later).
    public var duration: Double
    /// The stream is on the air: it has no end to have watched to yet, only an edge (`wasAtLiveEdge`).
    public var isLive: Bool
    /// On the air, whether the position was at the live edge: such a stream is watched live again, not resumed.
    public var wasAtLiveEdge: Bool

    public init(position: Double, duration: Double, isLive: Bool = false, wasAtLiveEdge: Bool = false) {
        self.position = position
        self.duration = duration
        self.isLive = isLive
        self.wasAtLiveEdge = wasAtLiveEdge
    }
}
