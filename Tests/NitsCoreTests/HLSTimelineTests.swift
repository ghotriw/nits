import Foundation
import Testing

@testable import NitsCore

/// `HLSTimeline`: a rendition's segments on the playlist's timeline, live reloads merged by media sequence, and other
/// renditions aligned to it.
@Suite("HLS timeline")
struct HLSTimelineTests {
    static let base = URL(string: "https://cdn.example.com/live/index.m3u8")!
    static let noon = HLSPlaylist.date("2026-11-10T12:00:00Z")!

    /// A media playlist of `durations` from media sequence `sequence`; `discontinuities` are the indices of segments
    /// a discontinuity comes before; `dated` gives the first segment a date that many seconds after noon.
    static func playlist(
        _ durations: [Double], sequence: Int = 0, discontinuitySequence: Int? = nil, discontinuities: Set<Int> = [],
        dated: Double? = nil, type: String? = nil, ended: Bool = false, name: String = "s"
    ) throws -> HLSMediaPlaylist {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:\(sequence)\n"
        if let discontinuitySequence { text += "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)\n" }
        if let type { text += "#EXT-X-PLAYLIST-TYPE:\(type)\n" }
        for (index, duration) in durations.enumerated() {
            if discontinuities.contains(index) { text += "#EXT-X-DISCONTINUITY\n" }
            if index == 0, let dated {
                text += "#EXT-X-PROGRAM-DATE-TIME:\(noon.addingTimeInterval(dated).ISO8601Format())\n"
            }
            text += "#EXTINF:\(duration),\n\(name)\(sequence + index).ts\n"
        }
        if ended { text += "#EXT-X-ENDLIST\n" }
        guard case .media(let playlist) = try HLSPlaylist.parse(text, url: base) else {
            throw HLSPlaylistError.mixedTypes
        }
        return playlist
    }

    @Test("Segments start where the one before ends, from zero; lookup by time and by sequence")
    func placesSegments() throws {
        let timeline = HLSTimeline(try Self.playlist([6, 6, 0, 4.5], sequence: 10, type: "VOD", ended: true))
        #expect(timeline.entries.map(\.start) == [0, 6, 12, 12])
        #expect(timeline.end == 16.5 && timeline.liveWindow == nil && timeline.hasEnded)
        #expect(timeline.index(at: -1) == 0 && timeline.index(at: 0) == 0 && timeline.index(at: 5.99) == 0)
        // On a boundary: the segment that starts there, not one of no duration.
        #expect(timeline.index(at: 6) == 1 && timeline.index(at: 12) == 3)
        // The very end is the last segment's; past it, none.
        #expect(timeline.index(at: 16.5) == 3 && timeline.index(at: 16.6) == nil)
        #expect(timeline.entry(sequence: 11)?.start == 6 && timeline.entry(sequence: 9) == nil)
        #expect(timeline.entry(sequence: 14) == nil)
        #expect(timeline.next(after: timeline.entries[0]) == .entry(timeline.entries[1]))
        #expect(timeline.next(after: timeline.entries[3]) == .ended)
    }

    // MARK: Measured starts

    private static func url(_ sequence: Int) -> URL { URL(string: "s\(sequence).ts", relativeTo: base)!.absoluteURL }

