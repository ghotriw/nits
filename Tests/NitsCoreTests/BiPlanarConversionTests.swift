import NitsKernels
import Testing

/// The SIMD conversions against a scalar reference, at widths that leave a tail after the vector steps and with
/// strides padded past the row.
@Suite("BiPlanarConversion")
struct BiPlanarConversionTests {
    private static let widths = [1, 7, 8, 9, 16, 17, 33]
    private static let height = 3
    private static let padding = 5

    @Test("A 10-bit plane is shifted to MSB alignment", arguments: widths)
    func shifts10BitPlane(width: Int) {
        let stride = (width + Self.padding) * 2
        let source = (0..<(stride / 2 * Self.height)).map { UInt16($0 * 37 % 1024) }
        var output = [UInt16](repeating: 0xFFFF, count: source.count)
        source.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                BiPlanarConversion.shift10BitPlane(
                    from: src.baseAddress!, stride: stride, to: dst.baseAddress!, stride: stride,
                    width: width, height: Self.height)
            }
        }
        for row in 0..<Self.height {
            for x in 0..<width {
                let index = row * stride / 2 + x
                #expect(output[index] == source[index] << 6, "row \(row), x \(x)")
            }
            #expect(output[row * stride / 2 + width] == 0xFFFF, "Wrote past row \(row)")
        }
    }

    @Test("10-bit U and V are interleaved into MSB-aligned CbCr", arguments: widths)
    func interleaves10BitChroma(width: Int) {
        let stride = (width + Self.padding) * 2
        let u = (0..<(stride / 2 * Self.height)).map { UInt16($0 * 13 % 1024) }
        let v = (0..<(stride / 2 * Self.height)).map { UInt16(1023 - $0 * 29 % 1024) }
        let dstStride = (width * 2 + Self.padding) * 2
        var output = [UInt16](repeating: 0xFFFF, count: dstStride / 2 * Self.height)
        u.withUnsafeBytes { uBytes in
            v.withUnsafeBytes { vBytes in
                output.withUnsafeMutableBytes { dst in
                    BiPlanarConversion.interleave10BitChroma(
                        u: uBytes.baseAddress!, uStride: stride, v: vBytes.baseAddress!, vStride: stride,
                        to: dst.baseAddress!, stride: dstStride, width: width, height: Self.height)
                }
            }
        }
        for row in 0..<Self.height {
            for x in 0..<width {
                let out = row * dstStride / 2 + x * 2
                #expect(output[out] == u[row * stride / 2 + x] << 6, "Cb at row \(row), x \(x)")
                #expect(output[out + 1] == v[row * stride / 2 + x] << 6, "Cr at row \(row), x \(x)")
            }
            #expect(output[row * dstStride / 2 + width * 2] == 0xFFFF, "Wrote past row \(row)")
        }
    }

    @Test("8-bit U and V are interleaved into CbCr", arguments: widths)
    func interleaves8BitChroma(width: Int) {
        let stride = width + Self.padding
        let u = (0..<(stride * Self.height)).map { UInt8($0 * 13 % 256) }
        let v = (0..<(stride * Self.height)).map { UInt8(255 - $0 * 29 % 256) }
        let dstStride = width * 2 + Self.padding
        var output = [UInt8](repeating: 0xEE, count: dstStride * Self.height)
        u.withUnsafeBytes { uBytes in
            v.withUnsafeBytes { vBytes in
                output.withUnsafeMutableBytes { dst in
                    BiPlanarConversion.interleave8BitChroma(
                        u: uBytes.baseAddress!, uStride: stride, v: vBytes.baseAddress!, vStride: stride,
                        to: dst.baseAddress!, stride: dstStride, width: width, height: Self.height)
                }
            }
        }
        for row in 0..<Self.height {
            for x in 0..<width {
                let out = row * dstStride + x * 2
                #expect(output[out] == u[row * stride + x], "Cb at row \(row), x \(x)")
                #expect(output[out + 1] == v[row * stride + x], "Cr at row \(row), x \(x)")
            }
            #expect(output[row * dstStride + width * 2] == 0xEE, "Wrote past row \(row)")
        }
    }
}
