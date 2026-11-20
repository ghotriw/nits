import Testing

@testable import NitsCore

/// How many frames the feeder lets the queue hold, from a byte budget (iOS) or not (macOS).
@Suite("Frame queue budget")
struct FrameQueueBudgetTests {
    private static let mb = 1 << 20

    @Test("Without a budget the queue holds 40 and goes on at 25, whatever the frames")
    func nilBudgetKeepsFortyAndTwentyFive() {
        let result = FrameQueueBudget.highWater(budgetBytes: nil, frameBytes: 25 * Self.mb, frameRate: 24)
        #expect(result.pause == 40)
        #expect(result.resume == 25)
    }

    @Test("4K 10-bit frames hit the budget: 12 frames, resume at 7")
    func fourKTenBitHitsBudget() {
        let result = FrameQueueBudget.highWater(budgetBytes: 300 * Self.mb, frameBytes: 25 * Self.mb, frameRate: 24)
        #expect(result.pause == 12)
        #expect(result.resume == 7)
    }

    @Test("HD frames fit under the cap: 40 and 25")
    func hdFitsUnderCap() {
        let result = FrameQueueBudget.highWater(budgetBytes: 300 * Self.mb, frameBytes: 3 * Self.mb, frameRate: 24)
        #expect(result.pause == 40)
        #expect(result.resume == 25)
    }

    @Test("Half a second at the frame rate wins over the budget, by twice the budget at most")
    func minimumTimeWinsOverBudgetUpToTwice() {
        let sixty = FrameQueueBudget.highWater(budgetBytes: 300 * Self.mb, frameBytes: 25 * Self.mb, frameRate: 60)
        #expect(sixty.pause == 24)
        let hundredTwenty = FrameQueueBudget.highWater(
            budgetBytes: 300 * Self.mb, frameBytes: 25 * Self.mb, frameRate: 120)
        #expect(hundredTwenty.pause == 24)
    }

    @Test("A floor within twice the budget is kept: 24 fps holds 12")
    func floorWithinTwiceTheBudget() {
        let result = FrameQueueBudget.highWater(budgetBytes: 300 * Self.mb, frameBytes: 25 * Self.mb, frameRate: 24)
        #expect(result.pause == 12)
    }

    @Test("A budget under one frame still holds one")
    func budgetUnderOneFrame() {
        let result = FrameQueueBudget.highWater(budgetBytes: 10 * Self.mb, frameBytes: 25 * Self.mb, frameRate: 60)
        #expect(result.pause == 1)
    }

    @Test("The floor in time never raises the queue past 40")
    func floorIsCapped() {
        let result = FrameQueueBudget.highWater(budgetBytes: 1000 * Self.mb, frameBytes: 25 * Self.mb, frameRate: 120)
        #expect(result.pause == 40)
        #expect(result.resume == 25)
    }

    @Test("A frame size not known yet counts as no budget")
    func unknownFrameSize() {
        let result = FrameQueueBudget.highWater(budgetBytes: 300 * Self.mb, frameBytes: 0, frameRate: 24)
        #expect(result.pause == 40)
    }
}
