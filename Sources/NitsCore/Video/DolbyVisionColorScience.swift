import Foundation
import simd

/// Single source of truth for Dolby Vision color science constants (IPT-PQ-c2 matrices and Hunt-Pointer-Estevez LMS).
enum DolbyVisionColorScience {
    /// Hunt-Pointer-Estevez (HPE) crosstalk-free LMS -> BT.2020 Linear RGB.
    static let hpeLmsToRgb = simd_float3x3(rows: [
        SIMD3(3.06441879, -2.16597676, 0.10155818),
        SIMD3(-0.65612108, 1.78554118, -0.12943749),
        SIMD3(0.01736321, -0.04725154, 1.03004253),
    ])

    /// Default Dolby Vision IPT-PQ-c2 `IPT -> LMS'` (`[8192, 799, 1681; 8192, -933, 1091; 8192, 267, -5545] / 8192`).
    static let defaultIptToLms = simd_float3x3(rows: [
        SIMD3(1.0, 0.09753418, 0.20520020),
        SIMD3(1.0, -0.11389160, 0.13317871),
        SIMD3(1.0, 0.03259277, -0.67687988),
    ])
    static let defaultIptOffset = SIMD3<Float>(0.0, 0.5, 0.5)

    /// Default Dolby Vision IPT-PQ-c2 `LMS_c2 -> BT.2020 Linear RGB` (`HPE_LMS_TO_BT2020 * C_c2^-1`).
    static let defaultLmsToRgb = simd_float3x3(rows: [
        SIMD3(3.2387587, -2.3255600, 0.0867407),
        SIMD3(-0.7193106, 1.8782343, -0.1590020),
        SIMD3(-0.0028328, -0.0715728, 1.0744987),
    ])

    /// `LMS -> BT.2020 Linear RGB` for the RPU's custom `rgb_to_lms_matrix`: the Hunt-Pointer-Estevez matrix times it.
    static func lmsToRgb(rgbToLms: simd_float3x3) -> simd_float3x3 {
        hpeLmsToRgb * rgbToLms
    }
}
