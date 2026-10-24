import Foundation
import simd

/// Extracted Dolby Vision dynamic metadata per-frame from RPU (NAL unit 62).
public struct DolbyVisionFrameMetadata: Sendable, Equatable {
    /// Multivariate Multiple Regression (MMR) parameters for higher-order chroma reshaping (ETSI GS CCM 001).
    public struct MMRPiece: Sendable, Equatable {
        public let order: Int  // 1, 2, or 3
        public let constant: Float
        public let coefs: [Float]  // 7 * order coefficients

        public init(order: Int, constant: Float, coefs: [Float]) {
            self.order = order
            self.constant = constant
            self.coefs = coefs
        }
    }

    /// Reshaping curve for one base-layer component (`I`, `P`, `T` or `Y`, `Cb`, `Cr`).
    public struct ReshapingCurve: Sendable, Equatable {
        /// Normalized pivot boundaries in `[0, 1]` (`numPieces + 1` elements, sorted ascending).
        public let pivots: [Float]
        /// Polynomial coefficients `(c0, c1, c2)` for each piece (when mapping is polynomial).
        public let polyCoeffs: [SIMD3<Float>]
        /// The MMR piece spanning this chroma component (when mapping is MMR).
        public let mmr: MMRPiece?

        public init(pivots: [Float], polyCoeffs: [SIMD3<Float>] = [], mmr: MMRPiece? = nil) {
            self.pivots = pivots
            self.polyCoeffs = polyCoeffs
            self.mmr = mmr
        }
    }

    /// Custom Dolby Vision RPU color matrices (`ycc_to_rgb_matrix`, `ycc_to_rgb_offset`, `rgb_to_lms_matrix`).
    public struct ColorMatrix: Sendable, Equatable {
        public let yccToRgb: simd_float3x3
        public let yccToRgbOffset: SIMD3<Float>
        public let rgbToLms: simd_float3x3

        public init(yccToRgb: simd_float3x3, yccToRgbOffset: SIMD3<Float>, rgbToLms: simd_float3x3) {
            self.yccToRgb = yccToRgb
            self.yccToRgbOffset = yccToRgbOffset
            self.rgbToLms = rgbToLms
        }
    }

    /// Level 1: Per-frame brightness metadata (SMPTE ST 2084 PQ domain)
    public struct Level1: Sendable, Equatable {
        public let minPQ: UInt16
        public let maxPQ: UInt16
        public let avgPQ: UInt16

        public let minNits: Float
        public let maxNits: Float
        public let avgNits: Float

        public init(minPQ: UInt16, maxPQ: UInt16, avgPQ: UInt16) {
            self.minPQ = minPQ
            self.maxPQ = maxPQ
            self.avgPQ = avgPQ
            self.minNits = DolbyVisionRPUParser.pqToNits(Float(minPQ) / 4095.0)
            self.maxNits = DolbyVisionRPUParser.pqToNits(Float(maxPQ) / 4095.0)
            self.avgNits = DolbyVisionRPUParser.pqToNits(Float(avgPQ) / 4095.0)
        }
    }

    /// Level 2: Target display trim pass (slope, offset, power) per SMPTE ST 2094-10.
    public struct Level2Trim: Sendable, Equatable {
        public let targetMaxPQ: UInt16
        public let targetNits: Float
        public let slope: Float  // S = trimSlope / 4096.0 + 0.5 (neutral 2048 -> 1.0)
        public let offset: Float  // O = trimOffset / 4096.0 - 0.5 (neutral 2048 -> 0.0)
        public let power: Float  // P = trimPower / 4096.0 + 0.5 (neutral 2048 -> 1.0)
        public let chromaWeight: Float  // CW = trimChromaWeight / 4096.0 - 0.5 (neutral 2048 -> 0.0)
        public let saturationGain: Float  // SG = trimSaturationGain / 4096.0 - 0.5 (neutral 2048 -> 0.0)

