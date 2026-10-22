/// Copies planar 4:2:0 planes into the bi-planar layouts the decoders hand on (NV12, P010), row by row with SIMD.
///
/// This target is built with `-O` in Debug too (see `Package.swift`): under `-Onone` the SIMD types aren't vectorized
/// and the 10-bit path is ~40x slower, so 1080p+ 10-bit software playback falls behind the audio clock. Keep the
/// functions here non-`@inlinable`: inlined into an `-Onone` caller they would lose the optimization.
public enum BiPlanarConversion {
    /// Shifts a plane of 10-bit little-endian samples (`yuv420p10le`) to the MSB-aligned layout of P010.
    /// - Parameters:
    ///   - width: Samples per row.
    ///   - srcStride, dstStride: Bytes per row.
    public static func shift10BitPlane(
        from src: UnsafeRawPointer, stride srcStride: Int, to dst: UnsafeMutableRawPointer, stride dstStride: Int,
        width: Int, height: Int
    ) {
        let step = 8
        for row in 0..<height {
            let sRow = src.advanced(by: row * srcStride).assumingMemoryBound(to: UInt16.self)
            let dRow = dst.advanced(by: row * dstStride).assumingMemoryBound(to: UInt16.self)
            var x = 0
            while x + step <= width {
                let vec = UnsafeRawPointer(sRow.advanced(by: x)).loadUnaligned(as: SIMD8<UInt16>.self)
                UnsafeMutableRawPointer(dRow.advanced(by: x)).storeBytes(of: vec &<< 6, as: SIMD8<UInt16>.self)
                x += step
            }
            while x < width {
                dRow[x] = sRow[x] &<< 6
                x += 1
            }
        }
    }

    /// Interleaves 10-bit little-endian U and V planes into a P010 CbCr plane, shifted to MSB alignment.
    /// - Parameters:
    ///   - width: Samples per row of each source plane (half the luma width, rounded up).
    ///   - uStride, vStride, dstStride: Bytes per row.
    public static func interleave10BitChroma(
        u: UnsafeRawPointer, uStride: Int, v: UnsafeRawPointer, vStride: Int,
        to dst: UnsafeMutableRawPointer, stride dstStride: Int, width: Int, height: Int
    ) {
        let step = 8
        for row in 0..<height {
            let uRow = u.advanced(by: row * uStride).assumingMemoryBound(to: UInt16.self)
            let vRow = v.advanced(by: row * vStride).assumingMemoryBound(to: UInt16.self)
            let uvRow = dst.advanced(by: row * dstStride).assumingMemoryBound(to: UInt16.self)
            var x = 0
            while x + step <= width {
                let uVec = UnsafeRawPointer(uRow.advanced(by: x)).loadUnaligned(as: SIMD8<UInt16>.self) &<< 6
                let vVec = UnsafeRawPointer(vRow.advanced(by: x)).loadUnaligned(as: SIMD8<UInt16>.self) &<< 6

                let lowInterleaved = SIMD8<UInt16>(
                    uVec[0], vVec[0], uVec[1], vVec[1],
                    uVec[2], vVec[2], uVec[3], vVec[3]
                )
                let highInterleaved = SIMD8<UInt16>(
                    uVec[4], vVec[4], uVec[5], vVec[5],
                    uVec[6], vVec[6], uVec[7], vVec[7]
                )

                let destOffset = x * 2
                UnsafeMutableRawPointer(uvRow.advanced(by: destOffset))
                    .storeBytes(of: lowInterleaved, as: SIMD8<UInt16>.self)
                UnsafeMutableRawPointer(uvRow.advanced(by: destOffset + 8))
                    .storeBytes(of: highInterleaved, as: SIMD8<UInt16>.self)

                x += step
            }
            while x < width {
                uvRow[x * 2] = uRow[x] &<< 6
                uvRow[x * 2 + 1] = vRow[x] &<< 6
                x += 1
            }
        }
    }

    /// Interleaves 8-bit U and V planes into an NV12 CbCr plane.
    /// - Parameters:
    ///   - width: Samples per row of each source plane (half the luma width, rounded up).
    ///   - uStride, vStride, dstStride: Bytes per row.
    public static func interleave8BitChroma(
        u: UnsafeRawPointer, uStride: Int, v: UnsafeRawPointer, vStride: Int,
        to dst: UnsafeMutableRawPointer, stride dstStride: Int, width: Int, height: Int
    ) {
        let step = 16
        for row in 0..<height {
            let uRow = u.advanced(by: row * uStride)
            let vRow = v.advanced(by: row * vStride)
            let uvRow = dst.advanced(by: row * dstStride)
            var x = 0
            while x + step <= width {
                let uVec = uRow.advanced(by: x).loadUnaligned(as: SIMD16<UInt8>.self)
                let vVec = vRow.advanced(by: x).loadUnaligned(as: SIMD16<UInt8>.self)

                let lowInterleaved = SIMD16<UInt8>(
                    uVec[0], vVec[0], uVec[1], vVec[1],
                    uVec[2], vVec[2], uVec[3], vVec[3],
                    uVec[4], vVec[4], uVec[5], vVec[5],
                    uVec[6], vVec[6], uVec[7], vVec[7]
                )
                let highInterleaved = SIMD16<UInt8>(
                    uVec[8], vVec[8], uVec[9], vVec[9],
                    uVec[10], vVec[10], uVec[11], vVec[11],
                    uVec[12], vVec[12], uVec[13], vVec[13],
                    uVec[14], vVec[14], uVec[15], vVec[15]
                )

                let destOffset = x * 2
                uvRow.advanced(by: destOffset).storeBytes(of: lowInterleaved, as: SIMD16<UInt8>.self)
                uvRow.advanced(by: destOffset + 16).storeBytes(of: highInterleaved, as: SIMD16<UInt8>.self)

                x += step
            }
            while x < width {
                let uVal = uRow.advanced(by: x).loadUnaligned(as: UInt8.self)
                let vVal = vRow.advanced(by: x).loadUnaligned(as: UInt8.self)
                uvRow.advanced(by: x * 2).storeBytes(of: SIMD2<UInt8>(uVal, vVal), as: SIMD2<UInt8>.self)
                x += 1
            }
        }
    }
}
