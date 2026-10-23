import Foundation
import simd

/// Fast parser for Dolby Vision RPU payloads (NAL unit 62). The order and width of the fields follow the RPU format;
/// ETSI GS CCM 001 gives the semantics of the values (pivots, coefficients, NLQ parameters, the DM signal description),
/// not the RPU bitstream, so its clauses are cited for what a value means.
public enum DolbyVisionRPUParser {
    /// SMPTE ST 2084 PQ to Linear optical nits conversion.
    public static func pqToNits(_ pq: Float) -> Float {
        guard pq > 0.0 else { return 0.0 }
        let c1: Float = 0.8359375
        let c2: Float = 18.8515625
        let c3: Float = 18.6875
        let m1: Float = 0.1593017578125
        let m2: Float = 78.84375

        let p = pow(max(pq, 0.0), 1.0 / m2)
        let num = max(p - c1, 0.0)
        let den = max(c2 - c3 * p, 1e-6)
        let l = pow(num / den, 1.0 / m1)
        return l * 10000.0
    }

    private final class BitReader {
        private let data: [UInt8]
        private(set) var bitPos: Int = 0

        init(data: [UInt8]) {
            self.data = data
        }

        var isEOF: Bool {
            (bitPos >> 3) >= data.count
        }

        func skipBits(_ n: Int) -> Bool {
            guard n >= 0 else { return false }
            let nextPos = bitPos + n
            guard ((nextPos + 7) >> 3) <= data.count else { return false }
            bitPos = nextPos
            return true
        }

        func getBits(_ n: Int) -> UInt32? {
            guard n > 0 else { return 0 }
            var res: UInt32 = 0
            for _ in 0..<n {
                let byteIdx = bitPos >> 3
                guard byteIdx < data.count else { return nil }
                let bitIdx = 7 - (bitPos & 7)
                let bit = UInt32((data[byteIdx] >> bitIdx) & 1)
                res = (res << 1) | bit
                bitPos += 1
            }
            return res
        }

        func getBits1() -> UInt32? {
            let byteIdx = bitPos >> 3
            guard byteIdx < data.count else { return nil }
            let bitIdx = 7 - (bitPos & 7)
            let bit = UInt32((data[byteIdx] >> bitIdx) & 1)
            bitPos += 1
            return bit
        }

        func getSBits(_ n: Int) -> Int32? {
            guard (1...32).contains(n), let v = getBits(n) else { return nil }
            let shift = UInt32(32 - n)
            return Int32(bitPattern: v << shift) >> shift
        }

        func getUE() -> UInt32? {
            var zeros = 0
            while zeros < 32 {
                guard let b = getBits1() else { return nil }
                if b != 0 { break }
                zeros += 1
            }
            if zeros == 0 { return 0 }
            if zeros >= 32 { return nil }
            guard let suffix = getBits(zeros) else { return nil }
            return (UInt32(1) << zeros) - 1 + suffix
        }

        func getSE() -> Int32? {
            guard let ue = getUE() else { return nil }
            if (ue & 1) != 0 {
                return Int32((ue + 1) >> 1)
            } else {
                return -Int32(ue >> 1)
            }
        }

        func align() {
            let rem = bitPos & 7
            if rem != 0 {
                bitPos += (8 - rem)
            }
        }
    }

    /// Unescapes 3-byte emulation prevention sequences (0x00, 0x00, 0x03 -> 0x00, 0x00).
    public static func unescapeRPU(from raw: Data) -> [UInt8] {
        var unescaped = [UInt8]()
        unescaped.reserveCapacity(raw.count)
        var i = 0
        raw.withUnsafeBytes { ptr in
            guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            while i < count {
                if i + 2 < count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 3 {
                    unescaped.append(0)
                    unescaped.append(0)
                    i += 3
                } else {
                    unescaped.append(bytes[i])
                    i += 1
                }
            }
        }
        return unescaped
    }

