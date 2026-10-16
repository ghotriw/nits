import Foundation
import Testing

@testable import NitsCore

@Suite("Frame Cadence Statistics")
struct FrameCadenceStatsTests {
    /// Plays `seconds` of content through a display link the way `FrameQueue.popFrame` picks frames: a frame goes up
    /// on the first tick whose projected clock (plus `jitter(tick)`) is within the lead window of its PTS.
    private func play(
        fps: Double, linkHz: Double, seconds: Double, clockPhase: Double, jitter: (Int) -> Double = { _ in 0 },
        dropFrame: Int? = nil
    ) -> FrameCadenceStats {
        var stats = FrameCadenceStats()
        let tick = 1 / linkHz
        let frameDuration = 1 / fps
        let lead = FrameQueue.leadWindowSeconds(nominalFrameDuration: frameDuration)
        var nextFrame = 0
        for tickIndex in 0..<Int(seconds * linkHz) {
            let target = 100 + Double(tickIndex) * tick
            let clock = Double(tickIndex) * tick + clockPhase + jitter(tickIndex)
            if nextFrame == dropFrame { nextFrame += 1 }
            let pts = Double(nextFrame) * frameDuration
            guard clock + lead >= pts else { continue }
            _ = stats.recordFrame(
                targetTimestamp: target, tickInterval: tick, pts: pts, slack: clock + lead - pts,
                frameDuration: frameDuration, playbackRate: 1, renderCall: 0.001)
            nextFrame += 1
        }
        return stats
    }

    @Test("25 fps on 60 Hz holds frames for 2 and 3 ticks in a 3:2 ratio")
    func testSteadyPulldown() {
        // A phase that keeps every pick 1/2 of the 3.3 ms threshold spacing away from a vsync.
        let stats = play(fps: 25, linkHz: 60, seconds: 4, clockPhase: 1.0 / 600)
        #expect(stats.offPatternHolds == 0)
        #expect(stats.skippedFrames == 0)
        #expect(stats.nearTickEdge == 0)
        #expect(stats.holdTicks.keys.sorted() == [2, 3])
        let twos = Double(stats.holdTicks[2] ?? 0)
        let threes = Double(stats.holdTicks[3] ?? 0)
        #expect(abs(twos / (twos + threes) - 0.6) < 0.02)
        #expect(stats.slackSpread < 1.0 / 60)
    }

    @Test("24 fps on 120 Hz holds every frame for exactly 5 ticks")
    func testWholeMultiple() {
        let stats = play(fps: 24, linkHz: 120, seconds: 4, clockPhase: 0)
        #expect(stats.holdTicks.keys.sorted() == [5])
        #expect(stats.offPatternHolds == 0)
    }

    @Test("Clock jitter around a vsync shows as near-edge picks")
    func testJitter() {
        // Thresholds sit right on vsyncs (phase 0), and the clock wobbles ±0.5 ms tick to tick.
        let stats = play(
            fps: 25, linkHz: 60, seconds: 4, clockPhase: 0, jitter: { $0.isMultiple(of: 2) ? 0.0005 : -0.0005 })
        #expect(stats.nearTickEdge > 0)
    }

    @Test("An edge frame changing sides of the vsync counts as a flip; staying on one side does not")
    func testEdgeSideFlips() {
        // Edge frames recur every 12 ticks; the jitter sign alternates per 12 ticks, so each one lands on the other side.
        let flapping = play(
            fps: 25, linkHz: 60, seconds: 4, clockPhase: 0, jitter: { ($0 / 12).isMultiple(of: 2) ? 0.0005 : -0.0005 })
        #expect(flapping.edgeFrames > 10)
        #expect(flapping.edgeSideFlips >= flapping.edgeFrames - 2)

        let settled = play(fps: 25, linkHz: 60, seconds: 4, clockPhase: 0.0003)
        #expect(settled.edgeFrames > 10)
        #expect(settled.edgeSideFlips == 0)
    }

    @Test("A frame missing from the sequence counts as skipped, not as an off-pattern hold")
    func testSkippedFrame() {
        let stats = play(fps: 25, linkHz: 60, seconds: 4, clockPhase: 1.0 / 600, dropFrame: 30)
        #expect(stats.skippedFrames == 1)
        #expect(stats.offPatternHolds == 0)
    }

    @Test("GPU work finishing after its vsync or failing is counted")
    func testGPUCompletion() {
        var stats = play(fps: 25, linkHz: 60, seconds: 1, clockPhase: 1.0 / 600)
        stats.recordGPUCompletion(targetTimestamp: 10, gpuEndTime: 9.995)
        stats.recordGPUCompletion(targetTimestamp: 10, gpuEndTime: 10.001)
        stats.recordGPUCompletion(targetTimestamp: 10, gpuEndTime: 0)
        #expect(stats.lateGPUFrames == 1)
        #expect(stats.failedGPUFrames == 1)
    }

