import CoreVideo

/// The colour primaries the player tells apart, from the CoreVideo value `StreamColorimetry` reads: the one source of
/// the media info's label and of the gamut the Metal shader converts from. The shader knows only BT.2020, BT.709 and
/// P3, so BT.601 and the rest are labelled as what they are but converted as BT.2020 (and with the BT.2020 matrix,
/// see `colorSpaceMode`). That shows only with Metal forced on SDR content: `.auto` uses it for HDR alone.
enum ColorPrimariesClass: Equatable {
    case bt709
    /// EBU 3213 (PAL) and SMPTE C (NTSC): standard-definition video, tagged or untagged.
    case bt601
    case p3
    case bt2020
    case other

    init(_ primaries: CFString) {
        switch primaries {
        case kCVImageBufferColorPrimaries_ITU_R_709_2: self = .bt709
        case kCVImageBufferColorPrimaries_EBU_3213, kCVImageBufferColorPrimaries_SMPTE_C: self = .bt601
        case kCVImageBufferColorPrimaries_DCI_P3, kCVImageBufferColorPrimaries_P3_D65: self = .p3
        case kCVImageBufferColorPrimaries_ITU_R_2020: self = .bt2020
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .bt709: "BT.709"
        case .bt601: "BT.601"
        case .p3: "DCI-P3"
        case .bt2020: "BT.2020"
        case .other: "Unknown"
        }
    }

    /// `ToneMapUniforms.colorPrimaries`: the shader converts from BT.2020 (0), BT.709 (1) or P3 (2), and takes
    /// anything else as BT.2020.
    var shaderIndex: UInt32 {
        switch self {
        case .bt709: 1
        case .p3: 2
        case .bt601, .bt2020, .other: 0
        }
    }
}

/// The transfer functions the player tells apart, from the CoreVideo value `StreamColorimetry` reads: the one source of
/// the media info's label and of what the Metal shader decodes. The shader knows only PQ, HLG and BT.709, so sRGB,
/// SMPTE 240M, linear and the rest are labelled as what they are but decoded as PQ; as with `ColorPrimariesClass`,
/// that shows only with Metal forced on SDR content.
enum TransferFunctionClass: Equatable {
    /// BT.709, or a plain gamma.
    case bt709
    case sRGB
    case smpte240M
    case pq
    case hlg
    case linear
    case other

    init(_ transferFunction: CFString) {
        switch transferFunction {
        case kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferTransferFunction_UseGamma: self = .bt709
        case kCVImageBufferTransferFunction_sRGB: self = .sRGB
        case kCVImageBufferTransferFunction_SMPTE_240M_1995: self = .smpte240M
        case kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ: self = .pq
        case kCVImageBufferTransferFunction_ITU_R_2100_HLG: self = .hlg
        case kCVImageBufferTransferFunction_Linear: self = .linear
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .bt709: "BT.709 / SDR"
        case .sRGB: "sRGB"
        case .smpte240M: "SMPTE 240M"
        case .pq: "PQ (ST 2084)"
        case .hlg: "HLG"
        case .linear: "Linear"
        case .other: "Unknown"
        }
    }

    /// `ToneMapUniforms.transferFunction`: the shader decodes PQ (0), HLG (1) or BT.709 (2), and takes anything else
    /// as PQ.
    var shaderIndex: UInt32 {
        switch self {
        case .bt709: 2
        case .hlg: 1
        case .pq, .sRGB, .smpte240M, .linear, .other: 0
        }
    }
}
