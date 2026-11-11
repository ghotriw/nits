import Foundation

/// What a read of a subtitle rendition outside playback needs (`EmbeddedSubtitleReader.readSubtitles(hls:in:interrupt:)`):
/// the rendition's playlist as the opening placed it on the timeline, the offsets the playback's pictures anchored
/// (shared, thread-safe) and how to reach the server. Immutable once made; a live stream has none (its window moves, and
/// playback reads it from the edge).
struct HLSSubtitleWindowSource: Sendable {
    /// The address the stream was opened by, and the headers its requests carry: the reader makes a transport of its own.
    let address: String
    let headers: [String: String]
    let allowsFiles: Bool
    let url: URL
    let timeline: HLSTimeline
    let variables: [String: String]
    let anchors: HLSTimestampAnchors
    /// The cookies the stream's own session holds (the master's answer set them), which the read's session takes over.
    let cookies: @Sendable () -> [HTTPCookie]
}

extension HLSSubtitleWindowSource {
    /// The part of `range` that can be read and placed rightly, and the `limit` a lane is read to (no segment that starts
    /// after it is loaded). Cues are placed by the offset of their discontinuity sequence
    /// (`HLSTimestampAnchors.subtitleShift`); a sequence nobody has anchored would give them the picture's current
    /// offset: wrong times, which the merge would take as read. So the read starts at the first segment at or after
    /// `range.lowerBound` whose sequence is anchored (a cue that runs across the boundary is repeated in the WebVTT
    /// segment that follows) and ends before the first segment after it whose sequence is not (the one that starts at
    /// the break is not loaded). A playlist of one sequence has no break, but before anything is anchored its cues get no
    /// offset at all (a transport stream that doesn't start at 0 would be off by its start). Nil when nothing in the
    /// range can be read yet.
    func readable(in range: ClosedRange<Double>) -> (range: ClosedRange<Double>, limit: Double)? {
        let entries = timeline.entries
        guard Set(entries.map { $0.segment.discontinuitySequence }).count > 1 else {
            return anchors.hasAnchors ? (range, range.upperBound) : nil
        }
        let ahead = entries.filter { $0.end > range.lowerBound && $0.start <= range.upperBound }
        let isAnchored = { (entry: HLSTimeline.Entry) in anchors.isAnchored(entry.segment.discontinuitySequence) }
        guard let first = ahead.first(where: isAnchored) else { return nil }
        let lower = max(range.lowerBound, first.start)
        var upper = range.upperBound
        var limit = upper
        if let stop = ahead.first(where: { $0.start > first.start && !isAnchored($0) }) {
            upper = min(upper, stop.start)
            limit = stop.start.nextDown
        }
        return lower <= upper ? (lower...upper, limit) : nil
    }
}
