import CFFmpeg
import CoreVideo
import Foundation

/// A video stream's colour description as CoreVideo values, read from its codec parameters.
/// Unsignalled values fall back by resolution: BT.601 at SD, BT.709 otherwise.
struct StreamColorimetry {
    var colorPrimaries: CFString
    var transferFunction: CFString
    var yCbCrMatrix: CFString
    var isFullRange: Bool
    /// Where the subsampled chroma sits relative to luma; left (MPEG-2 onwards, H.264, HEVC, AV1) when unsignalled.
    var chromaLocation: CFString
    /// 10 for 10-bit pixel formats and for PQ / HLG HEVC, AV1 and VP9, otherwise 8.
    var bitDepth: Int

    init(codecParameters codecpar: UnsafePointer<AVCodecParameters>, width: Int, height: Int) {
        // Untagged streams: SD resolutions are BT.601 (DVD, DV, DivX rips), everything else BT.709.
        let sdPrimaries = Self.standardDefinitionPrimaries(width: width, height: height)

        // Dynamically map color primaries
        if let primaries = Self.known(
            CVColorPrimariesGetStringForIntegerCodePoint(
                Int32(codecpar.pointee.color_primaries.rawValue)), in: Self.knownPrimaries)
        {
            self.colorPrimaries = primaries
        } else {
            switch codecpar.pointee.color_primaries {
            case AVCOL_PRI_BT709:
                self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2
            case AVCOL_PRI_BT2020:
                self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_2020
            case AVCOL_PRI_SMPTE431:
                self.colorPrimaries = kCVImageBufferColorPrimaries_DCI_P3
            case AVCOL_PRI_SMPTE432:
                self.colorPrimaries = kCVImageBufferColorPrimaries_P3_D65
            default:
                self.colorPrimaries = sdPrimaries ?? kCVImageBufferColorPrimaries_ITU_R_709_2
            }
        }

        // Dynamically map transfer characteristics (TRC)
        if let trc = Self.known(
            CVTransferFunctionGetStringForIntegerCodePoint(Int32(codecpar.pointee.color_trc.rawValue)),
            in: Self.knownTransferFunctions)
        {
            self.transferFunction = trc
        } else {
            switch codecpar.pointee.color_trc {
            case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_SMPTE240M:
                self.transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2
            case AVCOL_TRC_SMPTE2084:
                self.transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            case AVCOL_TRC_ARIB_STD_B67:
                self.transferFunction = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            case AVCOL_TRC_GAMMA22:
                self.transferFunction = kCVImageBufferTransferFunction_UseGamma
            case AVCOL_TRC_LINEAR:
                self.transferFunction = kCVImageBufferTransferFunction_Linear
            default:
                self.transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2
            }
        }

        // Dynamically map YCbCr color matrix / colorspace
        if let matrix = Self.known(
            CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(codecpar.pointee.color_space.rawValue)),
            in: Self.knownMatrices)
        {
            self.yCbCrMatrix = matrix
        } else {
            switch codecpar.pointee.color_space {
            case AVCOL_SPC_BT709:
                self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL:
                self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
            case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M:
                self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
            case AVCOL_SPC_SMPTE240M:
                self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
            default:
                self.yCbCrMatrix =
                    sdPrimaries != nil
                    ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
            }
        }

        self.isFullRange = codecpar.pointee.color_range == AVCOL_RANGE_JPEG
        self.chromaLocation = Self.chromaLocation(codecpar.pointee.chroma_location)

        // Bit depth detection
        let pixFmt = codecpar.pointee.format
        let codecId = codecpar.pointee.codec_id
        if pixFmt == AV_PIX_FMT_YUV420P10LE.rawValue || pixFmt == AV_PIX_FMT_YUV420P10BE.rawValue
            || pixFmt == AV_PIX_FMT_YUV422P10LE.rawValue || pixFmt == AV_PIX_FMT_YUV444P10LE.rawValue
            || ((codecId == AV_CODEC_ID_HEVC || codecId == AV_CODEC_ID_AV1 || codecId == AV_CODEC_ID_VP9)
                && (self.transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                    || self.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG))
        {
            self.bitDepth = 10
        } else {
            self.bitDepth = 8
        }
    }

    /// The CoreVideo constants `CV*GetStringForIntegerCodePoint` maps H.273 code points to. For the rest it returns
    /// placeholders such as "YCbCrMatrix#5" (BT.470BG, i.e. PAL BT.601) that no CoreVideo consumer understands;
    /// those fall through to the FFmpeg mapping below them instead.
    private static let knownPrimaries: Set<String> = [
        kCVImageBufferColorPrimaries_ITU_R_709_2 as String, kCVImageBufferColorPrimaries_EBU_3213 as String,
        kCVImageBufferColorPrimaries_SMPTE_C as String, kCVImageBufferColorPrimaries_ITU_R_2020 as String,
        kCVImageBufferColorPrimaries_DCI_P3 as String, kCVImageBufferColorPrimaries_P3_D65 as String,
    ]
    private static let knownTransferFunctions: Set<String> = [
        kCVImageBufferTransferFunction_ITU_R_709_2 as String, kCVImageBufferTransferFunction_SMPTE_240M_1995 as String,
        kCVImageBufferTransferFunction_Linear as String, kCVImageBufferTransferFunction_sRGB as String,
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
        kCVImageBufferTransferFunction_SMPTE_ST_428_1 as String,
        kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
    ]
    /// ICtCp and IPT (Dolby Vision profile 5) have no public constant; these are the strings CoreVideo returns.
    private static let knownMatrices: Set<String> = [
        kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String,
        kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
        "ITU_R_2100_ICtCp", "IPT_C2",
    ]

    private static func known(_ value: Unmanaged<CFString>?, in constants: Set<String>) -> CFString? {
        guard let value = value?.takeUnretainedValue(), constants.contains(value as String) else { return nil }
        return value
    }

    static func chromaLocation(_ location: AVChromaLocation) -> CFString {
        switch location {
        case AVCHROMA_LOC_CENTER: kCVImageBufferChromaLocation_Center
        case AVCHROMA_LOC_TOPLEFT: kCVImageBufferChromaLocation_TopLeft
        case AVCHROMA_LOC_TOP: kCVImageBufferChromaLocation_Top
        case AVCHROMA_LOC_BOTTOMLEFT: kCVImageBufferChromaLocation_BottomLeft
        case AVCHROMA_LOC_BOTTOM: kCVImageBufferChromaLocation_Bottom
        default: kCVImageBufferChromaLocation_Left
        }
    }

    /// Primaries assumed for a stream that doesn't signal its colorimetry, or `nil` for HD (BT.709). Standard
    /// definition (≤ 576 lines, narrower than 1280) is BT.601: EBU primaries for 625-line systems
    /// (576/288 lines), SMPTE C for 525-line ones (480/486/240).
    static func standardDefinitionPrimaries(width: Int, height: Int) -> CFString? {
        guard width > 0, height > 0, width < 1280, height <= 576 else { return nil }
        let isPAL = height == 576 || height == 288
        return isPAL ? kCVImageBufferColorPrimaries_EBU_3213 : kCVImageBufferColorPrimaries_SMPTE_C
    }
}
