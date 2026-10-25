import Foundation
import Metal

@testable import NitsCore

/// Draws flat frames through `hdrToneMapFragmentShader`, as the layer does, and reads back one output pixel.
enum ToneMapShaderRendering {
    /// Full-range 16-bit luma code of a grey at `nits` (PQ).
    static func pqCode(nits: Float) -> UInt16 {
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = 2523.0 / 32.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = 2413.0 / 128.0
        let c3: Float = 2392.0 / 128.0
        let powered = pow(nits / 10000.0, m1)
        let pq = pow((c1 + c2 * powered) / (1.0 + c3 * powered), m2)
        return UInt16((pq * 65535.0).rounded())
    }

    /// Full-range 16-bit Y'CbCr codes of a BT.2020 PQ colour given per channel in nits.
    static func codes(red: Float, green: Float, blue: Float) -> (luma: UInt16, chroma: [UInt16]) {
        let (r, g, b) = (pq(red), pq(green), pq(blue))
        let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
        func code(_ value: Float) -> UInt16 { UInt16((max(0, min(1, value)) * 65535.0).rounded()) }
        return (code(y), [code((b - y) / 1.8814 + 32768.0 / 65535.0), code((r - y) / 1.4746 + 32768.0 / 65535.0)])
    }

    /// The 10-bit R, G, B of a packed `.bgr10a2Unorm` pixel.
    static func channels(_ pixel: UInt32) -> [Int] {
        [20, 10, 0].map { Int((pixel >> UInt32($0)) & 0x3FF) }
    }

    /// Linear Display P3 of a packed pixel, 1 = white (the layer's sRGB encoding decoded).
    static func linearDisplayP3(_ pixel: UInt32) -> SIMD3<Float> {
        let linear = channels(pixel).map { code -> Float in
            let c = Float(code) / 1023.0
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return SIMD3(linear[0], linear[1], linear[2])
    }

    /// The PQ signal of `nits`, 0 ... 1.
    private static func pq(_ nits: Float) -> Float {
        Float(pqCode(nits: nits)) / 65535.0
    }

    /// The packed `.bgr10a2Unorm` output of a flat 4 × 4 frame of 16-bit luma `luma` and Cb / Cr codes `chroma`; nil
    /// without a Metal device.
    static func renderRawTexels(luma: UInt16, chroma: [UInt16], uniforms: ToneMapUniforms) throws -> UInt32? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let library = try device.makeDefaultLibrary(bundle: .module)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "hdrVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "hdrToneMapFragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let size = 4
        func texture(_ format: MTLPixelFormat, _ texel: [UInt16]) -> (any MTLTexture)? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: size, height: size, mipmapped: false)
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let pixels = [UInt16]((0..<(size * size)).flatMap { _ in texel })
            pixels.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!,
                    bytesPerRow: size * texel.count * 2)
            }
            return texture
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgr10a2Unorm, width: size, height: size, mipmapped: false)
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        guard let lumaTexture = texture(.r16Unorm, [luma]),
            let chromaTexture = texture(.rg16Unorm, chroma),
            let output = device.makeTexture(descriptor: outputDescriptor),
            let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        var sourceRect = SIMD4<Float>(0, 0, 1, 1)
        encoder.setVertexBytes(&sourceRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        var bytes = uniforms
        encoder.setFragmentBytes(&bytes, length: MemoryLayout<ToneMapUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixel: UInt32 = 0
        output.getBytes(&pixel, bytesPerRow: size * 4, from: MTLRegionMake2D(1, 1, 1, 1), mipmapLevel: 0)
        return pixel
    }
}
