/// How many decoded frames the video feeder lets the frame queue hold before it waits, and the count at which it goes
/// on again.
///
/// Without a budget (macOS) that is 40 and 25. A 4K 10-bit frame is ~25 MB of IOSurface, so 40 of them are a gigabyte,
/// which a phone's foreground limit does not leave: a host sets `PlayerConfiguration.frameQueueByteBudget`, and the
/// count follows the size of the frames being decoded (it changes with a variant switch). A queue too short to hide a
/// decode's jitter stutters, so a floor in time (half a second at the queue's frame rate) wins over the budget.
struct FrameQueueBudget: Sendable {
    /// The most frames the feeder ever lets the queue hold: the budget never raises it.
    static let maximumFrames = 40
    /// The resume point of the cap, as a share of the pause point (25 of 40).
    static let resumeNumerator = 5
    static let resumeDenominator = 8
    /// What the floor in time keeps, whatever the budget says.
    static let minimumSeconds = 0.5

    /// - Parameters:
    ///   - budgetBytes: The memory the queue may hold; `nil` for the fixed 40 / 25.
    ///   - frameBytes: What one decoded frame costs (its IOSurface); not known yet (`<= 0`) counts as no budget.
    ///   - frameRate: Frames per second the queue is consumed at (the field rate when deinterlacing).
    static func highWater(budgetBytes: Int?, frameBytes: Int, frameRate: Double) -> (pause: Int, resume: Int) {
        guard let budgetBytes, frameBytes > 0 else {
            return (maximumFrames, maximumFrames * resumeNumerator / resumeDenominator)
        }
        let floorFrames = frameRate.isFinite && frameRate > 0 ? Int((frameRate * minimumSeconds).rounded(.up)) : 0
        let pause = min(max(budgetBytes / frameBytes, floorFrames, 1), maximumFrames)
        return (pause, max(pause * resumeNumerator / resumeDenominator, 1))
    }
}
