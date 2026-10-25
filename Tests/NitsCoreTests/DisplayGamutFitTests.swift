import Foundation
import Metal
import Testing
import simd

@testable import NitsCore

/// The step from Rec.2020 into Display P3 (`fitToDisplayP3`): on its own through a compute kernel, and in the shader.
@Suite("Display Gamut Fit", .hostDependent)
struct DisplayGamutFitTests {
    private static let rgb2020ToLms = simd_float3x3(
        SIMD3(0.6167557877, 0.2651330603, 0.1001026312),
        SIMD3(0.3601984026, 0.6358393718, 0.2039065206),
        SIMD3(0.0230458097, 0.0990275679, 0.6959908482))
    /// Oklab M2: LMS' -> (L, a, b).
    private static let lmsToLab = simd_float3x3(
        SIMD3(0.2104542553, 1.9779984951, 0.0259040371),
        SIMD3(0.7936177850, -2.4285922050, 0.7827717662),
        SIMD3(-0.0040720468, 0.4505937099, -0.8086757660))
    private static let p3To2020 = simd_float3x3(
        SIMD3(0.75383303, 0.04574385, -0.00121034),
        SIMD3(0.19859737, 0.94177722, 0.01760172),
        SIMD3(0.0475696, 0.01247893, 0.98360862))

    /// Oklab lightness, chroma and hue (degrees) of linear Rec.2020.
    private static func oklab(_ rgb2020: SIMD3<Float>) -> (lightness: Float, chroma: Float, hue: Float) {
        let lms = rgb2020ToLms * simd_max(rgb2020, .zero)
        let lab = lmsToLab * SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z))
        return (lab.x, hypot(lab.y, lab.z), atan2(lab.z, lab.y) * 180 / .pi)
    }

    private static func hueDifference(_ a: Float, _ b: Float) -> Float {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    /// `fitToDisplayP3` of each colour, built from its source with a kernel around it; nil without a Metal device.
    private static func fit(_ colours: [SIMD3<Float>]) throws -> [SIMD3<Float>]? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/NitsCore/Video/DisplayGamutFit.metal")
        let kernel = """
            kernel void fitKernel(device const float3 *input [[buffer(0)]], device float3 *output [[buffer(1)]],
                                  uint id [[thread_position_in_grid]]) {
                output[id] = fitToDisplayP3(input[id]);
            }
            """
        let library = try device.makeLibrary(
            source: try String(contentsOf: sourceURL, encoding: .utf8) + kernel, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "fitKernel")!)
        let length = colours.count * MemoryLayout<SIMD3<Float>>.stride
        guard let input = device.makeBuffer(bytes: colours, length: length),
            let output = device.makeBuffer(length: length),
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: colours.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let results = output.contents().bindMemory(to: SIMD3<Float>.self, capacity: colours.count)
        return Array(UnsafeBufferPointer(start: results, count: colours.count))
    }

    @Test("Colours inside Display P3 with a margin pass unchanged")
    func coloursInsidePassUnchanged() throws {
        let steps: [Float] = [0.1, 0.35, 0.6, 0.85]
        let p3 = steps.flatMap { r in steps.flatMap { g in steps.map { b in SIMD3(r, g, b) } } }
        guard let fitted = try Self.fit(p3.map { Self.p3To2020 * $0 }) else { return }
        for (expected, actual) in zip(p3, fitted) {
            #expect(simd_reduce_max(simd_abs(actual - expected)) < 2e-4, "\(expected) became \(actual)")
        }
    }

    @Test("Saturated colours land inside Display P3 at the same Oklab lightness and hue, giving up chroma only")
    func coloursOutsideKeepLightnessAndHue() throws {
        // Rec.2020 primaries and secondaries, a sunset orange and a saturated cyan, at several levels.
        let directions: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 0, 1),
            SIMD3(1, 0.47, 0.08), SIMD3(0.05, 0.6, 0.9),
        ]
        let colours = directions.flatMap { direction in [0.1, 0.4, 0.9].map { direction * Float($0) } }
        guard let fitted = try Self.fit(colours) else { return }
        for (source, p3) in zip(colours, fitted) {
            #expect(simd_reduce_min(p3) >= 0 && simd_reduce_max(p3) <= 1, "\(source) gave P3 \(p3)")
            let before = Self.oklab(source)
            let after = Self.oklab(Self.p3To2020 * p3)
            #expect(
                abs(after.lightness - before.lightness) < 2e-3, "\(source): L \(before.lightness) -> \(after.lightness)"
            )
            #expect(Self.hueDifference(after.hue, before.hue) < 0.5, "\(source): hue \(before.hue) -> \(after.hue)")
            #expect(after.chroma <= before.chroma + 1e-5, "\(source): chroma \(before.chroma) -> \(after.chroma)")
        }
    }

    @Test("In the shader, a colour outside Display P3 keeps its Oklab hue (channel clipping turned it ~5 deg)")
    func shaderKeepsHueOutsideP3() throws {
        // A Rec.2020 green well under SDR white, which the luminance curve passes through, outside P3 (negative red).
        let source = SIMD3<Float>(2, 30, 2)
        var uniforms = ToneMapUniforms(targetNits: 203.0, sourcePeakNits: 1000.0, outputSharpness: 0.0)
        uniforms.isFullRange = 1
        let codes = ToneMapShaderRendering.codes(red: source.x, green: source.y, blue: source.z)
        guard
            let pixel = try ToneMapShaderRendering.renderRawTexels(
                luma: codes.luma, chroma: codes.chroma, uniforms: uniforms)
        else { return }
        let before = Self.oklab(source / 203.0)
        let after = Self.oklab(Self.p3To2020 * ToneMapShaderRendering.linearDisplayP3(pixel))
        #expect(Self.hueDifference(after.hue, before.hue) < 1.5, "hue \(before.hue) -> \(after.hue)")
    }
}