    @Test("A measured start moves the entries around it as listed; the rest of the playlist keeps its durations")
    func measureMovesNeighbours() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6, 6, 6], ended: true))
        let applied1 = timeline.measure(sequence: 2, url: Self.url(2), byteRange: nil, start: 12.5)
        #expect(applied1)
        #expect(timeline.entries.map(\.start) == [0.5, 6.5, 12.5, 18.5])
        #expect(timeline.entries.map(\.isMeasured) == [false, false, true, false])
        #expect(timeline.index(at: 12.2) == 1 && timeline.index(at: 12.5) == 2)
        // A start the timeline already has changes nothing, a rounding of a millisecond either.
        let applied2 = timeline.measure(sequence: 2, url: Self.url(2), byteRange: nil, start: 12.5004)
        #expect(!applied2)
        #expect(timeline.entries.map(\.start) == [0.5, 6.5, 12.5, 18.5])
    }

    @Test("Between two measured entries the durations are scaled to fit: integer EXTINFs of 6.006 s segments")
    func measureSpreadsDrift() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6, 6, 6, 6], ended: true))
        _ = timeline.measure(sequence: 0, url: Self.url(0), byteRange: nil, start: 0)
        let applied4 = timeline.measure(sequence: 4, url: Self.url(4), byteRange: nil, start: 24.024)
        #expect(applied4)
        let starts = timeline.entries.map(\.start)
        #expect(zip(starts, [0, 6.006, 12.012, 18.018, 24.024]).allSatisfy { abs($0 - $1) < 1e-9 })
        // Contiguous, and the end follows the last measured start as listed.
        #expect(abs(timeline.entries[3].end - timeline.entries[4].start) < 1e-9)
        #expect(timeline.entry(at: 18.0)?.sequence == 2 && timeline.entry(at: 18.02)?.sequence == 3)
    }

    @Test(
        "A measure that doesn't fit is refused: another address, a jump past a target duration, a span scaled by more than double"
    )
    func measureRefusals() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6, 6], ended: true))
        let before = timeline.entries
        let applied5 = timeline.measure(sequence: 1, url: Self.url(7), byteRange: nil, start: 6.5)
        #expect(!applied5)
        let applied6 = timeline.measure(sequence: 1, url: Self.url(1), byteRange: nil, start: 6 + 7)
        #expect(!applied6)
        let applied7 = timeline.measure(sequence: 5, url: Self.url(5), byteRange: nil, start: 30)
        #expect(!applied7)
        #expect(timeline.entries == before)
        _ = timeline.measure(sequence: 0, url: Self.url(0), byteRange: nil, start: 0)
        // The span from 0 to 2's start would be 1 s for 12 s listed.
        let applied9 = timeline.measure(sequence: 2, url: Self.url(2), byteRange: nil, start: 1)
        #expect(!applied9)
        #expect(timeline.entries.map(\.start) == [0, 6, 12])
    }

    @Test("A reload keeps the measured places and durations; after a restart an old entry is not found by number")
    func measureSurvivesReload() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 10, ended: false))
        let applied10 = timeline.measure(sequence: 11, url: Self.url(11), byteRange: nil, start: 6.2)
        #expect(applied10)
        let read = try #require(timeline.entry(sequence: 11))
        #expect(timeline.reload(try Self.playlist([6, 6, 6, 6], sequence: 11)) == .updated(added: 2, expired: 1))
        #expect(timeline.entry(sequence: 11)?.start == 6.2 && timeline.entry(sequence: 11)?.isMeasured == true)
        #expect(timeline.entry(sequence: 14)?.start == 6.2 + 18)
        // Read before the window moved: still the same place, so what follows is by number.
        #expect(timeline.next(after: read) == .entry(try #require(timeline.entry(sequence: 12))))
        // A restart numbers its segments again: an entry of the run before is not found by number.
        let old = try #require(timeline.entry(sequence: 12))
        timeline.restart(try Self.playlist([6, 6], sequence: 12))
        #expect(timeline.entries.first?.epoch == 1)
        guard case .expired(let next) = timeline.next(after: old) else {
            Issue.record("the old run's entry was found by number in the new run")
            return
        }
        #expect(next.epoch == 1)
    }

    @Test("A segment of no duration at the end gives way to the one before")
    func zeroDurationAtEnd() throws {
        let timeline = HLSTimeline(try Self.playlist([6, 0], ended: true))
        #expect(timeline.index(at: 6) == 0)
        // At the start, the first that has a duration.
        let leading = HLSTimeline(try Self.playlist([0, 0, 6], ended: true))
        #expect(leading.index(at: -1) == 2 && leading.index(at: 0) == 2 && leading.index(at: 3) == 2)
    }

    @Test("A live reload keeps the places of segments listed again, adds the new, expires the dropped")
    func reloadSlides() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 100))
        let firstLoad = timeline.entries
        #expect(timeline.liveWindow == LiveWindow(start: 0, end: 18, hasSlid: true, hasEnded: false))
        #expect(timeline.reload(try Self.playlist([6, 6, 6], sequence: 100)) == .unchanged)
        // A re-listed segment's duration changed: its place stays as first loaded.
        #expect(timeline.reload(try Self.playlist([6, 6.5, 4, 6], sequence: 101)) == .updated(added: 2, expired: 1))
        #expect(timeline.entries.map(\.sequence) == [101, 102, 103, 104])
        #expect(timeline.entries.map(\.start) == [6, 12, 18, 22])
        // 100 left the window: what follows it, by time, is 101.
        #expect(timeline.next(after: firstLoad[0]) == .entry(timeline.entries[0]))
        #expect(timeline.next(after: firstLoad[1]) == .entry(timeline.entries[1]))
        // Read before 100: 100 expired unread.
        #expect(timeline.next(after: Self.entry(99, start: -6)) == .expired(resumingAt: timeline.entries[0]))
        #expect(timeline.next(after: timeline.entries[3]) == .pending)
        #expect(timeline.liveWindow == LiveWindow(start: 6, end: 28, hasSlid: true, hasEnded: false))
        // The stream ends: the window stays live, ended.
        #expect(
            timeline.reload(try Self.playlist([4, 6], sequence: 103, ended: true)) == .updated(added: 0, expired: 2))
        #expect(timeline.liveWindow == LiveWindow(start: 18, end: 28, hasSlid: true, hasEnded: true))
        #expect(timeline.next(after: timeline.entries[1]) == .ended)
    }

    @Test("An event playlist, or one from sequence zero, hasn't slid until it drops a segment")
    func slideFromStart() throws {
        var event = HLSTimeline(try Self.playlist([6, 6], sequence: 3, type: "EVENT"))
        #expect(event.liveWindow?.hasSlid == false && event.beganAtStreamStart)
        event.reload(try Self.playlist([6, 6, 6], sequence: 3, type: "EVENT"))
        #expect(event.liveWindow?.hasSlid == false && event.end == 18)

        var growing = HLSTimeline(try Self.playlist([6], sequence: 0))
        #expect(growing.liveWindow?.hasSlid == false)
        growing.reload(try Self.playlist([6, 6], sequence: 1))
        #expect(growing.liveWindow == LiveWindow(start: 6, end: 18, hasSlid: true, hasEnded: false))
    }

    @Test("A reload too late to match a segment: placed after the old end, the missed segments by count or by date")
    func reloadMissed() throws {
        var byCount = HLSTimeline(try Self.playlist([6, 6], sequence: 10))
        // 12 and 13 were missed: two target durations.
        #expect(byCount.reload(try Self.playlist([6, 6], sequence: 14)) == .restarted(gap: 12))
        #expect(byCount.entries.map(\.start) == [24, 30])

        var byDate = HLSTimeline(try Self.playlist([6, 6], sequence: 10, dated: 0))
        // The new first is dated 20 s after the old first, which ended 6 s after the old last's date (6).
        #expect(byDate.reload(try Self.playlist([6], sequence: 14, dated: 20)) == .restarted(gap: 8))
        #expect(byDate.entries.map(\.start) == [20])

        // Dates gone back with numbers gone on (a clock set back): counted by number.
        var clockBack = HLSTimeline(try Self.playlist([6, 6], sequence: 10, dated: 600))
        #expect(clockBack.reload(try Self.playlist([6], sequence: 13, dated: 0)) == .restarted(gap: 6))
    }

    @Test("Right after the window, nothing missed: the stream goes on, no new run")
    func reloadRightAfter() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6], sequence: 10, discontinuitySequence: 2))
        #expect(
            timeline.reload(try Self.playlist([6, 6], sequence: 12, discontinuitySequence: 2))
                == .updated(added: 2, expired: 2))
        #expect(timeline.entries.map(\.start) == [12, 18])
        #expect(timeline.entries.map(\.segment.isDiscontinuity) == [false, false])
        #expect(timeline.entries.map(\.segment.discontinuitySequence) == [2, 2])
    }

    @Test(
        "After segments were missed the new ones start a run of their own, numbered as a server that says its sequence numbers them"
    )
    func lateReloadStartsRun() throws {
        // The numbers the server says are the stream's, which the other playlists share: kept.
        var declared = HLSTimeline(try Self.playlist([6, 6], sequence: 10, discontinuitySequence: 2))
        declared.reload(try Self.playlist([6, 6], sequence: 20, discontinuitySequence: 3))
        #expect(declared.entries.map(\.segment.discontinuitySequence) == [3, 3])
        #expect(declared.entries.map(\.segment.isDiscontinuity) == [true, false])
        var same = HLSTimeline(try Self.playlist([6, 6], sequence: 10, discontinuitySequence: 2))
        same.reload(try Self.playlist([6, 6], sequence: 20, discontinuitySequence: 2))
        #expect(same.entries.map(\.segment.discontinuitySequence) == [2, 2])
        #expect(same.entries.map(\.segment.isDiscontinuity) == [true, false])
        // Going back is no number of the stream's: one after the old run.
        var back = HLSTimeline(try Self.playlist([6, 6], sequence: 10, discontinuitySequence: 2))
        back.reload(try Self.playlist([6, 6], sequence: 20, discontinuitySequence: 1))
        #expect(back.entries.map(\.segment.discontinuitySequence) == [3, 3])
        // A server that doesn't say it: a discontinuity after the old run, as missed segments may have held one.
        var counted = HLSTimeline(try Self.playlist([6, 6], sequence: 10, discontinuities: [1]))
        counted.reload(try Self.playlist([6, 6], sequence: 20))
        #expect(counted.entries.map(\.segment.discontinuitySequence) == [2, 2])
    }

    @Test("Missed segments are counted at the target they were served under, and not past an hour (a renumbering)")
    func lateReloadBounds() throws {
        var retargeted = HLSTimeline(try Self.playlist([6, 6], sequence: 10))
        var longer = try Self.playlist([10], sequence: 15)
        longer.targetDuration = 10
        // 12…14 were served under a target of 6.
        #expect(retargeted.reload(longer) == .restarted(gap: 18))
        #expect(retargeted.targetDuration == 10)

        var renumbered = HLSTimeline(try Self.playlist([6, 6], sequence: 500))
        #expect(renumbered.reload(try Self.playlist([6], sequence: 1_700_000_000)) == .restarted(gap: 0))
        #expect(renumbered.entries.map(\.start) == [12])

        // By date too: a clock that jumped a day isn't a day missed.
        var jumped = HLSTimeline(try Self.playlist([6, 6], sequence: 10, dated: 0))
        #expect(jumped.reload(try Self.playlist([6], sequence: 14, dated: 86_400)) == .restarted(gap: 0))
        #expect(jumped.entries.map(\.start) == [12])
    }

    @Test("Not newer than the window (ExoPlayer's rule) is stale; wholly behind it, a reset; neither is merged")
    func staleAndReset() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6, 6, 6], sequence: 10))
        let before = timeline.entries
        // An earlier first segment: stale, even when it lists the window's last (or more before it).
        #expect(timeline.reload(try Self.playlist([6, 6, 6], sequence: 8)) == .stale)
        #expect(timeline.reload(try Self.playlist([4, 6, 6, 6, 6], sequence: 9)) == .stale)
        // The same first with fewer segments: stale.
        #expect(timeline.reload(try Self.playlist([6, 6], sequence: 10)) == .stale)
        // Wholly behind: a reset; a restart near zero reads the same, by the playlist alone.
        #expect(timeline.reload(try Self.playlist([6, 6], sequence: 0)) == .reset)
        #expect(timeline.entries == before)
        // Taken as a restart by the caller: a run of its own after the old last.
        #expect(timeline.restart(try Self.playlist([6, 6], sequence: 0)) == .restarted(gap: 0))
        #expect(timeline.entries.map(\.start) == [24, 30] && timeline.entries[0].segment.isDiscontinuity)
    }

    @Test("A reload that only ends the playlist is a change")
    func endingIsAChange() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6], sequence: 10))
        #expect(
            timeline.reload(try Self.playlist([6, 6], sequence: 10, ended: true)) == .updated(added: 0, expired: 0))
        var empty = HLSTimeline(try Self.playlist([], sequence: 10))
        #expect(empty.reload(try Self.playlist([], sequence: 10, ended: true)) == .updated(added: 0, expired: 0))
    }

    @Test("A restart taken by the caller: a discontinuity after the old end, numbered after the old run")
    func restart() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6], sequence: 500, discontinuitySequence: 4))
        let old = timeline.entries
        #expect(timeline.reload(try Self.playlist([6, 6], sequence: 0)) == .reset)
        #expect(timeline.restart(try Self.playlist([6, 6], sequence: 0)) == .restarted(gap: 0))
        #expect(timeline.entries.map(\.start) == [12, 18])
        #expect(timeline.entries.map(\.segment.isDiscontinuity) == [true, false])
        #expect(timeline.entries.map(\.segment.discontinuitySequence) == [5, 5])
        // A reader goes on into the restart from the old last, by time; one behind it skips to it.
        #expect(timeline.next(after: old[1]) == .entry(timeline.entries[0]))
        #expect(timeline.next(after: old[0]) == .expired(resumingAt: timeline.entries[0]))
        // Reloads after it keep the numbers.
        timeline.reload(try Self.playlist([6, 6, 6], sequence: 0))
        #expect(timeline.entries.map(\.segment.discontinuitySequence) == [5, 5, 5])
        #expect(timeline.next(after: old[1]) == .entry(timeline.entries[0]))
        #expect(timeline.next(after: timeline.entries[0]) == .entry(timeline.entries[1]))
    }

    @Test("A server that doesn't keep the discontinuity sequence: numbers follow those matched")
    func discontinuitySequenceKept() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 10, discontinuities: [1]))
        #expect(timeline.entries.map(\.segment.discontinuitySequence) == [0, 1, 1])
        // The discontinuity left the window, the server still says 0.
        timeline.reload(try Self.playlist([6, 6, 6], sequence: 11))
        #expect(timeline.entries.map(\.segment.discontinuitySequence) == [1, 1, 1])
        // A server that keeps it changes nothing.
        var kept = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 10, discontinuities: [1]))
        kept.reload(try Self.playlist([6, 6, 6], sequence: 11, discontinuitySequence: 1))
        #expect(kept.entries.map(\.segment.discontinuitySequence) == [1, 1, 1])
    }

    @Test("An empty live playlist fills on reload from where the timeline starts")
    func emptyThenFilled() throws {
        var timeline = HLSTimeline(try Self.playlist([], sequence: 7), start: 30)
        #expect(timeline.isEmpty && timeline.liveWindow?.start == 30)
        #expect(timeline.next(after: Self.entry(6, start: 24)) == .pending)
        #expect(timeline.reload(try Self.playlist([], sequence: 7)) == .unchanged)
        #expect(timeline.reload(try Self.playlist([6], sequence: 7)) == .updated(added: 1, expired: 0))
        #expect(timeline.entries.map(\.start) == [30])
    }

    @Test("A segment listed again takes the new playlist's address (signed anew), keeping its place")
    func relistedTakesNewAddress() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6], sequence: 10, name: "old"))
        let read = timeline.entries[0]
        timeline.reload(try Self.playlist([6, 6, 6], sequence: 10, name: "new"))
        #expect(timeline.entries.map(\.segment.url.lastPathComponent) == ["new10.ts", "new11.ts", "new12.ts"])
        #expect(timeline.entries.map(\.start) == [0, 6, 12])
        // A reader that read the old description goes on by number.
        #expect(timeline.next(after: read) == .entry(timeline.entries[1]))
        // The same segments, re-signed: merged, unchanged.
        #expect(timeline.reload(try Self.playlist([6, 6, 6], sequence: 10, name: "newer")) == .unchanged)
        #expect(timeline.entries[0].segment.url.lastPathComponent == "newer10.ts")
    }

    @Test("Dates that disagree for the same numbers are no restart: a clock correction keeps the window going")
    func datesDontRestart() throws {
        var timeline = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 100, dated: 0))
        #expect(
            timeline.reload(try Self.playlist([6, 6, 6], sequence: 101, dated: 3606)) == .updated(added: 1, expired: 1))
        #expect(timeline.entries.map(\.start) == [6, 12, 18])
    }

    @Test("A live playlist first loaded empty is told how it began by its first segments")
    func emptyFirstLoadThenSlid() throws {
        var timeline = HLSTimeline(try Self.playlist([], sequence: 0))
        #expect(timeline.beganAtStreamStart)
        timeline.reload(try Self.playlist([6, 6], sequence: 5000))
        #expect(!timeline.beganAtStreamStart && timeline.liveWindow?.hasSlid == true)
    }

    // MARK: Alignment

    @Test("Finished renditions align at the start, whatever their media sequence numbers")
    func alignsFinished() throws {
        try alignsFinishedFromStart()
    }

    @Test("A finished live window that had slid isn't from the stream's start: renditions align at the end")
    func alignsEndedLiveWindow() throws {
        let video = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 100, ended: true), start: 50)
        #expect(!video.beganAtStreamStart && video.streamStart == nil)
        let audio = HLSTimeline(
            try Self.playlist([4, 4, 4, 4, 4, 4], sequence: 98, ended: true, name: "a"), testAlignedTo: video,
            sharesSequenceNumbers: false)
        #expect(audio.end == video.end && audio.start == 44)
    }

    @Test("A rendition from the stream's start aligns where the reference's stream started, after it slid")
    func alignsAtStreamStartAfterSlide() throws {
        var video = HLSTimeline(try Self.playlist([6, 6], sequence: 0), start: 10)
        video.reload(try Self.playlist([6, 6], sequence: 1))
        #expect(video.hasSlid && video.start == 16 && video.streamStart == 10)
        let subtitles = HLSTimeline(
            try Self.playlist([6, 6, 6], type: "VOD", ended: true, name: "t"), testAlignedTo: video,
            sharesSequenceNumbers: false)
        #expect(subtitles.start == 10)
    }

    private func alignsFinishedFromStart() throws {
        let video = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 0, ended: true))
        let audio = HLSTimeline(
            try Self.playlist([5.97, 6, 6], sequence: 1, ended: true, name: "a"), testAlignedTo: video,
            sharesSequenceNumbers: false)
        #expect(audio.start == 0)
    }

    @Test("Live renditions align by date first")
    func alignsByDate() throws {
        var video = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 100, dated: 0))
        video.reload(try Self.playlist([6, 6, 6], sequence: 101, dated: 6))
        // Numbered otherwise, dated 3 s into the video's 102 (at 12 on the timeline).
        let audio = HLSTimeline(
            try Self.playlist([4, 4], sequence: 7, dated: 15, name: "a"), testAlignedTo: video,
            sharesSequenceNumbers: false
        )
        #expect(audio.start == 15)
        // Starting before the video's first dated segment: against that one, earlier.
        let early = HLSTimeline(
            try Self.playlist([4, 4], sequence: 7, dated: 4, name: "a"), testAlignedTo: video,
            sharesSequenceNumbers: false)
        #expect(early.start == 4)
        let earlier = HLSTimeline(
            try Self.playlist([4, 4], sequence: 7, dated: 1, name: "a"), testAlignedTo: video,
            sharesSequenceNumbers: false)
        #expect(earlier.start == 1)
    }

    @Test("Live renditions without dates: a variant aligns by media sequence; another rendition at the live edge")
    func alignsBySequenceOrEdge() throws {
        let video = HLSTimeline(try Self.playlist([6, 6, 6], sequence: 100), start: 50)
        let variant = HLSTimeline(
            try Self.playlist([6, 6, 6, 6], sequence: 101, name: "v"), testAlignedTo: video, sharesSequenceNumbers: true
        )
        #expect(variant.start == 56)
        // Numbered as the video, but its segments are other spans: the number says nothing.
        let audio = HLSTimeline(
            try Self.playlist([4, 4, 4], sequence: 100, name: "a"), testAlignedTo: video, sharesSequenceNumbers: false)
        #expect(audio.end == video.end && audio.start == 56)
    }

    /// An entry read before, of `sequence`, from `start`.
    static func entry(_ sequence: Int, start: Double, duration: Double = 6) -> HLSTimeline.Entry {
        HLSTimeline.Entry(
            segment: HLSSegment(
                url: base.appending(path: "s\(sequence).ts"), duration: duration, sequence: sequence,
                discontinuitySequence: 0),
            start: start)
    }
}

extension HLSTimeline {
    /// `init(_:alignedTo:sharesSequenceNumbers:)` for a playlist the test knows lists segments.
    init(_ playlist: HLSMediaPlaylist, testAlignedTo reference: HLSTimeline, sharesSequenceNumbers: Bool) {
        guard let timeline = HLSTimeline(playlist, alignedTo: reference, sharesSequenceNumbers: sharesSequenceNumbers)
        else { preconditionFailure("an empty playlist or reference") }
        self = timeline
    }
}