    /// What the RPU header (`vdr_seq_info`) tells the rest of the RPU. Without it, the defaults stand.
    private struct Header {
        enum CoefficientFormat {
            /// A signed integer part and a fraction of `fractionBits` bits (`coefficient_log2_denom`).
            case fixedPoint(fractionBits: Int)
            /// An IEEE 754 single.
            case float32
        }

        var coefficientFormat = CoefficientFormat.fixedPoint(fractionBits: 23)
        var blBitDepth = 10
        var elBitDepth = 10
        /// Whether an enhancement-layer residual is added to the mapped base layer (`disable_residual_flag` 0), which
        /// puts the NLQ parameters after the mapping.
        var hasResidual = false
        /// 0: the DM data carries the signal description (matrices, source range); 1: it reuses the previous one.
        var dmCompression: UInt32 = 0
        /// Whether the RPU carries `vdr_seq_info`; without it the rest is read with the defaults above.
        var hasSequenceInfo = false
    }

    /// One piece of a component's mapping (ETSI GS CCM 001 5.3.3).
    private enum MappingPiece {
        /// Polynomial coefficients `(c0, c1, c2)`, `c2` 0 for a first-order one.
        case polynomial(SIMD3<Float>)
        case mmr(DolbyVisionFrameMetadata.MMRPiece)
    }

    /// The DM data's description of the signal: the colour matrices (when authored) and the source display's range.
    private struct SignalDescription {
        var colorMatrix: DolbyVisionFrameMetadata.ColorMatrix?
        var sourceMinPQ: UInt16?
        var sourceMaxPQ: UInt16?
    }

    /// Parses a raw NAL unit 62 (Dolby Vision RPU) and extracts L1, L2, reshaping curves, and color matrices.
    public static func parse(naluData: Data) -> DolbyVisionFrameMetadata? {
        guard naluData.count >= 6 else { return nil }
        let unescaped = unescapeRPU(from: naluData)
        guard unescaped.count >= 4 else { return nil }

        // Skip 2-byte NAL header if present (type 62 has nal_unit_type = 62)
        var payloadOffset = 0
        let firstNalType = (unescaped[0] >> 1) & 0x3F
        if firstNalType == 62 {
            payloadOffset = 2
        }

        guard payloadOffset < unescaped.count else { return nil }
        let payloadBytes: [UInt8]
        if unescaped[payloadOffset] == 25 {
            // NAL prefix byte 0x19 per SMPTE RPU spec
            payloadBytes = Array(unescaped[(payloadOffset + 1)...])
        } else {
            payloadBytes = Array(unescaped[payloadOffset...])
        }

        let br = BitReader(data: payloadBytes)
        guard let header = readHeader(br),
            let vdrDmMetadataPresent = br.getBits1(),
            let usePrevVdrRpu = br.getBits1()
        else { return nil }

        let curvesState: DolbyVisionFrameMetadata.ReshapingCurvesState
        if usePrevVdrRpu == 0 {
            guard let state = readMapping(br, header: header) else { return nil }
            curvesState = state
        } else {
            // Commercial Dolby Vision streams use a single RPU ID (id = 0), so reusing the last active
            // curves avoids maintaining an array of 16 RPU contexts.
            guard br.getUE() != nil else { return nil }  // prev_vdr_rpu_id
            curvesState = .reusePrevious
        }

        guard vdrDmMetadataPresent != 0 else { return nil }

        guard br.getUE() != nil,  // affected_dm_id
            br.getUE() != nil,  // current_dm_id
            let sceneRefreshUE = br.getUE()
        else { return nil }
        let sceneRefresh = sceneRefreshUE != 0

        let signal: SignalDescription
        let colorMatrixState: DolbyVisionFrameMetadata.ColorMatrixState
        if header.dmCompression == 0 {
            guard let description = readSignalDescription(br) else { return nil }
            // Read after a mapping of guessed widths without vdr_seq_info, the description may be off: neither its
            // matrices nor its source range are taken.
            signal = header.hasSequenceInfo ? description : SignalDescription()
            if let matrix = signal.colorMatrix {
                colorMatrixState = .matrix(matrix)
            } else {
                colorMatrixState = .defaults
            }
        } else {
            // Commercial Dolby Vision streams use a single color matrix configuration; dm_compression == 1
            // indicates reusing the previous matrix.
            signal = SignalDescription()
            colorMatrixState = .reusePrevious
        }

        guard let numExtBlocksUE = br.getUE(), numExtBlocksUE <= 32 else { return nil }
        let numExtBlocks = Int(numExtBlocksUE)
        br.align()

        var l1: DolbyVisionFrameMetadata.Level1? = nil
        var l2Trims = [DolbyVisionFrameMetadata.Level2Trim]()

        for _ in 0..<numExtBlocks {
            guard let extLenUE = br.getUE(),
                let levelU32 = br.getBits(8)
            else { return nil }
            let extLen = Int(extLenUE)
            let level = Int(levelU32)
            let startBit = br.bitPos

            if level == 1 && extLen >= 5 {
                guard let minPQ = br.getBits(12),
                    let maxPQ = br.getBits(12),
                    let avgPQ = br.getBits(12)
                else { return nil }
                l1 = DolbyVisionFrameMetadata.Level1(
                    minPQ: UInt16(minPQ),
                    maxPQ: UInt16(maxPQ),
                    avgPQ: UInt16(avgPQ)
                )
            } else if level == 2 && extLen >= 11 {
                guard let targetMaxPQ = br.getBits(12),
                    let slope = br.getBits(12),
                    let offset = br.getBits(12),
                    let power = br.getBits(12),
                    let chromaWeight = br.getBits(12),
                    let satGain = br.getBits(12),
                    br.getSBits(13) != nil  // ms_weight
                else { return nil }
                let trim = DolbyVisionFrameMetadata.Level2Trim(
                    targetMaxPQ: UInt16(targetMaxPQ),
                    trimSlope: UInt16(slope),
                    trimOffset: UInt16(offset),
                    trimPower: UInt16(power),
                    trimChromaWeight: UInt16(chromaWeight),
                    trimSaturationGain: UInt16(satGain)
                )
                l2Trims.append(trim)
            }

            let bitsRead = br.bitPos - startBit
            let totalBits = extLen * 8
            if totalBits > bitsRead {
                guard br.skipBits(totalBits - bitsRead) else { return nil }
            }
        }

        return DolbyVisionFrameMetadata(
            sceneRefresh: sceneRefresh,
            l1: l1,
            l2Trims: l2Trims,
            sourceMinPQ: signal.sourceMinPQ,
            sourceMaxPQ: signal.sourceMaxPQ,
            reshapingCurvesState: curvesState,
            colorMatrixState: colorMatrixState
        )
    }

