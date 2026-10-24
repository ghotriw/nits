import Foundation
import simd

/// A Dolby Vision Profile 5 RPU's reshaping curves and colour matrices, evaluated per pixel on the CPU: the shader's
/// (`nitsFromIPT` in `HDRToneMapping.metal`, ETSI GS CCM 001 5.4.2.3) for thumbnails, which don't go through Metal.
struct DolbyVisionPixelReshaping {
    private let curves: [DolbyVisionFrameMetadata.ReshapingCurve]
    private let pieceCounts: [Int]
    private let pivotMaxima: [Float]
    private let iptToLms: simd_float3x3
    private let iptOffset: SIMD3<Float>
    let lmsToRgb: simd_float3x3

    /// The RPU's reshaping, nil when it has no curves this can apply (as the shader then doesn't reshape either).
    init?(metadata: DolbyVisionFrameMetadata) {
        guard case .curves(let curves) = metadata.reshapingCurvesState, curves.count == 3 else { return nil }
        let maxPieces = ToneMapUniforms.DolbyVisionReshaping.maxPieces
        self.curves = curves
        pieceCounts = curves.map { min($0.polyCoeffs.count, maxPieces) }
        // The curve's end, an MMR component's included (no pieces of its own), as `setCurves` gives the shader.
        pivotMaxima = curves.map { $0.pivots.isEmpty ? 1 : $0.pivots[min($0.pivots.count - 1, maxPieces)] }
        if case .matrix(let matrix) = metadata.colorMatrixState {
            iptToLms = matrix.yccToRgb
            iptOffset = matrix.yccToRgbOffset
            lmsToRgb = DolbyVisionColorScience.lmsToRgb(rgbToLms: matrix.rgbToLms)
        } else {
            iptToLms = DolbyVisionColorScience.defaultIptToLms
            iptOffset = DolbyVisionColorScience.defaultIptOffset
            lmsToRgb = DolbyVisionColorScience.defaultLmsToRgb
        }
    }

    /// LMS' (non-linear, PQ) of a pixel whose base layer codewords are `raw`, each normalized to [0, 1] by its full
    /// code range.
    func lmsPrime(raw: SIMD3<Float>) -> SIMD3<Float> {
        let ipt = SIMD3(curve(0, raw.x), chroma(1, raw), chroma(2, raw)) - iptOffset
        return simd_clamp(iptToLms * ipt, .zero, SIMD3(repeating: 1))
    }

    /// Component `c`'s piecewise polynomial curve of `x`.
    private func curve(_ c: Int, _ x: Float) -> Float {
        let count = pieceCounts[c]
        guard count > 0 else { return min(max(x, 0), 1) }
        let pivots = curves[c].pivots
        let xc = min(max(x, pivots[0]), pivotMaxima[c])
        var piece = 0
        for i in 1..<count where i < pivots.count && xc >= pivots[i] { piece = i }
        let k = curves[c].polyCoeffs[piece]
        return min(max(k.x + xc * (k.y + xc * k.z), 0), 1)
    }

    /// Chroma component `c` (1: P, 2: T): by its MMR piece when it has one, else by its curve.
    private func chroma(_ c: Int, _ raw: SIMD3<Float>) -> Float {
        guard let mmr = curves[c].mmr else { return curve(c, raw[c]) }
        var result = mmr.constant
        var power = raw
        let coefs = mmr.coefs
        for k in 0..<min(mmr.order, 3) where (k + 1) * 7 <= coefs.count {
            let base = k * 7
            let xy = power.x * power.y
            result += coefs[base] * power.x + coefs[base + 1] * power.y + coefs[base + 2] * power.z
            result += coefs[base + 3] * xy + coefs[base + 4] * power.x * power.z + coefs[base + 5] * power.y * power.z
            result += coefs[base + 6] * xy * power.z
            power *= raw
        }
        return min(max(result, 0), 1)
    }
}
