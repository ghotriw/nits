import Foundation

/// SMPTE ST 2084 (PQ), for every Swift caller (Dolby Vision metadata, the frame meter, the tone-map controller,
/// thumbnails); the shaders have their own.
enum PQ {
    /// Code value → nits. PQ is defined on [0, 1]: past 1 the value is clamped (10 000 nits), as LMS′ from a Dolby
    /// Vision reshaping can reach it; NaN (a degenerate RPU matrix) reads as 0.
    static func toNits(_ value: Float) -> Float {
        guard value > 0 else { return 0 }
        let m1: Float = 2610 / 16384
        let m2: Float = 2523 / 32
        let c1: Float = 3424 / 4096
        let c2: Float = 2413 / 128
        let c3: Float = 2392 / 128
        // On [0, 1] the denominator stays ≥ c2 - c3 ≈ 0.164.
        let p = pow(min(value, 1), 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    /// Nits → code value.
    static func fromNits(_ nits: Float) -> Float {
        let m1: Float = 2610 / 16384
        let m2: Float = 2523 / 32
        let c1: Float = 3424 / 4096
        let c2: Float = 2413 / 128
        let c3: Float = 2392 / 128
        let y = pow(max(nits, 0) / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }
}