    @Test("The slack spread covers one report window, not the clock's slow drift against vsync before it")
    func testSpreadPerWindow() {
        var stats = FrameCadenceStats()
        let tick = 1.0 / 60
        // 3 ticks per 50 ms frame; the slack drifts 4 ms per second, 60 ms over the whole run.
        for frame in 0..<300 {
            let target = 100 + Double(frame) * 3 * tick
            _ = stats.recordFrame(
                targetTimestamp: target, tickInterval: tick, pts: Double(frame) * 0.05,
                slack: 0.001 + (target - 100) * 0.001 * 4, frameDuration: 0.05, playbackRate: 1, renderCall: 0)
        }
        #expect(stats.slackSpread < 0.021)
        #expect(stats.slackSpread > 0.015)
    }

    @Test("A pause or seek starts a new baseline instead of counting a long hold")
    func testBreaks() {
        var stats = FrameCadenceStats()
        let tick = 1.0 / 60
        func record(_ target: Double, _ pts: Double) {
            _ = stats.recordFrame(
                targetTimestamp: target, tickInterval: tick, pts: pts, slack: 0.005, frameDuration: 0.04,
                playbackRate: 1, renderCall: 0)
        }
        record(100, 0)
        record(100 + 3 * tick, 0.04)  // the hold after the baseline frame is not counted
        record(100 + 5 * tick, 0.08)
        record(101, 0.12)  // resumed after a pause
        record(101 + 3 * tick, 5)  // seek
        record(101 + 6 * tick, 4)  // backward seek
        #expect(stats.holdTicks == [2: 1])
        #expect(stats.skippedFrames == 0)
    }

    /// A ProMotion panel running at ~118.5 Hz while `CADisplayLink.duration` says 1/120: 25 fps takes 4.74 ticks per
    /// frame, not 4.8, and holds of 4 are 26 %, not 20 %.
    @Test("Tick figures follow the measured vsync spacing, not the link's reported duration")
    func testMeasuredTickInterval() {
        var stats = FrameCadenceStats()
        let reported = 1.0 / 120
        let actual = 1.0 / 118.5
        let frameDuration = 0.04
        let lead = FrameQueue.leadWindowSeconds(nominalFrameDuration: frameDuration)
        var nextFrame = 0
        for tickIndex in 0..<(4 * 118) {
            let target = 100 + Double(tickIndex) * actual
            stats.recordTick(targetTimestamp: target, tickInterval: reported)
            // Content clock tied to the actual vsyncs, phase chosen off the frame boundaries.
            let clock = Double(tickIndex) * actual + 0.0004
            let pts = Double(nextFrame) * frameDuration
            guard clock + lead >= pts else { continue }
            _ = stats.recordFrame(
                targetTimestamp: target, tickInterval: reported, pts: pts, slack: clock + lead - pts,
                frameDuration: frameDuration, playbackRate: 1, renderCall: 0)
            nextFrame += 1
        }
        #expect(abs(stats.measuredTickInterval - actual) < 1e-6)
        #expect(stats.holdTicks.keys.sorted() == [4, 5])
        #expect(stats.offPatternHolds == 0)
        let fours = Double(stats.holdTicks[4] ?? 0)
        let fives = Double(stats.holdTicks[5] ?? 0)
        #expect(abs(fours / (fours + fives) - 0.26) < 0.03)
    }

    @Test("On 120 Hz 25p, frame boundaries centred in the 1.7 ms lattice cells are not edge frames")
    func testEdgeWindowInsideLatticeStep() {
        // Centred cells put boundaries 0.83 ms from either tick edge: inside the old 1.5 ms window, outside step / 3.
        let stats = play(fps: 25, linkHz: 120, seconds: 4, clockPhase: 1.0 / 1200)
        #expect(stats.holdTicks.keys.sorted() == [4, 5])
        #expect(stats.edgeFrames == 0)
        #expect(stats.nearTickEdge == 0)
    }

    @Test("A completed window yields a report and starts the next one")
    func testReport() {
        var stats = FrameCadenceStats()
        let tick = 1.0 / 60
        var reports: [String] = []
        for frame in 0..<200 {
            if let report = stats.recordFrame(
                targetTimestamp: 100 + Double(frame) * 3 * tick, tickInterval: tick, pts: Double(frame) * 0.05,
                slack: 0.005, frameDuration: 0.05, playbackRate: 1, renderCall: 0)
            {
                reports.append(report)
            }
        }
        #expect(reports.count == 1)
        #expect(reports.first?.contains("held 3×99, off-pattern 0, skipped 0") == true)
        #expect(stats.frames < 100)
    }
}
