import Foundation
import Testing

@testable import NitsCore

@Suite("Adaptive Target White Tone Mapping Tests")
struct AdaptiveToneMappingTests {
    @Test("High-peak HDR10 content maintains standard 203 nits ITU reference")
    func testHighPeakHDR10TargetNits() {
        // High peak (1000 nits) and normal/high FALL (161 nits, like His Dark Materials)
        let target1 = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 1000.0,
            maxFallNits: 161.0
        )
        #expect(target1 == 203.0)

        // High peak (1000 nits) without explicit FALL metadata (like Ms. Marvel)
        let target2 = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 1000.0,
            maxFallNits: 0.0
        )
        #expect(target2 == 203.0)

        // 997 nits (w_hdm_full)
        let target3 = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 997.0,
            maxFallNits: 161.0
        )
        #expect(target3 == 203.0)
    }

    @Test("Low-peak and low-FALL content dynamically scales target white to prevent darkness")
    func testLowPeakAndLowFallTargetNits() {
        // The Agency (451 nits peak, 68 nits FALL)
        let agencyTarget = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 451.0,
            maxFallNits: 68.0
        )
        // Expected range: ~110...125 nits
        #expect(agencyTarget >= 110.0 && agencyTarget <= 125.0)

        // House of the Dragon (699 nits peak, 94 nits FALL)
        let hotdTarget = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 699.0,
            maxFallNits: 94.0
        )
        // Expected range: ~150...165 nits
        #expect(hotdTarget >= 150.0 && hotdTarget <= 165.0)
    }

    @Test("Adaptive target white clamps cleanly between 100 and base target nits")
    func testBoundaryClamping() {
        // Ultra-low peak (e.g. 250 nits)
        let minTarget = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 250.0,
            maxFallNits: 40.0
        )
        #expect(minTarget >= 100.0)

        // Ultra-high peak (e.g. 4000 nits mastering)
        let maxTarget = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 4000.0,
            maxFallNits: 250.0
        )
        #expect(maxTarget == 203.0)
    }

    @Test("Explicit custom baseTargetNits is respected as maximum bound")
    func testCustomBaseTargetNits() {
        // User explicitly set 150 nits as base target
        let target = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 150.0,
            maxPeakNits: 451.0,
            maxFallNits: 68.0
        )
        #expect(target >= 100.0 && target <= 150.0)
    }

    @Test("targetNitsScale scales content-adaptive target white dynamically while preserving adaptation")
    @MainActor
    func testTargetNitsScaleMultiplier() {
        let engine = PlayerEngine.makeForTesting()

        // 1.0x default
        #expect(engine.targetNitsScale == 1.0)
        #expect(engine.baseAdaptiveTargetNits == 203.0)
        #expect(engine.metalTargetNits == 203.0)

        // Adjust scale knob to 0.8x (20% brighter midtones/shadows for all content)
        engine.targetNitsScale = 0.8
        #expect(abs(engine.metalTargetNits - (203.0 * 0.8)) < 0.01)

        // Adjust scale knob to 1.5x (higher contrast)
        engine.targetNitsScale = 1.5
        #expect(abs(engine.metalTargetNits - (203.0 * 1.5)) < 0.01)
    }

    @Test("DolbyVisionRPUParser correctly converts PQ to nits and handles 100-nit trim")
    func testDolbyVisionPQConversionAndTrim() {
        // PQ 2081 corresponds to ~100 nits
        let nits100 = DolbyVisionRPUParser.pqToNits(Float(2081) / 4095.0)
        #expect(abs(nits100 - 100.0) < 5.0)

        // PQ 3079 corresponds to ~1000 nits
        let nits1000 = DolbyVisionRPUParser.pqToNits(Float(3079) / 4095.0)
        #expect(abs(nits1000 - 1000.0) < 50.0)

        // Construct mock Level 2 trim for 100 nits
        let trim100 = DolbyVisionFrameMetadata.Level2Trim(
            targetMaxPQ: 2081,
            trimSlope: 2013,
            trimOffset: 2016,
            trimPower: 1339,
            trimChromaWeight: 2048,
            trimSaturationGain: 2048
        )
        let meta = DolbyVisionFrameMetadata(
            sceneRefresh: true,
            l1: DolbyVisionFrameMetadata.Level1(minPQ: 7, maxPQ: 3079, avgPQ: 1229),
            l2Trims: [trim100]
        )

        #expect(meta.sdrTrim != nil)
        #expect(meta.sdrTrim?.targetMaxPQ == 2081)
        // SMPTE ST 2094-10 inverse conversion: S = 2013 / 4096 + 0.5 ~ 0.991455
        let expectedSlope = (Float(2013) / 4096.0) + 0.5
        #expect(abs((meta.sdrTrim?.slope ?? 0.0) - expectedSlope) < 0.0001)
        // Neutral 2048: O = 0.0, CW = 0.0, SG = 0.0
        #expect(abs(meta.sdrTrim?.chromaWeight ?? 1.0) < 0.0001)
        #expect(abs(meta.sdrTrim?.saturationGain ?? 1.0) < 0.0001)
    }

    @Test("DolbyVisionRPUParser handles unescaping emulation prevention bytes")
    func testRPUUnescaping() {
        // [0x00, 0x00, 0x03, 0x01] -> [0x00, 0x00, 0x01]
        let raw = Data([0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x02])
        let unescaped = DolbyVisionRPUParser.unescapeRPU(from: raw)
        #expect(unescaped == [0x00, 0x00, 0x01, 0x00, 0x00, 0x02])
    }

    @Test("DolbyVisionRPUParser rejects truncated or invalid payloads safely without crashing")
    func testInvalidRPUParsing() {
        // Less than minimum size
        #expect(DolbyVisionRPUParser.parse(naluData: Data([0x00, 0x00])) == nil)
        // Random garbage bytes
        let garbage = Data([0x7C, 0x01, 0x19, 0xFF, 0xFF, 0xFF, 0x00, 0x12])
        #expect(DolbyVisionRPUParser.parse(naluData: garbage) == nil)
    }

    @Test("PlayerEngine resets dynamic tone mapping state on stop()")
    @MainActor
    func testPlayerEngineToneMappingReset() {
        let engine = PlayerEngine.makeForTesting()
        #expect(engine.metalTargetNits == 203.0)
        engine.stop()
        #expect(engine.metalTargetNits == 203.0)
    }
}
