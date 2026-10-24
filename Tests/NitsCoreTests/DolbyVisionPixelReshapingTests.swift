import Foundation
import Testing
import simd

@testable import NitsCore

@Suite("Dolby Vision pixel reshaping (thumbnails)")
struct DolbyVisionPixelReshapingTests {
    typealias Curve = DolbyVisionFrameMetadata.ReshapingCurve

    @Test("Curves and MMR reshape the codewords as the shader does, then the IPT-PQ-c2 matrix applies")
    func reshapesCodewords() throws {
        let metadata = DolbyVisionFrameMetadata(
            sceneRefresh: true, l1: nil, l2Trims: [],
            reshapingCurvesState: .curves([
                // I: two pieces, 0.1 + 0.5 x below 0.5, then 0.2 + 0.3 x.
                Curve(pivots: [0, 0.5, 1], polyCoeffs: [SIMD3(0.1, 0.5, 0), SIMD3(0.2, 0.3, 0)]),
                // P: MMR of order 1, 0.4 + 0.2 I.
                Curve(pivots: [0, 1], mmr: .init(order: 1, constant: 0.4, coefs: [0.2, 0, 0, 0, 0, 0, 0])),
                // T: identity.
                Curve(pivots: [0, 1], polyCoeffs: [SIMD3(0, 1, 0)]),
            ]))
        let reshaping = try #require(DolbyVisionPixelReshaping(metadata: metadata))
        let raw = SIMD3<Float>(0.8, 0.3, 0.6)
        let ipt = SIMD3<Float>(0.2 + 0.3 * 0.8, 0.4 + 0.2 * 0.8, 0.6) - DolbyVisionColorScience.defaultIptOffset
        let expected = simd_clamp(DolbyVisionColorScience.defaultIptToLms * ipt, .zero, SIMD3(repeating: 1))
        #expect(simd_length(reshaping.lmsPrime(raw: raw) - expected) < 1e-5)
    }

    @Test("An RPU without curves to apply gives no reshaping")
    func noCurvesNoReshaping() {
        #expect(
            DolbyVisionPixelReshaping(metadata: DolbyVisionFrameMetadata(sceneRefresh: true, l1: nil, l2Trims: []))
                == nil)
    }
}
