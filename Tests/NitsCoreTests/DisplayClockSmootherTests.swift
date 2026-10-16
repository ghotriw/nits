import Foundation
import Testing

@testable import NitsCore

@Suite("Display Clock Smoothing and Phase Lock")
struct DisplayClockSmootherTests {
    private let tick = 1.0 / 60

    private func time(_ smoother: inout DisplayClockSmoother, _ raw: Double, _ host: Double, rate: Double = 1) -> Double
    {
        smoother.pickTime(rawTime: raw, hostTime: host, rate: rate).time
    }

    @Test("Tick-to-tick jitter is filtered to a fraction of its size")
    func testJitter() {
        var smoother = DisplayClockSmoother()
        var maxError = 0.0
        for index in 0..<600 {
            let host = 1000 + Double(index) * tick
            let jitter = index.isMultiple(of: 2) ? 0.001 : -0.001
            let smoothed = time(&smoother, host - 990 + jitter, host)
            if index > 120 { maxError = max(maxError, abs(smoothed - (host - 990))) }
        }
        #expect(maxError < 0.0001)
    }

    @Test("Slow clock drift is followed")
    func testDrift() {
        var smoother = DisplayClockSmoother()
        var error = 0.0
        for index in 0..<3600 {
            let host = 1000 + Double(index) * tick
            // 50 ppm: the content clock runs slightly slow against the host clock.
            let raw = (host - 1000) * (1 - 50e-6)
            error = time(&smoother, raw, host) - raw
        }
        #expect(abs(error) < 0.00005)
    }

    @Test("A seek, rate change or gap in ticks takes the raw clock at once and is reported")
    func testDiscontinuities() {
        var smoother = DisplayClockSmoother()
        for index in 0..<60 {
            let host = 1000 + Double(index) * tick
            _ = time(&smoother, host - 1000, host)
        }
        var host = 1000 + 60 * tick
        let seek = smoother.pickTime(rawTime: 30, hostTime: host, rate: 1)
        #expect(seek.time == 30)
        if case .jump = seek.discontinuity {
        } else {
            Issue.record("seek not reported as a jump: \(String(describing: seek.discontinuity))")
        }
        host += tick
        let rate = smoother.pickTime(rawTime: 30 + tick * 2, hostTime: host, rate: 2)
        #expect(rate.time == 30 + tick * 2)
        #expect(rate.discontinuity == .rateChange(from: 1, to: 2))
        host += 1
        let gap = smoother.pickTime(rawTime: 32.5, hostTime: host, rate: 2)
        #expect(gap.time == 32.5)
        if case .tickGap = gap.discontinuity {
        } else {
            Issue.record("gap not reported: \(String(describing: gap.discontinuity))")
        }
        host += tick
        #expect(smoother.pickTime(rawTime: 32.5 + 2 * tick, hostTime: host, rate: 2).discontinuity == nil)
    }

    @Test("The phase bias carries over a discontinuity; a stopped clock comes back raw, without it")
    func testBiasAcrossDiscontinuities() {
        var smoother = DisplayClockSmoother()
        for index in 0..<10 {
            let host = 1000 + Double(index) * tick
            _ = time(&smoother, host - 1000, host)
            // Picks 1 ms past the lattice centre (1.67 ms) every frame: the lock pulls the bias negative.
            smoother.recordPick(slack: 0.0027, tickInterval: tick, frameDuration: 0.04, playbackRate: 1)
        }
        let bias = smoother.phaseBias
        #expect(bias < 0)
        let host = 1000 + 10 * tick
        let seek = smoother.pickTime(rawTime: 30, hostTime: host, rate: 1)
        #expect(seek.discontinuity != nil)
        #expect(abs(seek.time - (30 + bias)) < 1e-12)
        #expect(smoother.pickTime(rawTime: 30, hostTime: host + tick, rate: 0).time == 30)
    }

    @Test("A stopped clock is never smoothed or biased")
    func testStoppedClock() {
        var smoother = DisplayClockSmoother()
        _ = time(&smoother, 10, 1000, rate: 0)
        let stopped = smoother.pickTime(rawTime: 10.004, hostTime: 1000 + tick, rate: 0)
        #expect(stopped.time == 10.004)
        #expect(stopped.discontinuity == nil)
    }

    @Test("Lattice step: tick / q for p/q ticks per frame, none for rates without a small common multiple")
    func testLatticeStep() {
        func step(fps: Double, hz: Double) -> Double? {
            DisplayClockSmoother.latticeStep(tickInterval: 1 / hz, frameDuration: 1 / fps, rate: 1)
        }
        #expect(abs((step(fps: 25, hz: 60) ?? 0) - 1.0 / 300) < 1e-9)
        #expect(abs((step(fps: 24, hz: 60) ?? 0) - 1.0 / 120) < 1e-9)
        #expect(abs((step(fps: 24000.0 / 1001.0, hz: 60) ?? 0) - 1.0 / 120) < 1e-9)
        #expect(abs((step(fps: 30, hz: 60) ?? 0) - 1.0 / 60) < 1e-9)
        #expect(step(fps: 25, hz: 59.94) == nil)
    }

    /// 25 fps on 60 Hz for two minutes with the clock drifting 50 ppm against the display (the frame-boundary lattice
    /// passes vsyncs twice) and ±1 ms of pseudo-random jitter per tick, picking frames the way `FrameQueue` does.
    @Test("Phase lock keeps frame boundaries off vsyncs: no flips, no off-pattern holds")
    func testPhaseLockAgainstDriftAndJitter() {
        var smoother = DisplayClockSmoother()
        let frameDuration = 0.04
        let lead = FrameQueue.leadWindowSeconds(nominalFrameDuration: frameDuration)
        let step = 1.0 / 300
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func jitter() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(seed >> 11) / Double(1 << 53) * 2 - 1) * 0.001
        }

        var nextFrame = 0
        var lastPickTick = -1
        var holds: [Int: Int] = [:]
        var nearEdge = 0
        var maxBias = 0.0
        for tickIndex in 0..<(120 * 60) {
            let host = 1000 + Double(tickIndex) * tick
            let raw = (host - 1000) * (1 - 50e-6) + jitter()
            let pick = time(&smoother, raw, host)
            let pts = Double(nextFrame) * frameDuration
            guard pick + lead >= pts else { continue }
            let slack = pick + lead - pts
            smoother.recordPick(slack: slack, tickInterval: tick, frameDuration: frameDuration, playbackRate: 1)
            maxBias = max(maxBias, abs(smoother.phaseBias))
            if tickIndex > 120 {
                holds[tickIndex - lastPickTick, default: 0] += 1
                if slack < 0.0005 || slack > tick - 0.0005 { nearEdge += 1 }
            }
            lastPickTick = tickIndex
            nextFrame += 1
        }
        #expect(Set(holds.keys) == [2, 3])
        #expect(maxBias <= step / 2 + 1e-9)
        // Without the lock about one frame in five sits on the edge while the lattice passes a vsync; with it, only
        // the few picks around each one-step bias move.
        #expect(nearEdge < 10)
    }
}