    /// Reads the RPU type and format and, when present, `vdr_seq_info`; nil for an RPU this parser doesn't read. The
    /// parser keeps no state between RPUs, so one without `vdr_seq_info` is read with the defaults (10-bit base layer,
    /// 23 fraction bits, `dm_compression` 0): its curves, matrices and source range aren't taken, and with a
    /// `dm_compression` other than the default its DM data reads wrong, mostly failing the RPU. Profile 5 and 8 streams
    /// carry it in every RPU.
    private static func readHeader(_ br: BitReader) -> Header? {
        guard let rpuType = br.getBits(6), rpuType == 2 else { return nil }

        guard let rpuFormat = br.getBits(11),
            br.getBits(4) != nil,  // vdr_rpu_profile
            br.getBits(4) != nil,  // vdr_rpu_level
            let vdrSeqInfoPresent = br.getBits1()
        else { return nil }

        var header = Header()
        guard vdrSeqInfoPresent != 0 else { return header }
        header.hasSequenceInfo = true

        guard br.getBits1() != nil,  // chroma_resampling_explicit_filter_flag
            let coefficientDataType = br.getBits(2)
        else { return nil }
        switch coefficientDataType {
        case 0:
            // CCM 001 5.3.2 allows EL_bit_depth + 5 ... 32. It comes before the EL bit depth, and Profiles 5 and 8 have
            // no EL, so the bound for the smallest (8-bit) EL is checked; 32 is also the widest fraction read.
            guard let log2Denom = br.getUE(), (13...32).contains(log2Denom) else { return nil }
            header.coefficientFormat = .fixedPoint(fractionBits: Int(log2Denom))
        case 1:
            header.coefficientFormat = .float32
        default:
            return nil
        }
        guard br.getBits(2) != nil,  // vdr_rpu_normalized_idc
            br.getBits1() != nil,  // bl_video_full_range_flag
            (rpuFormat & 0x700) == 0
        else { return nil }

        // The upper bits of el_bit_depth_minus8 carry ext_mapping_idc in newer streams.
        guard let blBitDepthMinus8 = br.getUE(), blBitDepthMinus8 <= 8,
            let elBitDepthMinus8 = br.getUE(),
            br.getUE() != nil,  // vdr_bit_depth_minus8
            br.getBits1() != nil,  // spatial_resampling_filter_flag
            let dmCompression = br.getBits(3), dmCompression <= 1,
            br.getBits1() != nil,  // el_spatial_resampling_filter_flag
            let disableResidual = br.getBits1()
        else { return nil }
        header.blBitDepth = Int(blBitDepthMinus8) + 8
        header.elBitDepth = Int(elBitDepthMinus8 & 0xFF) + 8
        header.hasResidual = disableResidual == 0
        header.dmCompression = dmCompression
        // NLQ reads EL_bit_depth-bit values: an out-of-range depth leaves the rest unreadable.
        guard !header.hasResidual || header.elBitDepth <= 16 else { return nil }
        return header
    }

