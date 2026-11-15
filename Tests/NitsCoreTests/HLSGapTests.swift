import Foundation
import Testing
import os

@testable import NitsCore
@testable import NitsStreaming

/// A segment marked `EXT-X-GAP` is never requested: a lane starts, or goes on, at the segment after it.
@Suite("HLS gaps")
struct HLSGapTests {
    private static let url = URL(string: "https://example.com/a.m3u8")!

    /// A lane over four segments of 4 s, of which `gaps` (indices) are marked; `abort` is what its waits give way to.
    private static func lane(
        gaps: Set<Int>, hasEnded: Bool = true, abort: OSAllocatedUnfairLock<Bool> = .init(initialState: false)
    ) throws -> HLSLane {
        let segments = (0..<4).map { index in
            "\(gaps.contains(index) ? "#EXT-X-GAP\n" : "")#EXTINF:4,\nsegment\(index).ts\n"
        }.joined()
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n\(segments)\(hasEnded ? "#EXT-X-ENDLIST\n" : "")"
        guard case .media(let playlist) = try HLSPlaylist.parse(text, url: url) else { throw CancellationError() }
        return HLSLane(
            kind: .audio, url: url, timeline: HLSTimeline(playlist), variables: [:], playlists: HLSServedPlaylists(),
            loader: HLSSegmentLoader(
                transport: HTTPSessionTransport(source: url.absoluteString, headers: [:]) { false }),
            anchors: HLSTimestampAnchors(), shouldAbort: { abort.withLock { $0 } })
    }

    @Test("A gap at the start, in the middle or at the end: the segment read is the first that is not one")
    func readableSkipsGaps() throws {
        let leading = try Self.lane(gaps: [0, 1])
        #expect(leading.readable(try #require(leading.timeline.entry(at: 1))).entry?.sequence == 2)
        #expect(leading.readable(try #require(leading.timeline.entry(at: 9))).entry?.sequence == 2)

        let middle = try Self.lane(gaps: [1, 2])
        #expect(middle.readable(try #require(middle.timeline.entry(at: 0))).entry?.sequence == 0)
        #expect(middle.readable(try #require(middle.timeline.entry(at: 5))).entry?.sequence == 3)
    }

    @Test("Only gaps to the end: a finished playlist has nothing to read, a live one may get more")
    func readableAtTheEnd() throws {
        let finished = try Self.lane(gaps: [2, 3])
        #expect(finished.readable(try #require(finished.timeline.entry(at: 1))).entry?.sequence == 0)
        #expect(finished.readable(try #require(finished.timeline.entry(at: 9))) == .ended)

        let live = try Self.lane(gaps: [2, 3], hasEnded: false)
        let edge = try #require(live.timeline.entry(at: 9))
        // The last of the gaps, where the playlist is waited on.
        #expect(live.readable(edge) == .pending(after: try #require(live.timeline.entry(sequence: 3))))
    }

    @Test("A lane started in the gaps that end a finished playlist is finished: no request, the end")
    func startInTrailingGaps() throws {
        let lane = try Self.lane(gaps: [2, 3])
        #expect(throws: HLSSegmentReaderError.self) { try lane.open(at: 10) }
        #expect(throws: HLSSegmentReaderError.self) { try lane.probe(at: 10) }
        lane.reposition(at: 10)
        // A gap asked for would fail to load and be skipped (a code of failure, not the end).
        #expect(lane.fill() == FFmpegErrorCode.eof)
    }

    @Test("A lane started in the gaps at a live edge waits for the segments to come, and is not finished")
    func startInGapsAtALiveEdge() throws {
        let abort = OSAllocatedUnfairLock(initialState: false)
        let lane = try Self.lane(gaps: [2, 3], hasEnded: false, abort: abort)
        lane.reposition(at: 10)
        // It waits for the playlist to be loaded again (until the abort here): not the end (eof), nor a failure.
        abort.withLock { $0 = true }
        #expect(lane.fill() == FFmpegErrorCode.exit)
    }
}
