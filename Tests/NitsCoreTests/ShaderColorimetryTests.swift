import CoreVideo
import Foundation
import NitsTestSupport
import Testing
import simd

@testable import NitsCore

/// The matrices the shader decodes a stream with, from its matrix coefficients and primaries.
@Suite("Shader colorimetry")
struct ShaderColorimetryTests {
    private static func isClose(_ a: simd_float3x3, _ b: simd_float3x3, within tolerance: Float = 1e-4) -> Bool {
        [0, 1, 2].allSatisfy { simd_reduce_max(simd_abs(a[$0] - b[$0])) <= tolerance }
    }

    @Test("BT.2020 Y'CbCr decodes with the coefficients of BT.2020")
    func bt2020Matrix() {
        let expected = simd_float3x3(
            columns: (
                SIMD3(1, 1, 1), SIMD3(0, -0.164553, 1.8814), SIMD3(1.4746, -0.571353, 0)
            ))
        #expect(Self.isClose(ShaderColorimetry.yCbCrToRGB(kCVImageBufferYCbCrMatrix_ITU_R_2020), expected))
    }

    @Test("BT.709 Y'CbCr decodes with the coefficients of BT.709, and BT.601 with its own")
    func bt709And601Matrices() {
        let bt709 = simd_float3x3(
            columns: (
                SIMD3(1, 1, 1), SIMD3(0, -0.1873, 1.8556), SIMD3(1.5748, -0.4681, 0)
            ))
        #expect(Self.isClose(ShaderColorimetry.yCbCrToRGB(kCVImageBufferYCbCrMatrix_ITU_R_709_2), bt709))
        let bt601 = ShaderColorimetry.yCbCrToRGB(kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        #expect(abs(bt601[2][0] - 1.402) < 1e-3 && abs(bt601[1][2] - 1.772) < 1e-3)
    }

    @Test("BT.709 converts to Display P3 by the matrix the SDR path always used")
    func bt709ToDisplayP3() {
        let expected = simd_float3x3(
            columns: (
                SIMD3(0.822462, 0.033194, 0.017083), SIMD3(0.177538, 0.966806, 0.072397), SIMD3(0, 0, 0.910520)
            ))
        #expect(
            Self.isClose(
                ShaderColorimetry.toDisplayP3(kCVImageBufferColorPrimaries_ITU_R_709_2), expected, within: 2e-4))
    }

    @Test("White stays white through every conversion, and BT.2020 to itself is the identity")
    func whiteIsKept() {
        let primaries = [
            kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferColorPrimaries_EBU_3213,
            kCVImageBufferColorPrimaries_SMPTE_C, kCVImageBufferColorPrimaries_P3_D65,
            kCVImageBufferColorPrimaries_ITU_R_2020,
        ]
        for p in primaries {
            for m in [ShaderColorimetry.toBT2020(p), ShaderColorimetry.toDisplayP3(p)] {
                #expect(simd_reduce_max(simd_abs(m * SIMD3(1, 1, 1) - SIMD3(1, 1, 1))) < 1e-4, "\(p)")
            }
        }
        #expect(ShaderColorimetry.toBT2020(kCVImageBufferColorPrimaries_ITU_R_2020) == matrix_identity_float3x3)
        #expect(!ShaderColorimetry.fitsDisplayP3(kCVImageBufferColorPrimaries_ITU_R_2020))
        #expect(ShaderColorimetry.fitsDisplayP3(kCVImageBufferColorPrimaries_ITU_R_709_2))
    }
}

/// The shader decodes a colour the same whatever primaries and matrix carry it: V-08's BT.2020 SDR and PQ with BT.709
/// primaries, which it used to take as BT.709 SDR.
@Suite("Shader colorimetry rendering", .hostDependent)
struct ShaderColorimetryRenderingTests {
    /// Uniforms for full-range 10-bit Y'CbCr of `primaries` and `matrix` with the transfer `transferFunction`.
    private static func uniforms(
        primaries: CFString, matrix: CFString, transferFunction: CFString
    ) -> ToneMapUniforms {
        var uniforms = ToneMapUniforms(targetNits: 203.0, sourcePeakNits: 1000.0, outputSharpness: 0.0)
        uniforms.isFullRange = 1
        uniforms.transferFunction = TransferFunctionClass(transferFunction).shaderIndex
        uniforms.yCbCrToRGB = ShaderColorimetry.yCbCrToRGB(matrix)
        uniforms.sourceToBT2020 = ShaderColorimetry.toBT2020(primaries)
        uniforms.sourceToDisplayP3 = ShaderColorimetry.toDisplayP3(primaries)
        uniforms.sourceFitsDisplayP3 = ShaderColorimetry.fitsDisplayP3(primaries) ? 1 : 0
        return uniforms
    }