        public init(
            targetMaxPQ: UInt16,
            trimSlope: UInt16,
            trimOffset: UInt16,
            trimPower: UInt16,
            trimChromaWeight: UInt16,
            trimSaturationGain: UInt16
        ) {
            self.targetMaxPQ = targetMaxPQ
            self.targetNits = DolbyVisionRPUParser.pqToNits(Float(targetMaxPQ) / 4095.0)
            // SMPTE ST 2094-10 (Clause 6.2 & ETSI TS 103 572) inverse conversion:
            // trim_slope = Clip3(0, 4095, Round((S - 0.5) * 4096)) => S = trim_slope / 4096 + 0.5
            // trim_offset = Clip3(0, 4095, Round((O + 0.5) * 4096)) => O = trim_offset / 4096 - 0.5
            // trim_power = Clip3(0, 4095, Round((P - 0.5) * 4096)) => P = trim_power / 4096 + 0.5
            // trim_chroma_weight = Clip3(0, 4095, Round((CW + 0.5) * 4096)) => CW = trim_chroma_weight / 4096 - 0.5
            // trim_saturation_gain = Clip3(0, 4095, Round((SG + 0.5) * 4096)) => SG = trim_saturation_gain / 4096 - 0.5
            self.slope = (Float(trimSlope) / 4096.0) + 0.5
            self.offset = (Float(trimOffset) / 4096.0) - 0.5
            self.power = (Float(trimPower) / 4096.0) + 0.5
            self.chromaWeight = (Float(trimChromaWeight) / 4096.0) - 0.5
            self.saturationGain = (Float(trimSaturationGain) / 4096.0) - 0.5
        }

        /// Slope, offset, power and saturation at their neutral codes (2048): the trim leaves the picture unchanged.
        /// Mastering tools often write such a block on every frame. Chroma weight is not applied, so not checked.
        public var isNeutral: Bool {
            let tolerance: Float = 0.5 / 4096.0
            return abs(slope - 1.0) < tolerance && abs(offset) < tolerance && abs(power - 1.0) < tolerance
                && abs(saturationGain) < tolerance
        }
    }

    /// What an RPU does to the reshaping curves.
    public enum ReshapingCurvesState: Sendable, Equatable {
        /// Keeps the previous RPU's (`use_prev_vdr_rpu_flag`).
        case reusePrevious
        /// Reshapes by these (I, P, T).
        case curves([ReshapingCurve])
        /// Carries curves the shader can't apply (or that need the enhancement layer): no reshaping.
        case unsupported
    }

    /// What an RPU does to the colour matrices.
    public enum ColorMatrixState: Sendable, Equatable {
        /// Keeps the previous RPU's (`dm_compression` 1).
        case reusePrevious
        /// Takes these.
        case matrix(ColorMatrix)
        /// Carries none (all zero): the IPT-PQ-c2 defaults.
        case defaults
    }

    public let sceneRefresh: Bool
    public let l1: Level1?
    public let l2Trims: [Level2Trim]
    public let sourceMinPQ: UInt16?
    public let sourceMaxPQ: UInt16?
    public let reshapingCurvesState: ReshapingCurvesState
    public let colorMatrixState: ColorMatrixState

    /// Preferred 100-nit SDR trim if authored by the colorist (target_max_pq ~ 2081)
    public var sdrTrim: Level2Trim? {
        l2Trims.first { abs($0.targetNits - 100.0) <= 20.0 || abs(Int($0.targetMaxPQ) - 2081) <= 50 }
    }

    public init(
        sceneRefresh: Bool,
        l1: Level1?,
        l2Trims: [Level2Trim],
        sourceMinPQ: UInt16? = nil,
        sourceMaxPQ: UInt16? = nil,
        reshapingCurvesState: ReshapingCurvesState = .unsupported,
        colorMatrixState: ColorMatrixState = .defaults
    ) {
        self.sceneRefresh = sceneRefresh
        self.l1 = l1
        self.l2Trims = l2Trims
        self.sourceMinPQ = sourceMinPQ
        self.sourceMaxPQ = sourceMaxPQ
        self.reshapingCurvesState = reshapingCurvesState
        self.colorMatrixState = colorMatrixState
    }
}
