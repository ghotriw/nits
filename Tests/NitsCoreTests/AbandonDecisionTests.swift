import Foundation
import Testing

@testable import NitsCore

/// What the check of a download does once the rule gives it up (`MediaDemuxer.noteSegmentInFlight`): where the cut would
/// be against the position (`abandonPlace`), and which outcomes decide the segment for good (`AbandonmentLog`).
@Suite("Deciding on a download given up")
struct AbandonDecisionTests {
    /// The segment is [6, 12) s.
    private func place(
        cursor: Double, keyframes: [Double] = [], muxedSound: Double? = nil
    ) -> MediaDemuxer.AbandonPlace {
        MediaDemuxer.abandonPlace(
            start: 6, duration: 6, cursor: cursor, keyframes: keyframes, muxedSoundHandedOut: muxedSound)
    }

    @Test("A segment at or after the position is cut at its start, whatever is queued")
    func ahead() {
        #expect(place(cursor: 4) == .ahead)
        #expect(place(cursor: 6) == .ahead)
        #expect(place(cursor: 5, keyframes: [6, 8], muxedSound: 7) == .ahead)
    }

    @Test("Inside the segment, the first keyframe of it queued is the cut")
    func insideAtAQueuedKeyframe() {
        #expect(place(cursor: 7, keyframes: [8, 10]) == .inside(keyframe: 8))
        // A keyframe of the segment before (still queued, not handed out) is no cut of this one.
        #expect(place(cursor: 6.5, keyframes: [5, 8]) == .inside(keyframe: 8))
    }

    @Test("Inside the segment with no keyframe of it queued: nothing to cut at")
    func insideWithoutKeyframe() {
        #expect(place(cursor: 7) == .insideWithoutKeyframe)
        // Only the next segment's keyframe is queued.
        #expect(place(cursor: 7, keyframes: [12]) == .insideWithoutKeyframe)
    }

    @Test("Sound muxed into the old variant and handed out to a keyframe or past it moves the cut after it")
    func muxedSoundMovesTheCut() {
        #expect(place(cursor: 7, keyframes: [8, 10], muxedSound: 8.3) == .inside(keyframe: 10))
        #expect(place(cursor: 7, keyframes: [8, 10], muxedSound: 8) == .inside(keyframe: 10), "its packet at 8 is out")
        #expect(place(cursor: 7, keyframes: [8, 10], muxedSound: 7.9) == .inside(keyframe: 8))
        #expect(place(cursor: 7, keyframes: [8, 10], muxedSound: 10.5) == .insideWithoutKeyframe)
    }

    @Test("A download given up and read again is checked again")
    func reopensWhatIsReadAgain() {
        var log = MediaDemuxer.AbandonmentLog()
        _ = log.record(.requested, variant: 2, sequence: 5)
        log.reopen(variant: 2, sequence: 4)
        #expect(log.isDecided(variant: 2, sequence: 5), "another segment's restart leaves it")
        log.reopen(variant: 2, sequence: 5)
        #expect(!log.isDecided(variant: 2, sequence: 5))
    }

    @Test("A segment is decided when given up or refused for good; a passing refusal is asked again, logged once")
    func passingRefusalsAreAskedAgain() {
        var log = MediaDemuxer.AbandonmentLog()
        #expect(!log.isDecided(variant: 2, sequence: 5))

        let first = log.record(.refused(.switchUnderWay), variant: 2, sequence: 5)
        #expect(first)
        #expect(!log.isDecided(variant: 2, sequence: 5))
        let again = log.record(.refused(.switchUnderWay), variant: 2, sequence: 5)
        #expect(!again, "the same refusal is logged once")
        let another = log.record(.refused(.noKeyframeQueued), variant: 2, sequence: 5)
        #expect(another, "another one is logged")
        let nextSegment = log.record(.refused(.noKeyframeQueued), variant: 2, sequence: 6)
        #expect(nextSegment, "so is the next segment's")

        let requested = log.record(.requested, variant: 2, sequence: 6)
        #expect(requested)
        #expect(log.isDecided(variant: 2, sequence: 6))
        #expect(!log.isDecided(variant: 2, sequence: 5))
        #expect(!log.isDecided(variant: 1, sequence: 6))
    }

    @Test("Refusals that hold for the segment decide it")
    func finalRefusalsDecide() {
        let finals: [MediaDemuxer.AbandonRefusal] = [
            .notAskedFor, .rejected, .join(.atDiscontinuity), .join(.beforeDiscontinuity), .join(.unsupported),
        ]
        for (sequence, refusal) in finals.enumerated() {
            var log = MediaDemuxer.AbandonmentLog()
            let isNew = log.record(.refused(refusal), variant: 2, sequence: sequence)
            #expect(isNew)
            #expect(log.isDecided(variant: 2, sequence: sequence), "\(refusal.text)")
        }
        #expect(!MediaDemuxer.AbandonRefusal.switchUnderWay.isFinal)
        #expect(!MediaDemuxer.AbandonRefusal.noKeyframeQueued.isFinal)
        #expect(
            !MediaDemuxer.AbandonRefusal.join(.noSegment).isFinal,
            "a target's live playlist a reload behind lists the segment a moment later")
    }
}
