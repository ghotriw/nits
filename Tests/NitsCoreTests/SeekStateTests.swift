import Testing

@testable import NitsCore

@Suite("Seek preview frame choice")
struct SeekPreviewFrameChoiceTests {
    private typealias Choice = SeekPreview.FrameChoice

    /// The frame the preview ends on when the decoder emits frames at `order`.
    private func picked(_ choice: Choice, from order: [Double]) -> Double? {
        order.reduce(nil as Double?) { current, candidate in
            choice.prefers(candidate, over: current) ? candidate : current
        }
    }

    @Test("An exact seek shows the frame closest to the target, in whatever order frames come")
    func exactClosest() {
        let choice = Choice(target: 2.0, exact: true, minPts: nil)
        // B-frames out of order, then the pipeline's tail past the target.
        #expect(picked(choice, from: [1.0, 1.96, 1.92, 2.06, 2.08]) == 1.96)
        // A tie goes to the later one decoded.
        #expect(picked(choice, from: [1.5, 2.5]) == 2.5)
    }

    @Test("A keyframe seek shows the earliest frame decoded")
    func keyframeEarliest() {
        let choice = Choice(target: 2.0, exact: false, minPts: nil)
        #expect(picked(choice, from: [3.04, 3.0, 3.08]) == 3.0)
    }

    @Test("A forward step lands past the frame it steps from, closest to its target")
    func forwardStep() {
        let choice = Choice(target: 1.04, exact: true, minPts: 1.001)
        // Closer to the target, but the frame stepped from: the step would not advance.
        #expect(picked(choice, from: [1.0, 1.08]) == 1.08)
        #expect(picked(choice, from: [1.0, 1.08, 1.04]) == 1.04)
        // No frame past it yet: the closest stands in.
        #expect(picked(choice, from: [0.92, 0.96]) == 0.96)
        // One past it replaces the stand-in, however far; one before it never replaces it.
        #expect(picked(choice, from: [0.96, 1.2, 1.0]) == 1.2)
    }
}

@Suite("Relative seek bursts")
struct RelativeSeekBurstTests {
    @Test("The first press starts the burst; the rest report from where it started")
    func burstOffset() {
        var burst = RelativeSeekBurst()
        #expect(burst.offset(landingAt: 10) == nil)
        let first = burst.press(at: 10)
        let second = burst.press(at: 15)
        #expect(first && !second)
        #expect(burst.offset(landingAt: 20) == 10)
        let landed = burst.seekLanded()
        let landedAgain = burst.seekLanded()
        #expect(landed && !landedAgain)
        // Still the same burst after a landing: it ends only on a reset.
        let afterLanding = burst.press(at: 20)
        #expect(!afterLanding)
        #expect(burst.startTime == 10)
    }

    @Test("A reset burst starts again from the next press")
    func restart() {
        var burst = RelativeSeekBurst()
        _ = burst.press(at: 10)
        burst = RelativeSeekBurst()
        let first = burst.press(at: 30)
        #expect(first)
        #expect(burst.offset(landingAt: 25) == -5)
    }
}

@Suite("Chase target")
struct ChaseTargetTests {
    @Test("Landing keeps the kind of seek and drops the frame step's minimum")
    func landed() {
        let step = ChaseTarget(seconds: 1.04, exact: true, forward: false, minFramePTS: 1.001)
        #expect(step.landed(at: 1.08) == ChaseTarget(seconds: 1.08, exact: true, forward: false))
    }
}