    /// Reads the mapping (`rpu_data_mapping`, and `rpu_data_nlq` with a residual) of an RPU that doesn't reuse the
    /// previous one: the reshaping curves when the shader can apply them, `.unsupported` when they read fine but it
    /// can't; nil when the rest of the RPU is unreadable.
    private static func readMapping(
        _ br: BitReader, header: Header
    ) -> DolbyVisionFrameMetadata.ReshapingCurvesState? {
        guard br.getUE() != nil,  // vdr_rpu_id
            br.getUE() != nil,  // mapping_color_space
            br.getUE() != nil  // mapping_chroma_format_idc
        else { return nil }

        // CCM 001 5.3.2: each pred_pivot_value adds to the previous pivot; normalized to the base layer's range here.
        let pivotScale = 1.0 / Float((1 << header.blBitDepth) - 1)
        var componentPivots: [[Float]] = []
        for _ in 0..<3 {
            // The shader holds 8 pieces (9 pivots) per component.
            guard let numPivotsMinus2 = br.getUE(), numPivotsMinus2 <= 7 else { return nil }
            var pivot: UInt32 = 0
            var pivots: [Float] = []
            for _ in 0..<(Int(numPivotsMinus2) + 2) {
                guard let delta = br.getBits(header.blBitDepth) else { return nil }
                pivot += delta
                pivots.append(Float(pivot) * pivotScale)
            }
            componentPivots.append(pivots)
        }

        if header.hasResidual {
            // nlq_method_idc 0 (NLQ_LINEAR_DZ) is the only one defined; its two pivots bound the residual.
            guard let nlqMethodIdc = br.getBits(3), nlqMethodIdc == 0,
                br.getBits(header.blBitDepth) != nil,
                br.getBits(header.blBitDepth) != nil
            else { return nil }
        }

        guard br.getUE() != nil,  // num_x_partitions_minus1
            br.getUE() != nil  // num_y_partitions_minus1
        else { return nil }

        var curves: [DolbyVisionFrameMetadata.ReshapingCurve] = []
        for (component, pivots) in componentPivots.enumerated() {
            var pieces: [MappingPiece] = []
            for _ in 1..<pivots.count {
                guard let piece = readMappingPiece(br, format: header.coefficientFormat) else { return nil }
                pieces.append(piece)
            }
            if let curve = reshapingCurve(component: component, pivots: pivots, pieces: pieces) {
                curves.append(curve)
            }
        }

        if header.hasResidual {
            // rpu_data_nlq, per component: nlq_offset, hdr_in_max, linear_deadzone_slope and linear_deadzone_threshold
            // (semantics in CCM 001 5.3.4).
            for _ in 0..<3 {
                guard br.getBits(header.elBitDepth) != nil,
                    skipUnsignedCoefficient(br, format: header.coefficientFormat),
                    skipUnsignedCoefficient(br, format: header.coefficientFormat),
                    skipUnsignedCoefficient(br, format: header.coefficientFormat)
                else { return nil }
            }
            // The picture needs the enhancement layer's residual, which isn't decoded: the base layer's reshaping
            // alone would be wrong.
            return .unsupported
        }
        // Without vdr_seq_info the bit depth and fraction bits are guessed: the curves may be wrong.
        return curves.count == 3 && header.hasSequenceInfo ? .curves(curves) : .unsupported
    }

