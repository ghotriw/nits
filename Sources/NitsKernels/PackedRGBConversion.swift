/// Unpacks 10-bit packed RGB texels (Metal's `.bgr10a2Unorm`) into 16-bit RGB, for still images.
///
/// Built with `-O` in Debug too, like `BiPlanarConversion`: a 4K frame is 8 M texels. Keep the functions here
/// non-`@inlinable`.
public enum PackedRGBConversion {
    /// Converts `count` texels laid out as `(A << 30) | (R << 20) | (G << 10) | B` into R, G, B `UInt16` triples.
    /// 10 bits go to 16 by bit replication, so 0 and 1023 stay black and white and the steps stay even.
    public static func unpack10BitBGRA(
        from src: UnsafePointer<UInt32>, to dst: UnsafeMutablePointer<UInt16>, count: Int
    ) {
        for index in 0..<count {
            let texel = src[index]
            let red = UInt16(truncatingIfNeeded: (texel >> 20) & 0x3FF)
            let green = UInt16(truncatingIfNeeded: (texel >> 10) & 0x3FF)
            let blue = UInt16(truncatingIfNeeded: texel & 0x3FF)
            dst[index * 3] = red &<< 6 | red &>> 4
            dst[index * 3 + 1] = green &<< 6 | green &>> 4
            dst[index * 3 + 2] = blue &<< 6 | blue &>> 4
        }
    }
}
