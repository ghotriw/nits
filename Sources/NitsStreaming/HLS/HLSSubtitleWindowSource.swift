import CFFmpeg
import Foundation

/// What a read of a subtitle rendition outside playback needs (`EmbeddedSubtitleReader.readSubtitles(hls:in:interrupt:)`):
/// the rendition's playlist as the opening placed it on the timeline, the offsets the playback's pictures anchored
/// (shared, thread-safe) and how to reach the server. Immutable once made; a live stream has none (its window moves, and
/// playback reads it from the edge).
package struct HLSSubtitleWindowSource: Sendable {
    /// The address the stream was opened by, and the headers its requests carry: the reader makes a transport of its own.
    package let address: String
    package let headers: [String: String]
    package let allowsFiles: Bool
    package let url: URL
    package let timeline: HLSTimeline
    package let variables: [String: String]
    /// Where the stream's playlists come from, as the opening read them.
    package let playlists: any HLSPlaylistSource
    package let anchors: HLSTimestampAnchors
    /// The cookies the stream's own session holds (the master's answer set them), which the read's session takes over.
    package let cookies: @Sendable () -> [HTTPCookie]
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
    package func readable(in range: ClosedRange<Double>) -> (range: ClosedRange<Double>, limit: Double)? {
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

extension HLSSubtitleWindowSource {
    /// How a read of the rendition's cues ended.
    package enum WindowRead {
        /// Nothing in the range can be read yet (`readable(in:)`).
        case unreadable
        /// What was read, up to `covered`: to the end of the range, or to a break the pictures have not anchored.
        case read(covered: ClosedRange<Double>)
        /// The read was cancelled, or the lane gave an error up.
        case failed
    }

    /// Reads the cues within `range` of the timeline (`upperBound` may be `infinity`: the whole rendition) by a lane of its
    /// own: its own transport (the requests are no sample for adaptive bitrate, and give way to `shouldAbort`; `isCancelled` ends the read), the
    /// playlist and the offsets the stream's pictures anchored. The run starts at the segment that holds the lower bound
    /// and stops at the first cue past the upper, and loads no segment that starts after it (a stretch without cues is not
    /// read to its next cue). A segment that fails is skipped, as in playback (and counts as read). Each packet read is
    /// handed to `packet` (timestamps in milliseconds, stream 0), which must not keep it.
    package func read(
        in range: ClosedRange<Double>, shouldAbort: @escaping @Sendable () -> Bool, isCancelled: () -> Bool,
        packet: (inout AVPacket) -> Void
    ) -> WindowRead {
        guard let readable = readable(in: range) else { return .unreadable }
        let covered = readable.range
        let limit = readable.limit
        let timebase = AVRational(num: 1, den: 1000)
        let transport = HTTPSessionTransport(source: address, headers: headers, shouldAbort: shouldAbort)
        transport.adopt(cookies())
        let loader = SegmentLoader(transport: transport, allowsFiles: allowsFiles)
        let lane = HLSLane(
            kind: .subtitle, url: url, timeline: timeline, variables: variables, playlists: playlists, loader: loader,
            anchors: anchors, shouldAbort: shouldAbort)
        defer { lane.close() }
        lane.setStreams([HLSLane.StreamSlot(table: 0, timebase: timebase, type: AVMEDIA_TYPE_SUBTITLE)])
        lane.reposition(at: covered.lowerBound)
        var pkt = AVPacket()
        while !isCancelled() {
            let code = lane.fill(before: limit.isFinite ? limit : nil)
            if code == FFmpegErrorCode.eof || code == HLSLane.held {
                return isCancelled() ? .failed : .read(covered: covered)
            }
            guard code >= 0 else { return .failed }
            if lane.pendingTime > covered.upperBound { return .read(covered: covered) }
            lane.take(into: &pkt)
            packet(&pkt)
            av_packet_unref(&pkt)
        }
        return .failed
    }
}
