import Foundation
import Testing

@testable import NitsCore

@Suite("Adaptive Target White Tone Mapping Tests")
struct AdaptiveToneMappingTests {
    @Test("High-peak HDR10 content maintains standard 203 nits ITU reference")
    func testHighPeakHDR10TargetNits() {
        // High peak (1000 nits) and normal/high FALL (161 nits, like His Dark Materials)
        let target1 = ToneMapController.adaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 1000.0,
            maxFallNits: 161.0
        )
        #expect(target1 == 203.0)

        // High peak (1000 nits) without explicit FALL metadata (like Ms. Marvel)
        let target2 = ToneMapController.adaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 1000.0,
            maxFallNits: 0.0
        )
        #expect(target2 == 203.0)

        // 997 nits (w_hdm_full)
        let target3 = ToneMapController.adaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 997.0,
            maxFallNits: 161.0
        )
        #expect(target3 == 203.0)
    }

    @Test("Low-peak and low-FALL content dynamically scales target white to prevent darkness")
    func testLowPeakAndLowFallTargetNits() {
        // The Agency (451 nits peak, 68 nits FALL)
        let agencyTarget = ToneMapController.adaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 451.0,
            maxFallNits: 68.0
        )
        // Expected range: ~110...125 nits
        #expect(agencyTarget >= 110.0 && agencyTarget <= 125.0)

        // House of the Dragon (699 nits peak, 94 nits FALL)
        let hotdTarget = ToneMapController.adaptiveTargetNits(
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
        let minTarget = ToneMapController.adaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 250.0,
            maxFallNits: 40.0
        )
        #expect(minTarget >= 100.0)

        // Ultra-high peak (e.g. 4000 nits mastering)
        let maxTarget = ToneMapController.adaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 4000.0,
            maxFallNits: 250.0
        )
        #expect(maxTarget == 203.0)
    }

    @Test("Explicit custom baseTargetNits is respected as maximum bound")
    func testCustomBaseTargetNits() {
        // User explicitly set 150 nits as base target
        let target = ToneMapController.adaptiveTargetNits(
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
        #expect(engine.toneMapping.targetNitsScale == 1.0)
        #expect(engine.toneMapping.baseTargetNits == 203.0)
        #expect(engine.toneMapping.targetNits == 203.0)

        // Adjust scale knob to 0.8x (20% brighter midtones/shadows for all content)
        engine.toneMapping.targetNitsScale = 0.8
        #expect(abs(engine.toneMapping.targetNits - (203.0 * 0.8)) < 0.01)

        // Adjust scale knob to 1.5x (higher contrast)
        engine.toneMapping.targetNitsScale = 1.5
        #expect(abs(engine.toneMapping.targetNits - (203.0 * 1.5)) < 0.01)
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

    @Test("An L2 trim at neutral codes is neutral; one code off is not")
    func testLevel2TrimNeutrality() {
        func trim(slope: UInt16 = 2048, offset: UInt16 = 2048, power: UInt16 = 2048, saturation: UInt16 = 2048)
            -> DolbyVisionFrameMetadata.Level2Trim
        {
            DolbyVisionFrameMetadata.Level2Trim(
                targetMaxPQ: 2081, trimSlope: slope, trimOffset: offset, trimPower: power, trimChromaWeight: 1000,
                trimSaturationGain: saturation)
        }
        #expect(trim().isNeutral)
        #expect(!trim(slope: 2049).isNeutral)
        #expect(!trim(offset: 2047).isNeutral)
        #expect(!trim(power: 2049).isNeutral)
        #expect(!trim(saturation: 2049).isNeutral)
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

    private final class BitWriter {
        private(set) var bytes: [UInt8] = []
        private var currentByte: UInt8 = 0
        private var bitsInCurrent: Int = 0

        func putBit(_ b: UInt32) {
            currentByte = (currentByte << 1) | UInt8(b & 1)
            bitsInCurrent += 1
            if bitsInCurrent == 8 {
                bytes.append(currentByte)
                currentByte = 0
                bitsInCurrent = 0
            }
        }

        func putBits(_ value: UInt32, count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) {
                putBit((value >> i) & 1)
            }
        }

        func putSBits(_ value: Int32, count: Int) {
            let mask: UInt32 = count == 32 ? UInt32.max : ((UInt32(1) << count) - 1)
            putBits(UInt32(bitPattern: value) & mask, count: count)
        }

        func putUE(_ value: UInt32) {
            let v = value + 1
            let bitLen = 32 - v.leadingZeroBitCount
            let leadingZeros = bitLen - 1
            for _ in 0..<leadingZeros { putBit(0) }
            putBits(v, count: bitLen)
        }

        func putSE(_ value: Int32) {
            let ue: UInt32 = value > 0 ? UInt32(value * 2 - 1) : UInt32(-value * 2)
            putUE(ue)
        }

        func putSECoef(_ fixedValue: Int64, log2Denom: Int) {
            let denom = Int64(1) << log2Denom
            let ipart = Int32(fixedValue >> log2Denom)
            let fpart = UInt32(fixedValue & (denom - 1))
            putSE(ipart)
            putBits(fpart, count: log2Denom)
        }

        func align() {
            while bitsInCurrent != 0 {
                putBit(0)
            }
        }

        func ebspNALUnit() -> Data {
            // Keep 2-byte NAL header as-is, escape RBSP payload with 0x03 emulation prevention bytes.
            guard bytes.count > 2 else { return Data(bytes) }
            var out: [UInt8] = [bytes[0], bytes[1]]
            var zeroCount = 0
            for b in bytes.dropFirst(2) {
                if zeroCount == 2 && b <= 0x03 {
                    out.append(0x03)
                    zeroCount = 0
                }
                out.append(b)
                zeroCount = (b == 0) ? (zeroCount + 1) : 0
            }
            return Data(out)
        }

        func writeRPUHeader(
            log2Denom: Int = 23, usePrevVdrRpu: Bool = false, disableResidual: Bool = true,
            hasSequenceInfo: Bool = true,
            float32Coefficients: Bool = false
        ) {
            putBits(0x7C, count: 8)
            putBits(0x01, count: 8)
            putBits(25, count: 8)

            putBits(2, count: 6)  // rpu_type = 2
            putBits(18, count: 11)  // rpu_format = 18
            putBits(0, count: 4)  // vdr_rpu_profile = 0
            putBits(0, count: 4)  // vdr_rpu_level = 0
            putBit(hasSequenceInfo ? 1 : 0)  // vdr_seq_info_present
            guard hasSequenceInfo else {
                putBit(1)  // vdr_dm_metadata_present = 1
                putBit(usePrevVdrRpu ? 1 : 0)  // use_prev_vdr_rpu_flag
                return
            }
            putBit(0)  // chroma_resampling_explicit_filter_flag = 0
            putBits(float32Coefficients ? 1 : 0, count: 2)  // coef_data_type: 0 fixed point, 1 float32
            if !float32Coefficients { putUE(UInt32(log2Denom)) }  // coef_log2_denom
            putBits(1, count: 2)  // vdr_rpu_normalized_idc = 1
            putBit(1)  // bl_video_full_range_flag = 1
            putUE(2)  // bl_bit_depth_minus8 = 2 (10-bit)
            putUE(2)  // el_bit_depth_minus8 = 2 (10-bit)
            putUE(4)  // vdr_bit_depth_minus8 = 4 (12-bit)
            putBit(0)  // spatial_resampling_filter_flag = 0
            putBits(0, count: 3)  // reserved / dm_compression = 0
            putBit(0)  // el_spatial_resampling_filter_flag = 0
            putBit(disableResidual ? 1 : 0)  // disable_residual_flag

            putBit(1)  // vdr_dm_metadata_present = 1
            putBit(usePrevVdrRpu ? 1 : 0)  // use_prev_vdr_rpu_flag
        }

        func writeDMHeaderAndFooter(hasL1: Bool = false) {
            putUE(0)  // affected_dm_id = 0
            putUE(0)  // current_dm_id = 0
            putUE(1)  // scene_refresh_flag = 1

            let yccMat: [Int32] = [8192, 799, 1681, 8192, -933, 1091, 8192, 267, -5545]
            for v in yccMat { putSBits(v, count: 16) }
            let yccOff: [UInt32] = [0, 1 << 27, 1 << 27]
            for v in yccOff { putBits(v, count: 32) }
            let lmsMat: [Int32] = [17081, -349, -349, -349, 17081, -349, -349, -349, 17081]
            for v in lmsMat { putSBits(v, count: 16) }

            putBits(65535, count: 16)  // signal_eotf
            putBits(0, count: 16)  // signal_eotf_param0
            putBits(0, count: 16)  // signal_eotf_param1
            putBits(0, count: 32)  // signal_eotf_param2
            putBits(12, count: 5)  // signal_bit_depth
            putBits(1, count: 2)  // signal_color_space
            putBits(0, count: 2)  // signal_chroma_format
            putBits(1, count: 2)  // signal_full_range_flag
            putBits(7, count: 12)  // source_min_pq = 7
            putBits(3079, count: 12)  // source_max_pq = 3079
            putBits(42, count: 10)  // source_diagonal = 42

            if hasL1 {
                putUE(1)  // num_ext_blocks = 1
                align()
                putUE(5)  // ext_len = 5 bytes
                putBits(1, count: 8)  // level = 1
                putBits(10, count: 12)  // minPQ = 10
                putBits(3000, count: 12)  // maxPQ = 3000
                putBits(1200, count: 12)  // avgPQ = 1200
                putBits(0, count: 4)  // 5 bytes total: 8 + 36 = 44 bits -> 4 padding bits
            } else {
                putUE(0)  // num_ext_blocks = 0
                align()
            }
            putBits(0, count: 32)  // CRC32
            putBits(0x80, count: 8)  // terminator
        }
    }

    @Test("DolbyVisionRPUParser parses Profile 5 polynomial reshaping curves, fractional se_coef, and DM matrices")
    func testProfile5RPUReshapingAndColorMatrixParsing() throws {
        let bw = BitWriter()
        let log2Denom = 23
        bw.writeRPUHeader(log2Denom: log2Denom, usePrevVdrRpu: false)

        bw.putUE(0)  // vdr_rpu_id = 0
        bw.putUE(0)  // mapping_color_space = 0
        bw.putUE(0)  // mapping_chroma_format_idc = 0

        // 3 components: 1 piece each (2 pivots: 0 and 1023)
        for _ in 0..<3 {
            bw.putUE(0)  // num_pivots_minus2 = 0 -> 2 pivots
            bw.putBits(0, count: 10)
            bw.putBits(1023, count: 10)
        }
        bw.putUE(0)  // num_x_partitions_minus1 = 0
        bw.putUE(0)  // num_y_partitions_minus1 = 0

        // Component 0 (I): poly_order = 2, [-612867, 9803467, 0]
        bw.putUE(0)  // mapping_idc = 0 (polynomial)
        bw.putUE(1)  // poly_order_minus1 = 1 (order 2)
        bw.putSECoef(-612867, log2Denom: log2Denom)
        bw.putSECoef(9_803_467, log2Denom: log2Denom)
        bw.putSECoef(0, log2Denom: log2Denom)

        // Components 1 & 2 (P, T): poly_order = 2, [-599187, 9584640, 0]
        for _ in 1..<3 {
            bw.putUE(0)  // mapping_idc = 0 (polynomial)
            bw.putUE(1)  // poly_order_minus1 = 1 (order 2)
            bw.putSECoef(-599187, log2Denom: log2Denom)
            bw.putSECoef(9_584_640, log2Denom: log2Denom)
            bw.putSECoef(0, log2Denom: log2Denom)
        }

        bw.writeDMHeaderAndFooter()

        let parsed = try #require(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()))
        #expect(parsed.sceneRefresh == true)
        #expect(parsed.sourceMinPQ == 7)
        #expect(parsed.sourceMaxPQ == 3079)

        guard case .curves(let curves) = parsed.reshapingCurvesState else {
            Issue.record("Expected .curves, got \(parsed.reshapingCurvesState)")
            return
        }
        #expect(curves.count == 3)
        let denom = Float(1 << log2Denom)
        #expect(abs(curves[0].polyCoeffs[0].x - (-612867.0 / denom)) < 1e-6)
        #expect(abs(curves[0].polyCoeffs[0].y - (9_803_467.0 / denom)) < 1e-6)
        #expect(abs(curves[1].polyCoeffs[0].x - (-599187.0 / denom)) < 1e-6)
        #expect(abs(curves[1].polyCoeffs[0].y - (9_584_640.0 / denom)) < 1e-6)

        guard case .matrix(let matrix) = parsed.colorMatrixState else {
            Issue.record("Expected .matrix, got \(parsed.colorMatrixState)")
            return
        }
        #expect(abs(matrix.yccToRgb[0][0] - 1.0) < 1e-5)
        #expect(abs(matrix.yccToRgb[1][0] - (799.0 / 8192.0)) < 1e-5)
        #expect(abs(matrix.yccToRgb[1][1] - (-933.0 / 8192.0)) < 1e-5)
        #expect(abs(matrix.rgbToLms[1][0] - (-349.0 / 16384.0)) < 1e-5)
        #expect(abs(matrix.yccToRgbOffset.y - 0.5) < 1e-5)
        #expect(abs(matrix.rgbToLms[0][0] - (17081.0 / 16384.0)) < 1e-5)
    }

    @Test("DolbyVisionRPUParser parses multi-piece pivot accumulation and polynomial coefficients")
    func testMultiPiecePivotAccumulationParsing() throws {
        let bw = BitWriter()
        let log2Denom = 23
        bw.writeRPUHeader(log2Denom: log2Denom, usePrevVdrRpu: false)

        bw.putUE(0)  // vdr_rpu_id
        bw.putUE(0)  // mapping_color_space
        bw.putUE(0)  // mapping_chroma_format_idc

        // Component 0: 3 pivots (0, 512, 1023), so 2 pieces
        bw.putUE(1)  // num_pivots_minus2 = 1 -> 3 pivots
        bw.putBits(0, count: 10)  // delta 0 = 0 -> accum = 0
        bw.putBits(512, count: 10)  // delta 1 = 512 -> accum = 512
        bw.putBits(511, count: 10)  // delta 2 = 511 -> accum = 1023

        // Components 1 & 2: 2 pivots (0, 1023), 1 piece each
        for _ in 1..<3 {
            bw.putUE(0)  // num_pivots_minus2 = 0 -> 2 pivots
            bw.putBits(0, count: 10)
            bw.putBits(1023, count: 10)
        }

        bw.putUE(0)  // num_x_partitions
        bw.putUE(0)  // num_y_partitions

        // Component 0: 2 polynomial pieces
        // Piece 0
        bw.putUE(0)  // mapping_idc = 0
        bw.putUE(1)  // poly_order_minus1 = 1
        bw.putSECoef(0, log2Denom: log2Denom)
        bw.putSECoef(1 << 23, log2Denom: log2Denom)
        bw.putSECoef(0, log2Denom: log2Denom)
        // Piece 1
        bw.putUE(0)  // mapping_idc = 0
        bw.putUE(1)  // poly_order_minus1 = 1
        bw.putSECoef(-1 << 22, log2Denom: log2Denom)
        bw.putSECoef(2 << 23, log2Denom: log2Denom)
        bw.putSECoef(0, log2Denom: log2Denom)

        // Components 1 & 2: 1 piece each
        for _ in 1..<3 {
            bw.putUE(0)
            bw.putUE(1)
            bw.putSECoef(0, log2Denom: log2Denom)
            bw.putSECoef(1 << 23, log2Denom: log2Denom)
            bw.putSECoef(0, log2Denom: log2Denom)
        }

        bw.writeDMHeaderAndFooter()

        let parsed = try #require(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()))
        guard case .curves(let curves) = parsed.reshapingCurvesState else {
            Issue.record("Expected .curves reshaping curves state")
            return
        }
        #expect(curves.count == 3)
        #expect(curves[0].pivots.count == 3)
        #expect(abs(curves[0].pivots[0] - 0.0) < 1e-5)
        #expect(abs(curves[0].pivots[1] - (512.0 / 1023.0)) < 1e-5)
        #expect(abs(curves[0].pivots[2] - 1.0) < 1e-5)
        #expect(curves[0].polyCoeffs.count == 2)
        #expect(abs(curves[0].polyCoeffs[0].y - 1.0) < 1e-5)
        #expect(abs(curves[0].polyCoeffs[1].y - 2.0) < 1e-5)
    }

    @Test("DolbyVisionRPUParser reads L1 of an RPU without vdr_seq_info but applies neither its curves nor matrices")
    func testMissingSequenceInfoParsing() throws {
        let bw = BitWriter()
        bw.writeRPUHeader(usePrevVdrRpu: false, hasSequenceInfo: false)
        bw.putUE(0)  // vdr_rpu_id
        bw.putUE(0)  // mapping_color_space
        bw.putUE(0)  // mapping_chroma_format_idc
        // The defaults the parser assumes: 10-bit pivots, 23 fraction bits.
        for _ in 0..<3 {
            bw.putUE(0)
            bw.putBits(0, count: 10)
            bw.putBits(1023, count: 10)
        }
        bw.putUE(0)  // num_x_partitions
        bw.putUE(0)  // num_y_partitions
        for _ in 0..<3 {
            bw.putUE(0)  // mapping_idc = 0 (polynomial)
            bw.putUE(1)  // poly_order_minus1 = 1
            bw.putSECoef(0, log2Denom: 23)
            bw.putSECoef(1 << 23, log2Denom: 23)
            bw.putSECoef(0, log2Denom: 23)
        }
        bw.writeDMHeaderAndFooter(hasL1: true)

        let parsed = try #require(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()))
        #expect(parsed.l1 != nil)
        #expect(parsed.reshapingCurvesState == .unsupported)
        #expect(parsed.colorMatrixState == .defaults)
        #expect(parsed.sourceMaxPQ == nil)
    }

    @Test(
        "DolbyVisionRPUParser applies float32 curves only with coefficients in CCM 001's range, keeping the RPU",
        arguments: [Float.nan, Float.infinity, 1e30, 0.5])
    func testFloatCoefficientRangeParsing(coefficient: Float) throws {
        let bw = BitWriter()
        bw.writeRPUHeader(usePrevVdrRpu: false, float32Coefficients: true)
        bw.putUE(0)  // vdr_rpu_id
        bw.putUE(0)  // mapping_color_space
        bw.putUE(0)  // mapping_chroma_format_idc
        for _ in 0..<3 {
            bw.putUE(0)
            bw.putBits(0, count: 10)
            bw.putBits(1023, count: 10)
        }
        bw.putUE(0)  // num_x_partitions
        bw.putUE(0)  // num_y_partitions
        for component in 0..<3 {
            bw.putUE(0)  // mapping_idc = 0 (polynomial)
            bw.putUE(0)  // poly_order_minus1 = 0
            bw.putBit(0)  // linear_interp_flag
            bw.putBits(component == 0 ? coefficient.bitPattern : Float(0).bitPattern, count: 32)
            bw.putBits(Float(1).bitPattern, count: 32)
        }
        bw.writeDMHeaderAndFooter(hasL1: true)

        let parsed = try #require(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()))
        #expect(parsed.l1 != nil)
        if coefficient == 0.5 {
            guard case .curves = parsed.reshapingCurvesState else {
                Issue.record("Expected .curves, got \(parsed.reshapingCurvesState)")
                return
            }
        } else {
            #expect(parsed.reshapingCurvesState == .unsupported)
        }
    }

    @Test("DolbyVisionRPUParser parses use_prev_vdr_rpu flag as reusePrevious")
    func testUsePrevVdrRpuFlagParsing() throws {
        let bw = BitWriter()
        bw.writeRPUHeader(usePrevVdrRpu: true)
        bw.putUE(0)  // prev_vdr_rpu_id = 0
        bw.writeDMHeaderAndFooter()

        let parsed = try #require(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()))
        #expect(parsed.reshapingCurvesState == .reusePrevious)
    }

    @Test("DolbyVisionRPUParser parses MMR chroma reshaping curves")
    func testMMRMappingParsing() throws {
        let bw = BitWriter()
        let log2Denom = 23
        bw.writeRPUHeader(log2Denom: log2Denom, usePrevVdrRpu: false)

        bw.putUE(0)  // vdr_rpu_id
        bw.putUE(0)  // mapping_color_space
        bw.putUE(0)  // mapping_chroma_format_idc

        // 3 components: 2 pivots each (1 piece)
        for _ in 0..<3 {
            bw.putUE(0)
            bw.putBits(0, count: 10)
            bw.putBits(1023, count: 10)
        }
        bw.putUE(0)
        bw.putUE(0)

        // Component 0: polynomial
        bw.putUE(0)
        bw.putUE(1)
        bw.putSECoef(0, log2Denom: log2Denom)
        bw.putSECoef(1 << 23, log2Denom: log2Denom)
        bw.putSECoef(0, log2Denom: log2Denom)

        // Component 1: MMR! mapping_idc = 1
        bw.putUE(1)  // mapping_idc = 1 (MMR)
        bw.putBits(0, count: 2)  // mmr_order_minus1 = 0 (order = 1)
        bw.putSECoef(1 << 22, log2Denom: log2Denom)  // mmr_constant = 0.5
        for i in 1...7 {
            bw.putSECoef(Int64(i) << 20, log2Denom: log2Denom)
        }

        // Component 2: polynomial
        bw.putUE(0)
        bw.putUE(1)
        bw.putSECoef(0, log2Denom: log2Denom)
        bw.putSECoef(1 << 23, log2Denom: log2Denom)
        bw.putSECoef(0, log2Denom: log2Denom)

        bw.writeDMHeaderAndFooter()

        let parsed = try #require(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()))
        guard case .curves(let curves) = parsed.reshapingCurvesState else {
            Issue.record("Expected .curves reshaping state")
            return
        }
        #expect(curves.count == 3)
        #expect(curves[0].mmr == nil)
        #expect(curves[1].mmr != nil)
        #expect(curves[1].mmr?.order == 1)
        #expect(abs(curves[1].mmr!.constant - 0.5) < 1e-4)
        #expect(curves[1].mmr?.coefs.count == 7)
    }

    @Test("DolbyVisionRPUParser rejects an RPU whose mapping layout is unknown instead of reading DM out of sync")
    func testUnknownMappingLayoutRejectsRPU() {
        let bw = BitWriter()
        let log2Denom = 23
        bw.writeRPUHeader(log2Denom: log2Denom, usePrevVdrRpu: false)

        bw.putUE(0)  // vdr_rpu_id
        bw.putUE(0)  // mapping_color_space
        bw.putUE(0)  // mapping_chroma_format_idc
        for _ in 0..<3 {
            bw.putUE(0)
            bw.putBits(0, count: 10)
            bw.putBits(1023, count: 10)
        }
        bw.putUE(0)
        bw.putUE(0)

        // Component 0: linear interpolation, whose layout the parser doesn't know
        bw.putUE(0)  // mapping_idc = 0
        bw.putUE(0)  // poly_order_minus1 = 0
        bw.putBit(1)  // linear_interp_flag = 1
        for _ in 1..<3 {
            bw.putUE(0)
            bw.putUE(1)
            bw.putSECoef(0, log2Denom: log2Denom)
            bw.putSECoef(1 << 23, log2Denom: log2Denom)
            bw.putSECoef(0, log2Denom: log2Denom)
        }

        bw.writeDMHeaderAndFooter(hasL1: true)

        #expect(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()) == nil)
    }

    @Test(
        "DolbyVisionRPUParser marks reshaping the shader can't apply as unsupported and keeps DM",
        arguments: [false, true])
    func testUnsupportedReshapingShapeKeepsDM(mmrOnLuma: Bool) throws {
        let bw = BitWriter()
        let log2Denom = 23
        bw.writeRPUHeader(log2Denom: log2Denom, usePrevVdrRpu: false)

        bw.putUE(0)  // vdr_rpu_id
        bw.putUE(0)  // mapping_color_space
        bw.putUE(0)  // mapping_chroma_format_idc
        // Component 1 has two pieces (3 pivots) unless MMR goes on I
        for c in 0..<3 {
            if c == 1 && !mmrOnLuma {
                bw.putUE(1)
                bw.putBits(0, count: 10)
                bw.putBits(512, count: 10)
                bw.putBits(511, count: 10)
            } else {
                bw.putUE(0)
                bw.putBits(0, count: 10)
                bw.putBits(1023, count: 10)
            }
        }
        bw.putUE(0)
        bw.putUE(0)

        func putPolynomial() {
            bw.putUE(0)
            bw.putUE(1)
            bw.putSECoef(0, log2Denom: log2Denom)
            bw.putSECoef(1 << 23, log2Denom: log2Denom)
            bw.putSECoef(0, log2Denom: log2Denom)
        }
        func putMMR() {
            bw.putUE(1)  // mapping_idc = 1 (MMR)
            bw.putBits(0, count: 2)  // mmr_order_minus1 = 0
            bw.putSECoef(1 << 22, log2Denom: log2Denom)
            for i in 1...7 { bw.putSECoef(Int64(i) << 20, log2Denom: log2Denom) }
        }

        if mmrOnLuma {
            putMMR()
            putPolynomial()
        } else {
            putPolynomial()
            // Component 1: a polynomial piece and an MMR piece
            putPolynomial()
            putMMR()
        }
        putPolynomial()

        bw.writeDMHeaderAndFooter(hasL1: true)

        let parsed = try #require(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()))
        #expect(parsed.reshapingCurvesState == .unsupported)
        #expect(parsed.sourceMaxPQ == 3079)
        #expect(parsed.l1?.maxPQ == 3000)
    }

    @Test("DolbyVisionRPUParser parses Profile 7 FEL (disableResidual == 0 with NLQ) without dropping L1 metadata")
    func testProfile7FELWithNLQExtractsL1Metadata() throws {
        let bw = BitWriter()
        let log2Denom = 23
        bw.writeRPUHeader(log2Denom: log2Denom, usePrevVdrRpu: false, disableResidual: false)

        bw.putUE(0)  // vdr_rpu_id
        bw.putUE(0)  // mapping_color_space
        bw.putUE(0)  // mapping_chroma_format_idc

        // 3 components: 2 pivots each
        for _ in 0..<3 {
            bw.putUE(0)
            bw.putBits(0, count: 10)
            bw.putBits(1023, count: 10)
        }

        // NLQ header (since useNLQ is true)
        bw.putBits(0, count: 3)  // nlq_method_idc = 0
        bw.putBits(0, count: 10)  // nlq_pivots[0]
        bw.putBits(1023, count: 10)  // nlq_pivots[1]

        bw.putUE(0)  // num_x_partitions
        bw.putUE(0)  // num_y_partitions

        // 3 components: 1 piece each
        for _ in 0..<3 {
            bw.putUE(0)
            bw.putUE(1)
            bw.putSECoef(0, log2Denom: log2Denom)
            bw.putSECoef(1 << 23, log2Denom: log2Denom)
            bw.putSECoef(0, log2Denom: log2Denom)
        }

        // NLQ component params (since useNLQ is true): 3 components
        for _ in 0..<3 {
            bw.putBits(0, count: 10)  // nlq_offset (el_bit_depth = 10)
            bw.putUE(0)  // vdr_in_max (ipart = 0)
            bw.putBits(0, count: log2Denom)  // vdr_in_max fpart
            // nlq_method_idc == 0: linear deadzone params
            bw.putUE(0)  // slope ipart
            bw.putBits(0, count: log2Denom)  // slope fpart
            bw.putUE(0)  // threshold ipart
            bw.putBits(0, count: log2Denom)  // threshold fpart
        }

        bw.writeDMHeaderAndFooter(hasL1: true)

        let parsed = try #require(DolbyVisionRPUParser.parse(naluData: bw.ebspNALUnit()))
        #expect(parsed.reshapingCurvesState == .unsupported)
        #expect(parsed.l1 != nil)
        #expect(parsed.l1?.minPQ == 10)
        #expect(parsed.l1?.maxPQ == 3000)
        #expect(parsed.l1?.avgPQ == 1200)
    }

    @Test("PlayerEngine resets dynamic tone mapping state on stop()")
    @MainActor
    func testPlayerEngineToneMappingReset() {
        let engine = PlayerEngine.makeForTesting()
        #expect(engine.toneMapping.targetNits == 203.0)
        engine.toneMapping.adapt(toPeakNits: 451.0, fallNits: 68.0, hasStaticPeak: true)
        #expect(engine.toneMapping.targetNits < 203.0)
        engine.stop()
        #expect(engine.toneMapping.targetNits == 203.0)
        #expect(engine.toneMapping.baseTargetNits == 203.0)
    }

    @Test("A dim media's shadow lift applies while the user sets none and goes with the media")
    @MainActor
    func mediaShadowLiftIsReset() {
        let engine = PlayerEngine.makeForTesting()
        let toneMapping = engine.toneMapping

        toneMapping.adapt(toPeakNits: 451.0, fallNits: 68.0, hasStaticPeak: true)
        #expect(toneMapping.appliedShadowLift == ToneMapController.lowFallShadowLift)
        #expect(
            engine.metalRenderer.map { $0.uniforms.outputShadowLift } ?? toneMapping.appliedShadowLift
                == ToneMapController.lowFallShadowLift)

        toneMapping.shadowLift = 0.02
        #expect(toneMapping.appliedShadowLift == 0.02)
        // 0 is the user's: no lift at all, even on a dim media.
        toneMapping.shadowLift = 0
        #expect(toneMapping.appliedShadowLift == 0)
        #expect(engine.metalRenderer.map { $0.uniforms.outputShadowLift } ?? 0 == 0)
        toneMapping.shadowLift = nil
        #expect(toneMapping.appliedShadowLift == ToneMapController.lowFallShadowLift)

        // The next media isn't dim: it must not keep the previous one's lift.
        toneMapping.adapt(toPeakNits: 1000.0, fallNits: 161.0, hasStaticPeak: true)
        #expect(toneMapping.appliedShadowLift == 0)
        #expect(engine.metalRenderer.map { $0.uniforms.outputShadowLift } ?? 0 == 0)

        toneMapping.adapt(toPeakNits: 451.0, fallNits: 68.0, hasStaticPeak: true)
        engine.stop()
        #expect(toneMapping.appliedShadowLift == 0)
    }

    @Test("Re-applying the configuration keeps the smoothed Dolby Vision target and the settings changed since")
    @MainActor
    func reappliedConfigurationKeepsState() {
        let configuration = PlayerConfiguration(targetNitsScale: 1.5)
        let engine = PlayerEngine.makeForTesting(configuration: configuration)
        let toneMapping = engine.toneMapping
        let l1 = DolbyVisionFrameMetadata(
            sceneRefresh: true, l1: DolbyVisionFrameMetadata.Level1(minPQ: 0, maxPQ: 2400, avgPQ: 1000), l2Trims: [])
        _ = toneMapping.applyFrame(doviMetadata: l1)
        let smoothedTarget = toneMapping.frameState.withLock { $0.smoothedTargetNits }
        toneMapping.sharpness = 0.9

        // Another setting changes: the tone-mapping ones are those of before.
        var changed = configuration
        changed.seekStepSeconds += 1
        engine.applyConfiguration(changed)
        #expect(toneMapping.frameState.withLock { $0.smoothedTargetNits } == smoothedTarget)
        #expect(toneMapping.sharpness == 0.9)

        // A setting changed in the configuration applies.
        changed.sharpness = 0.2
        engine.applyConfiguration(changed)
        #expect(toneMapping.sharpness == 0.2)
    }

    @Test("The monitor reports the scaled target white after a reset and a render mode switch")
    @MainActor
    func monitorReportsScaledTarget() {
        // A monitor of its own: the shared one is written by the tests running alongside.
        let monitor = PlayerPerformanceMonitor()
        let toneMapping = ToneMapController(renderer: nil, monitor: monitor)
        toneMapping.apply(PlayerConfiguration(targetNitsScale: 1.5))
        toneMapping.adapt(toPeakNits: 1000.0, fallNits: 161.0, hasStaticPeak: true)
        toneMapping.reset()
        #expect(abs(monitor.currentMetrics.targetNits - 203.0 * 1.5) < 0.01)
        toneMapping.renderModeDidChange(to: .metalToneMap)
        #expect(abs(monitor.currentMetrics.targetNits - 203.0 * 1.5) < 0.01)
    }
}
