import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import NitsCore

/// The local contrast (`ContrastRecovery`, `applyContrastRecovery`) through `MetalVideoRenderer.renderStill`, which
/// draws a frame as the layer does.
@Suite("Contrast Recovery", .hostDependent)
struct ContrastRecoveryTests {
    private static let width = 256
    private static let height = 144

    /// A 10-bit video-range P010 frame of PQ greys: `nits(x, y)` at each pixel.
    private static func frame(_ nits: (Int, Int) -> Float) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attributes,
                &buffer) == kCVReturnSuccess, let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height {
            let row = luma.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let code = 64 + 876 * ThumbnailToneMapper.nitsToPQ(nits(x, y))
                row[x] = UInt16(code.rounded()) << 6
            }
        }
        for y in 0..<height / 2 {
            let row = chroma.advanced(by: y * chromaStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                row[x] = 512 << 6
            }
        }
        return buffer
    }

    /// Luminance-ish value (the green channel, 16-bit) of each pixel of a still, row by row.
    private static func greens(_ image: CGImage) -> [UInt16] {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let pixels = UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt16.self)
        return (0..<(image.width * image.height)).map { pixels[$0 * 3 + 1] }
    }

    private static func render(_ buffer: CVPixelBuffer, strength: Float) throws -> [UInt16]? {
        guard let renderer = MetalVideoRenderer() else { return nil }
        var uniforms = ToneMapUniforms(targetNits: 140, sourcePeakNits: 600, outputSharpness: 0)
        uniforms.contrastRecovery = strength
        let image = try #require(
            renderer.renderStill(
                pixelBuffer: buffer, uniforms: uniforms, sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                width: width, height: height))
        return greens(image)
    }

    @Test("A flat frame has no detail to recover: the picture is the curve's")
    func flatFrameUnchanged() throws {
        let buffer = try #require(Self.frame { _, _ in 400 })
        guard let plain = try Self.render(buffer, strength: 0), let recovered = try Self.render(buffer, strength: 0.5)
        else { return }
        let difference = zip(plain, recovered).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(difference <= 64, "max difference \(difference) of 65535")
    }

    @Test("Texture in a compressed highlight gains contrast")
    func highlightTextureGains() throws {
        // Left: 300 / 340-nit stripes (haze in the shoulder); right: a dark 5-nit field, a hard edge between.
        let buffer = try #require(
            Self.frame { x, y in x < Self.width / 2 ? ((y / 4) % 2 == 0 ? 300 : 340) : 5 })
        guard let plain = try Self.render(buffer, strength: 0), let recovered = try Self.render(buffer, strength: 0.5)
        else { return }
        func stripeContrast(_ values: [UInt16]) -> Int {
            let x = Self.width / 4
            let rows = (8..<(Self.height - 8))
            let bright = rows.filter { ($0 / 4) % 2 == 1 }.map { Int(values[$0 * Self.width + x]) }
            let dark = rows.filter { ($0 / 4) % 2 == 0 }.map { Int(values[$0 * Self.width + x]) }
            return bright.reduce(0, +) / bright.count - dark.reduce(0, +) / dark.count
        }
        let before = stripeContrast(plain)
        let after = stripeContrast(recovered)
        #expect(after > before + before / 4, "stripe contrast \(before) -> \(after)")
    }
}