    /// Reads one piece of a component's mapping; nil for one this parser can't read (linear interpolation, an order
    /// or `mapping_idc` CCM 001 doesn't define), which leaves the bit position, so the rest of the RPU, unknown.
    private static func readMappingPiece(_ br: BitReader, format: Header.CoefficientFormat) -> MappingPiece? {
        guard let mappingIdc = br.getUE() else { return nil }
        switch mappingIdc {
        case 0:
            guard let polyOrderMinus1 = br.getUE(), polyOrderMinus1 <= 1 else { return nil }
            if polyOrderMinus1 == 0 {
                guard let linearInterpolation = br.getBits1(), linearInterpolation == 0 else { return nil }
            }
            var coefficients = SIMD3<Float>.zero
            for i in 0...(Int(polyOrderMinus1) + 1) {
                guard let coefficient = readCoefficient(br, format: format) else { return nil }
                coefficients[i] = coefficient
            }
            return .polynomial(coefficients)
        case 1:
            guard let mmrOrderMinus1 = br.getBits(2), mmrOrderMinus1 <= 2,
                let constant = readCoefficient(br, format: format)
            else { return nil }
            let order = Int(mmrOrderMinus1) + 1
            var coefficients: [Float] = []
            for _ in 0..<(order * 7) {
                guard let coefficient = readCoefficient(br, format: format) else { return nil }
                coefficients.append(coefficient)
            }
            return .mmr(DolbyVisionFrameMetadata.MMRPiece(order: order, constant: constant, coefs: coefficients))
        default:
            return nil
        }
    }

    /// The curve of `component` the shader applies; nil for a mapping it can't: the shader reshapes I with polynomial
    /// pieces only, and P / T with polynomial pieces or one MMR piece spanning the component. A mapping of zero
    /// polynomials is no curve either, nor one with a coefficient out of CCM 001's range (NaN included), which could
    /// overflow the shader's sums into a NaN it can't clamp away.
    private static func reshapingCurve(
        component: Int, pivots: [Float], pieces: [MappingPiece]
    ) -> DolbyVisionFrameMetadata.ReshapingCurve? {
        if case .mmr(let mmr) = pieces.first, pieces.count == 1, component > 0 {
            guard ([mmr.constant] + mmr.coefs).allSatisfy(isValidMMRCoefficient) else { return nil }
            return DolbyVisionFrameMetadata.ReshapingCurve(pivots: pivots, mmr: mmr)
        }
        var polynomials: [SIMD3<Float>] = []
        for piece in pieces {
            guard case .polynomial(let coefficients) = piece,
                [coefficients.x, coefficients.y, coefficients.z].allSatisfy(isValidPolynomialCoefficient)
            else { return nil }
            polynomials.append(coefficients)
        }
        guard polynomials.contains(where: { $0 != .zero }) else { return nil }
        return DolbyVisionFrameMetadata.ReshapingCurve(pivots: pivots, polyCoeffs: polynomials)
    }

    /// CCM 001 5.3.3.2: `poly_coef_int` is -64 ... 63, so a coefficient is in [-64, 64); false for NaN.
    private static func isValidPolynomialCoefficient(_ value: Float) -> Bool {
        value >= -64 && value < 64
    }

