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

    /// The segment is [6, 12) s; `after` is how far the old variant is read.
    private func holeCut(after: Double, known: [Double]) -> Double? {
        MediaDemuxer.expectedHoleCut(start: 6, duration: 6, after: after, known: known)
    }

    @Test("With nothing of the segment queued, the cut is the keyframe expected past what is read, by the spacing read")
    func holeCutAtTheNextKeyframe() {
        // Keyframes every 2 s, the segment's at 6 handed out: the next at 8.
        #expect(holeCut(after: 7.5, known: [0, 2, 4, 6]) == 8)
        // The spacing of the keyframes read, whatever segment they are of (the 15 → 1.5 Mbit/s stand: every 0.33 s).
        let short = holeCut(after: 8.57, known: [7.98, 8.31])
        #expect(short.map { abs($0 - 8.64) < 0.001 } == true, "\(String(describing: short))")
        // Read past where one was expected (a keyframe missing): the one after.
        #expect(holeCut(after: 8.5, known: [2, 4, 6]) == 10)
        // Keyframes queued past what is read are not what the spacing counts from.
        #expect(holeCut(after: 7.5, known: [0, 2, 4, 6, 11]) == 8)
    }

    @Test("With no spacing known, or the next keyframe at the segment's end, the lower variant joins the next segment")
    func holeCutJoinsTheNextSegment() {
        #expect(holeCut(after: 7, known: []) == nil)
        #expect(holeCut(after: 7, known: [6]) == nil, "one keyframe: no spacing")
        #expect(holeCut(after: 7, known: [0, 6]) == nil, "a keyframe a segment")
        #expect(holeCut(after: 10.5, known: [6, 8, 10]) == nil, "the next is the next segment's, at 12")
    }

    @Test("The keyframes queued are kept apart from the packets: the latest, once each, a break starting them over")
    func keyframeTrail() {
        var trail = MediaDemuxer.KeyframeTrail()
        for time in stride(from: 0.0, through: 20, by: 2) { trail.note(time) }
        #expect(trail.times == [4, 6, 8, 10, 12, 14, 16, 18, 20], "the latest nine")
        trail.note(20)
        #expect(trail.times.last == 20 && trail.times.count == 9, "the same keyframe queued again counts once")
        // A download read again from 16: what came after it goes.
        trail.note(16)
        #expect(trail.times == [4, 6, 8, 10, 12, 14, 16])
        // A break: the times start over.
        trail.note(1)
        #expect(trail.times == [1])
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
        let another = log.record(.refused(.join(.noSegment)), variant: 2, sequence: 5)
        #expect(another, "another one is logged")
        let nextSegment = log.record(.refused(.join(.noSegment)), variant: 2, sequence: 6)
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
        #expect(
            !MediaDemuxer.AbandonRefusal.join(.noSegment).isFinal,
            "a target's live playlist a reload behind lists the segment a moment later")
    }

    typealias Restart = MediaDemuxer.RestartSplice

    @Test(
        "Read again from the segment's start: pictures dropped to the first keyframe past what is handed out, cut there"
    )
    func restartCutsAtTheFirstKeyframePastWhatIsHandedOut() {
        var restart = Restart(video: 0, audio: nil)
        // Handed out to 650: the segment's own keyframe at 600 is dropped with what follows it, the one at 700 is the cut.
        #expect(restart.admitVideo(isKeyframe: true, time: 600, handedOut: 650) == .drop)
        #expect(restart.admitVideo(isKeyframe: false, time: 640, handedOut: 650) == .drop)
        #expect(restart.admitVideo(isKeyframe: true, time: 700, handedOut: 650) == .init(cut: 700, passes: true))
        // An open GOP's leading pictures (after the keyframe in decode order, before it in time) pass: their queued copies
        // were after the keyframe in the queue, cut with it.
        #expect(restart.admitVideo(isKeyframe: false, time: 680, handedOut: 650) == .pass)
        #expect(restart.admitVideo(isKeyframe: false, time: 720, handedOut: 650) == .pass)
        #expect(restart.isDone)
    }

    @Test("Nothing handed out of the segment: its own keyframe is the cut")
    func restartCutsAtTheSegmentStart() {
        var restart = Restart(video: 0, audio: nil)
        #expect(restart.admitVideo(isKeyframe: true, time: 600, handedOut: 400) == .init(cut: 600, passes: true))
        var fresh = Restart(video: 0, audio: nil)
        #expect(fresh.admitVideo(isKeyframe: true, time: 600, handedOut: nil) == .init(cut: 600, passes: true))
    }

    @Test(
        "The sound is cut at its first packet read again, or just after what is handed out, and the rest before it dropped"
    )
    func restartCutsTheSound() {
        // Read again from 600, handed out to 640: the queue is cut from 641, what is read again before it dropped.
        var restart = Restart(video: 0, audio: 1)
        #expect(restart.admitAudio(time: 600, handedOut: 640) == .init(cut: 641, passes: false))
        #expect(restart.admitAudio(time: 620, handedOut: 640) == .drop)
        #expect(!restart.isDone)
        #expect(restart.admitAudio(time: 660, handedOut: 640) == .pass)
        #expect(restart.admitVideo(isKeyframe: true, time: 700, handedOut: 650).passes)
        #expect(restart.isDone)

        // A rendition the lane does not read again: its next packet is past everything queued and handed out, and passes.
        var rendition = Restart(video: 0, audio: 1)
        #expect(rendition.admitAudio(time: 900, handedOut: 640) == .init(cut: 900, passes: true))
    }

    @Test("The splice waits for both the picture and the sound")
    func restartIsDoneWithBoth() {
        var restart = Restart(video: 0, audio: 1)
        _ = restart.admitVideo(isKeyframe: true, time: 700, handedOut: nil)
        #expect(!restart.isDone)
        _ = restart.admitAudio(time: 700, handedOut: nil)
        #expect(restart.isDone)
    }
}
