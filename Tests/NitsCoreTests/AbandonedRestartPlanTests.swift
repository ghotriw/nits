import Foundation
import Testing

@testable import NitsCore

/// What is done with the queued part of a segment whose download was given up, when the old variant reads it again
/// (`MediaDemuxer.restartPlan`): the pictures are cut at a keyframe, so the decoder does not get the same times twice, and
/// the segment is read from its start or, with its start handed out already, from the keyframe the cut is at.
@Suite("Reading a download given up again")
struct AbandonedRestartPlanTests {
    private static let perSecond = 90_000.0
    private static let slack = Int64(0.1 * perSecond)

    private static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * perSecond).rounded()) }

    /// The segment starts at 6 s; GOPs of 1 s, so a keyframe at 6, 7 (inside it) and 8 (the next segment's).
    private func plan(
        keyframes: [Double], isStartHandedOut: Bool = false, sound: Double? = nil
    ) -> MediaDemuxer.AbandonedRestart {
        MediaDemuxer.restartPlan(
            start: Self.ticks(6), slack: Self.slack,
            keyframes: keyframes.enumerated().map { (index: 100 + $0.offset, pts: Self.ticks($0.element)) },
            isStartHandedOut: isStartHandedOut, soundHandedOut: sound.map(Self.ticks))
    }

    @Test("With the segment's own start queued, it is the cut, and the segment is read from its start")
    func cutsAtTheStart() {
        #expect(plan(keyframes: [6, 7]) == .cut(index: 100, atStart: true))
        // The media's start is a little off the timeline's.
        #expect(plan(keyframes: [6.05, 7]) == .cut(index: 100, atStart: true))
        #expect(plan(keyframes: [5.95, 7]) == .cut(index: 100, atStart: true))
    }

    @Test("A GOP shorter than the segment: the start handed out, a later keyframe is a landing, not the start")
    func laterKeyframeIsALanding() {
        // The keyframe at 6 is handed out, the one at 7 is queued: cutting there and reading from 6 would queue [6, 7) twice.
        #expect(plan(keyframes: [7], isStartHandedOut: true) == .cut(index: 100, atStart: false))
        #expect(
            plan(keyframes: [7, 8]) == .cut(index: 100, atStart: false),
            "Whether or not the clock says it is handed out")
    }

    @Test("A keyframe before the segment is no part of it")
    func ignoresWhatIsBefore() {
        // The segment before is still queued (a keyframe at 5), none of this one: nothing of it to cut.
        #expect(plan(keyframes: [4, 5]) == .fromStart)
        #expect(plan(keyframes: [4, 5], isStartHandedOut: true) == .nextSegment)
    }

    @Test("Sound handed out past the start moves the cut after it")
    func soundMovesTheCut() {
        // Muxed sound is handed out to 6.4 s: the keyframe at 6 would leave it read again over what is handed out.
        #expect(plan(keyframes: [6, 7], sound: 6.4) == .cut(index: 101, atStart: false))
        // Handed out to before the segment: no constraint.
        #expect(plan(keyframes: [6, 7], sound: 5.0) == .cut(index: 100, atStart: true))
        // Past every keyframe queued: nothing left to cut at.
        #expect(plan(keyframes: [6, 7], sound: 7.5) == .nextSegment)
    }

    @Test("Nothing queued of the segment: from its start, or after it when playback has got to it")
    func nothingQueued() {
        #expect(plan(keyframes: []) == .fromStart)
        #expect(plan(keyframes: [], isStartHandedOut: true) == .nextSegment)
        #expect(plan(keyframes: [], sound: 6.2) == .nextSegment, "The sound is in the segment")
    }
}
