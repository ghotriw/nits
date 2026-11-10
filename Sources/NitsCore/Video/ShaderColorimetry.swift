import CoreVideo
import simd

/// The colour matrices the Metal shader decodes a stream with (`ToneMapUniforms`), from the stream's CoreVideo values:
/// Y'CbCr → R'G'B' by its matrix coefficients (ITU-R BT.709 / BT.601 / BT.2020, SMPTE 240M) and its linear RGB to
/// BT.2020 and to Display P3 by its primaries' chromaticities (RGB → XYZ as in SMPTE RP 177, both at D65).
enum ShaderColorimetry {
    /// Y'CbCr (Y' in [0, 1], Cb / Cr around 0) → R'G'B' for `matrix`; BT.709 for one the shader doesn't know. ICtCp and
    /// IPT outside Dolby Vision Profile 5 (which decodes by the RPU) have no decoder here and take BT.2020's, their
    /// primaries: an approximation.
    static func yCbCrToRGB(_ matrix: CFString) -> simd_float3x3 {
        let (kr, kb): (Float, Float) =
            switch matrix {
            case kCVImageBufferYCbCrMatrix_ITU_R_2020, StreamColorimetry.ictcpMatrix, StreamColorimetry.iptC2Matrix:
                (0.2627, 0.0593)
            case kCVImageBufferYCbCrMatrix_ITU_R_601_4: (0.299, 0.114)
            case kCVImageBufferYCbCrMatrix_SMPTE_240M_1995: (0.212, 0.087)
            default: (0.2126, 0.0722)
            }
        let kg = 1 - kr - kb
        return simd_float3x3(
            columns: (
                SIMD3(1, 1, 1),
                SIMD3(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb)),
                SIMD3(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0)
            ))
    }

    /// Linear RGB of `primaries` → linear BT.2020.
    static func toBT2020(_ primaries: CFString) -> simd_float3x3 {
        conversion(from: Primaries(primaries), to: .bt2020)
    }

    /// Linear RGB of `primaries` → linear Display P3; out-of-gamut values stay out (see `fitsDisplayP3`).
    static func toDisplayP3(_ primaries: CFString) -> simd_float3x3 {
        conversion(from: Primaries(primaries), to: .p3)
    }

    /// Whether every colour of `primaries` lies inside Display P3: SDR then needs no gamut fit.
    static func fitsDisplayP3(_ primaries: CFString) -> Bool {
        Primaries(primaries) != .bt2020
    }

    /// The chromaticities of the primaries the player tells apart. DCI-P3 is taken with the D65 white of P3-D65, as
    /// video tagged with it is in practice; anything unknown as BT.709, `StreamColorimetry`'s own fallback.
    enum Primaries: Equatable {
        case bt709, ebu3213, smpteC, p3, bt2020

        init(_ primaries: CFString) {
            switch primaries {
            case kCVImageBufferColorPrimaries_ITU_R_2020: self = .bt2020
            case kCVImageBufferColorPrimaries_DCI_P3, kCVImageBufferColorPrimaries_P3_D65: self = .p3
            case kCVImageBufferColorPrimaries_EBU_3213: self = .ebu3213
            case kCVImageBufferColorPrimaries_SMPTE_C: self = .smpteC
            default: self = .bt709
            }
        }

        /// (x, y) of red, green and blue.
        var chromaticities: (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>) {
            switch self {
            case .bt709: (SIMD2(0.640, 0.330), SIMD2(0.300, 0.600), SIMD2(0.150, 0.060))
            case .ebu3213: (SIMD2(0.640, 0.330), SIMD2(0.290, 0.600), SIMD2(0.150, 0.060))
            case .smpteC: (SIMD2(0.630, 0.340), SIMD2(0.310, 0.595), SIMD2(0.155, 0.070))
            case .p3: (SIMD2(0.680, 0.320), SIMD2(0.265, 0.690), SIMD2(0.150, 0.060))
            case .bt2020: (SIMD2(0.708, 0.292), SIMD2(0.170, 0.797), SIMD2(0.131, 0.046))
            }
        }
    }

    private static let whiteD65 = SIMD2<Double>(0.3127, 0.3290)

    private static func rgbToXYZ(_ primaries: Primaries) -> simd_double3x3 {
        func xyz(_ c: SIMD2<Double>) -> SIMD3<Double> { SIMD3(c.x / c.y, 1, (1 - c.x - c.y) / c.y) }
        let (r, g, b) = primaries.chromaticities
        let m = simd_double3x3(columns: (xyz(r), xyz(g), xyz(b)))
        let s = m.inverse * xyz(whiteD65)
        return simd_double3x3(columns: (m.columns.0 * s.x, m.columns.1 * s.y, m.columns.2 * s.z))
    }

    private static func conversion(from source: Primaries, to target: Primaries) -> simd_float3x3 {
        if source == target { return matrix_identity_float3x3 }
        let m = rgbToXYZ(target).inverse * rgbToXYZ(source)
        return simd_float3x3(
            columns: (
                SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2)
            ))
    }
}
