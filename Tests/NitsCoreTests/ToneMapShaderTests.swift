import Foundation
import Metal
import NitsTestSupport
import Testing
import simd

@testable import NitsCore

/// Renders flat PQ frames through the tone mapping: greys stay neutral, saturated colours keep their hue, no NaN.
@Suite("Tone Mapping Shader", .hostDependent)
struct ToneMapShaderTests {
    private static func uniforms(sharpness: Float = 0.0) -> ToneMapUniforms {
        var uniforms = ToneMapUniforms(targetNits: 203.0, sourcePeakNits: 4000.0, outputSharpness: sharpness)
        uniforms.isFullRange = 1
        return uniforms
    }

    @Test("Greys stay neutral from deep shadow to the source peak")
    func greysStayNeutral() throws {
        for nits: Float in [0.5, 5, 50, 203, 1000, 4000] {
            let grey = ToneMapShaderRendering.codes(red: nits, green: nits, blue: nits)
            guard
                let pixel = try ToneMapShaderRendering.renderRawTexels(
                    luma: grey.luma, chroma: grey.chroma, uniforms: Self.uniforms())
            else { return }
            let rgb = ToneMapShaderRendering.channels(pixel)
            #expect(
                abs(rgb[0] - rgb[1]) <= 2 && abs(rgb[2] - rgb[1]) <= 2, "at \(nits) nits the grey is tinted: \(rgb)")
        }
    }

    @Test("A bright saturated red stays red")
    func saturatedHighlightKeepsHue() throws {
        let red = ToneMapShaderRendering.codes(red: 1000, green: 1, blue: 1)
        guard
            let pixel = try ToneMapShaderRendering.renderRawTexels(
                luma: red.luma, chroma: red.chroma, uniforms: Self.uniforms())
        else { return }
        let rgb = ToneMapShaderRendering.channels(pixel)
        #expect(rgb[0] > rgb[1] && rgb[0] > rgb[2], "the red should stay red: \(rgb)")
    }

    @Test("The curve and the P3 fit stay NaN-free at full sharpness, out-of-gamut and extreme inputs included")
    func curveIsNaNFree() throws {
        // A NaN reaches `.bgr10a2Unorm` as 0: a lit input coming out black is one.
        let chromaCorners: [[UInt16]] = [[32768, 32768], [0, 0], [0, 65535], [65535, 0], [65535, 65535]]
        for nits: Float in [1, 100, 1000, 10000] {
            for chroma in chromaCorners {
                let luma = ToneMapShaderRendering.pqCode(nits: nits)
                guard
                    let pixel = try ToneMapShaderRendering.renderRawTexels(
                        luma: luma, chroma: chroma, uniforms: Self.uniforms(sharpness: 1.0))
                else { return }
                #expect(
                    ToneMapShaderRendering.channels(pixel).max()! > 0, "black output at \(nits) nits, chroma \(chroma)")
            }
        }
    }
}