    /// CCM 001 5.3.3.3: `mmr_constant_int` and `mmr_coef_int` are -65 536 ... 65 535; false for NaN.
    private static func isValidMMRCoefficient(_ value: Float) -> Bool {
        value >= -65_536 && value < 65_536
    }

    /// A signed mapping coefficient: CCM 001 5.3.3, `(int << coefficient_log2_denom) + fraction`.
    private static func readCoefficient(_ br: BitReader, format: Header.CoefficientFormat) -> Float? {
        switch format {
        case .fixedPoint(let fractionBits):
            guard let integer = br.getSE(), let fraction = br.getBits(fractionBits) else { return nil }
            return Float(integer) + Float(fraction) / Float(UInt64(1) << fractionBits)
        case .float32:
            return br.getBits(32).map { Float(bitPattern: $0) }
        }
    }

    /// Skips an unsigned coefficient (the NLQ ones): an unsigned integer part, else as `readCoefficient`.
    private static func skipUnsignedCoefficient(_ br: BitReader, format: Header.CoefficientFormat) -> Bool {
        switch format {
        case .fixedPoint(let fractionBits):
            br.getUE() != nil && br.skipBits(fractionBits)
        case .float32:
            br.skipBits(32)
        }
    }

    /// Reads the DM data's signal description (`dm_compression` 0): the colour matrices, the signal's coding and the
    /// source display's PQ range (semantics in CCM 001 6.2.2; its byte layout, 6.2.1, is not the RPU's).
    private static func readSignalDescription(_ br: BitReader) -> SignalDescription? {
        // ycc_to_rgb_coef: Short, 1 = 8192; ycc_to_rgb_offset: unsigned 32-bit, in 2^28 units for Profile 5 (Profile 4
        // uses 2^30; the matrix is applied to Profile 5 only); rgb_to_lms_coef: Short, 1 = 16384.
        guard let yccToRgb = readMatrix(br, scale: 1.0 / 8192.0) else { return nil }
        var yccToRgbOffset = SIMD3<Float>.zero
        for i in 0..<3 {
            guard let offset = br.getBits(32) else { return nil }
            yccToRgbOffset[i] = Float(offset) / Float(UInt64(1) << 28)
        }
        guard let rgbToLms = readMatrix(br, scale: 1.0 / 16384.0),
            br.getBits(16) != nil,  // signal_eotf
            br.getBits(16) != nil,  // signal_eotf_param0
            br.getBits(16) != nil,  // signal_eotf_param1
            br.getBits(32) != nil,  // signal_eotf_param2
            br.getBits(5) != nil,  // signal_bit_depth
            br.getBits(2) != nil,  // signal_color_space
            br.getBits(2) != nil,  // signal_chroma_format
            br.getBits(2) != nil,  // signal_full_range_flag
            let sourceMinPQ = br.getBits(12),
            let sourceMaxPQ = br.getBits(12),
            br.getBits(10) != nil  // source_diagonal
        else { return nil }

        var description = SignalDescription()
        // An all-zero matrix is no matrix: the defaults stand.
        let zero = simd_float3x3()
        if yccToRgb != zero && rgbToLms != zero {
            description.colorMatrix = DolbyVisionFrameMetadata.ColorMatrix(
                yccToRgb: yccToRgb, yccToRgbOffset: yccToRgbOffset, rgbToLms: rgbToLms)
        }
        if sourceMaxPQ > 0 {
            description.sourceMinPQ = UInt16(sourceMinPQ)
            description.sourceMaxPQ = UInt16(sourceMaxPQ)
        }
        return description
    }

    /// Reads a 3×3 matrix of signed 16-bit coefficients, row by row, scaled by `scale`.
    private static func readMatrix(_ br: BitReader, scale: Float) -> simd_float3x3? {
        var rows: [SIMD3<Float>] = []
        for _ in 0..<3 {
            var row = SIMD3<Float>.zero
            for i in 0..<3 {
                guard let value = br.getSBits(16) else { return nil }
                row[i] = Float(value) * scale
            }
            rows.append(row)
        }
        return simd_float3x3(rows: rows)
    }
}