    /// Full-range 16-bit Y'CbCr codes of the non-linear R'G'B' `rgb` by `matrix`.
    private static func codes(_ rgb: SIMD3<Float>, matrix: CFString) -> (luma: UInt16, chroma: [UInt16]) {
        let ycc = ShaderColorimetry.yCbCrToRGB(matrix).inverse * rgb
        func code(_ value: Float) -> UInt16 { UInt16((max(0, min(1, value)) * 65535.0).rounded()) }
        let mid: Float = 32768.0 / 65535.0
        return (code(ycc.x), [code(ycc.y + mid), code(ycc.z + mid)])
    }

    private static func each(_ v: SIMD3<Float>, _ f: (Float) -> Float) -> SIMD3<Float> {
        SIMD3(f(v.x), f(v.y), f(v.z))
    }

    private static func bt709OETF(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        each(linear) { $0 < 0.018 ? 4.5 * $0 : 1.099 * pow($0, 0.45) - 0.099 }
    }

    private static func pq(_ nits: SIMD3<Float>) -> SIMD3<Float> {
        each(nits) { Float(ToneMapShaderRendering.pqCode(nits: $0)) / 65535.0 }
    }

    private static func render(
        _ rgb: SIMD3<Float>, primaries: CFString, matrix: CFString, transferFunction: CFString
    ) throws -> [Int]? {
        let c = codes(rgb, matrix: matrix)
        return try ToneMapShaderRendering.renderRawTexels(
            luma: c.luma, chroma: c.chroma,
            uniforms: uniforms(primaries: primaries, matrix: matrix, transferFunction: transferFunction)
        ).map(ToneMapShaderRendering.channels)
    }

    private static func expectClose(_ a: [Int], _ b: [Int], within tolerance: Int, _ what: String) {
        #expect(zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }, "\(what): \(a) vs \(b)")
    }

    @Test("BT.2020 SDR shows a colour as BT.709 SDR shows it")
    func bt2020SDRMatchesBT709() throws {
        let linear709 = SIMD3<Float>(0.6, 0.1, 0.05)
        let linear2020 = ShaderColorimetry.toBT2020(kCVImageBufferColorPrimaries_ITU_R_709_2) * linear709
        guard
            let reference = try Self.render(
                Self.bt709OETF(linear709), primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2),
            let wide = try Self.render(
                Self.bt709OETF(linear2020), primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2)
        else { return }
        Self.expectClose(reference, wide, within: 6, "BT.2020 SDR")
    }

    @Test("BT.601 SDR decodes with the BT.601 matrix")
    func bt601SDRMatchesBT709() throws {
        let rgb = Self.bt709OETF(SIMD3<Float>(0.5, 0.2, 0.1))
        guard
            let reference = try Self.render(
                rgb, primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2),
            let sd = try Self.render(
                rgb, primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2)
        else { return }
        Self.expectClose(reference, sd, within: 3, "BT.601 matrix")
    }

    @Test("PQ with BT.709 primaries is tone mapped as the same colour in BT.2020")
    func pqWithBT709PrimariesIsHDR() throws {
        let nits709 = SIMD3<Float>(300, 60, 20)
        let nits2020 = ShaderColorimetry.toBT2020(kCVImageBufferColorPrimaries_ITU_R_709_2) * nits709
        guard
            let narrow = try Self.render(
                Self.pq(nits709), primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
            let reference = try Self.render(
                Self.pq(nits2020), primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        else { return }
        Self.expectClose(reference, narrow, within: 6, "PQ BT.709")
    }

    @Test("HLG with BT.709 primaries is decoded as the same colour in BT.2020")
    func hlgWithBT709PrimariesIsHDR() throws {
        // HLG's OETF of scene light in [0, 1]; the OOTF follows the conversion, so the two must meet.
        func hlg(_ e: SIMD3<Float>) -> SIMD3<Float> {
            let (a, b, c): (Float, Float, Float) = (0.17883277, 0.28466892, 0.55991073)
            return Self.each(e) { $0 <= 1.0 / 12.0 ? sqrt(3 * $0) : a * log(12 * $0 - b) + c }
        }
        let scene709 = SIMD3<Float>(0.4, 0.12, 0.05)
        let scene2020 = ShaderColorimetry.toBT2020(kCVImageBufferColorPrimaries_ITU_R_709_2) * scene709
        guard
            let narrow = try Self.render(
                hlg(scene709), primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            let reference = try Self.render(
                hlg(scene2020), primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        else { return }
        Self.expectClose(reference, narrow, within: 6, "HLG BT.709")
    }

    @Test("An unknown transfer with BT.2020 primaries is drawn as SDR, not decoded as PQ")
    func unknownTransferIsSDR() throws {
        let rgb = Self.bt709OETF(SIMD3<Float>(0.3, 0.3, 0.3))
        guard
            let reference = try Self.render(
                rgb, primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2),
            let srgb = try Self.render(
                rgb, primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020, transferFunction: kCVImageBufferTransferFunction_sRGB)
        else { return }
        #expect(reference == srgb)
    }
}
