import Foundation
import simd

extension ToneMapUniforms {
    /// Dolby Vision Profile 5 reshaping (the RPU's curves per I / P / T component) and colour matrices, laid out as
    /// `DolbyVisionReshaping` in `HDRToneMapping.metal`. The defaults are IPT-PQ-c2 without reshaping.
    public struct DolbyVisionReshaping: Sendable {
        public typealias Float4x2 = (SIMD4<Float>, SIMD4<Float>)
        public typealias Float4x6 = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        public typealias Float4x8 = (
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>
        )

        /// The pieces of a component's polynomial curve the shader holds.
        public static let maxPieces = 8

        /// 1 when the curves below reshape the decoded codewords; 0 normalizes them by range instead.
        public private(set) var isActive: UInt32 = 0
        /// `IPT -> LMS'`: the RPU's `ycc_to_rgb_matrix`, else IPT-PQ-c2's.
        public private(set) var iptToLms = DolbyVisionColorScience.defaultIptToLms
        /// Subtracted from the reshaped I / P / T (`ycc_to_rgb_offset`).
        public private(set) var iptOffset = DolbyVisionColorScience.defaultIptOffset
        /// `LMS -> BT.2020 Linear RGB`, from the RPU's `rgb_to_lms_matrix` when present.
        public private(set) var lmsToRgb = DolbyVisionColorScience.defaultLmsToRgb
        /// Polynomial pieces of I, P and T; 0 for an MMR component.
        public private(set) var pieceCounts = SIMD3<UInt32>.zero
        /// MMR order of P (`.y`) and T (`.z`); 0 for a polynomial component.
        public private(set) var mmrOrders = SIMD3<UInt32>.zero
        /// MMR constant of P (`.y`) and T (`.z`).
        public private(set) var mmrConstants = SIMD3<Float>.zero
        /// Upper end of each component's curve, where its input is clamped.
        public private(set) var pivotMax = SIMD3<Float>(repeating: 1.0)
        /// The pivots of each component: 8 floats, 1 past the last.
        public private(set) var pivots: (Float4x2, Float4x2, Float4x2) = (
            Self.zero4x2, Self.zero4x2, Self.zero4x2
        )
        /// `(c0, c1, c2, 0)` of each piece of each component.
        public private(set) var polyCoeffs: (Float4x8, Float4x8, Float4x8) = (
            Self.zero4x8, Self.zero4x8, Self.zero4x8
        )
        /// MMR coefficients of P and T: 7 per order, up to 21.
        public private(set) var mmrCoeffs: (Float4x6, Float4x6) = (Self.zero4x6, Self.zero4x6)

        private static let zero4x2: Float4x2 = (.zero, .zero)
        private static let zero4x6: Float4x6 = (.zero, .zero, .zero, .zero, .zero, .zero)
        private static let zero4x8: Float4x8 = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)

        public init() {}

        /// Reshapes by `curves` (I, P, T) from now on, keeping the colour matrices; 3 curves the parser accepted (I
        /// polynomial, P / T polynomial or one MMR piece), else reshaping stops.
        public mutating func setCurves(_ curves: [DolbyVisionFrameMetadata.ReshapingCurve]) {
            clearCurves()
            guard curves.count == 3 else { return }
            for (component, curve) in curves.enumerated() {
                let pieceCount = min(curve.polyCoeffs.count, Self.maxPieces)
                for i in 0..<Self.maxPieces {
                    Self.store(i < curve.pivots.count ? curve.pivots[i] : 1.0, at: component * 8 + i, in: &pivots)
                }
                // The last pivot the shader holds: the curve's end, an MMR component's included (no pieces of its own).
                pivotMax[component] =
                    curve.pivots.isEmpty
                    ? 1.0 : curve.pivots[min(curve.pivots.count - 1, Self.maxPieces)]
                pieceCounts[component] = UInt32(pieceCount)
                for (piece, c) in curve.polyCoeffs.prefix(pieceCount).enumerated() {
                    Self.store(SIMD4(c, 0.0), at: component * Self.maxPieces + piece, in: &polyCoeffs)
                }
                if let mmr = curve.mmr, component > 0 {
                    mmrOrders[component] = UInt32(mmr.order)
                    mmrConstants[component] = mmr.constant
                    for (i, coefficient) in mmr.coefs.prefix(21).enumerated() {
                        Self.store(coefficient, at: (component - 1) * 24 + i, in: &mmrCoeffs)
                    }
                }
            }
            isActive = 1
        }

        /// Stops reshaping, keeping the colour matrices.
        private mutating func clearCurves() {
            let matrices = (iptToLms, iptOffset, lmsToRgb)
            self = Self()
            (iptToLms, iptOffset, lmsToRgb) = matrices
        }

        /// Takes the RPU's colour matrices instead of IPT-PQ-c2's.
        public mutating func setColorMatrix(_ matrix: DolbyVisionFrameMetadata.ColorMatrix) {
            iptToLms = matrix.yccToRgb
            iptOffset = matrix.yccToRgbOffset
            lmsToRgb = DolbyVisionColorScience.lmsToRgb(rgbToLms: matrix.rgbToLms)
        }

        /// Writes `value` as element `index` of `storage`, a tuple the shader reads as an array of `Element`.
        private static func store<Element, Storage>(_ value: Element, at index: Int, in storage: inout Storage) {
            let stride = MemoryLayout<Element>.stride
            precondition(index >= 0 && (index + 1) * stride <= MemoryLayout<Storage>.size)
            withUnsafeMutableBytes(of: &storage) {
                $0.storeBytes(of: value, toByteOffset: index * stride, as: Element.self)
            }
        }
    }
}

/// The Dolby Vision Profile 5 reshaping of the media playing, which each frame's RPU sets whole;
/// `ToneMapController` writes it to the renderer's uniforms.
struct DolbyVisionReshaper: Sendable {
    /// Whether the media is Profile 5; for other media the reshaping stays at its defaults.
    private(set) var isProfile5 = false
    private(set) var uniforms = ToneMapUniforms.DolbyVisionReshaping()

    /// Back to the defaults, for media that is Profile 5 or not.
    mutating func reset(isProfile5: Bool = false) {
        self.isProfile5 = isProfile5
        uniforms = ToneMapUniforms.DolbyVisionReshaping()
    }

    /// Takes the curves and matrices of a frame's RPU; a frame without one keeps them. Profile 5 RPUs may not refer
    /// to an earlier one (`use_prev_vdr_rpu_flag`, `dm_compression`), so such an RPU leaves the defaults rather than
    /// borrow another frame's: the earlier RPU is in decoding order, and this sees frames in display order, not all.
    mutating func update(with metadata: DolbyVisionFrameMetadata?) {
        guard isProfile5, let metadata else { return }
        var reshaping = ToneMapUniforms.DolbyVisionReshaping()
        if case .curves(let curves) = metadata.reshapingCurvesState {
            reshaping.setCurves(curves)
        }
        if case .matrix(let matrix) = metadata.colorMatrixState {
            reshaping.setColorMatrix(matrix)
        }
        uniforms = reshaping
    }
}
