import CFFmpeg
import CoreMedia
import Foundation
import VideoToolbox

public enum VideoCodec: String, Sendable {
    case hevc = "HEVC / H.265"
    case h264 = "AVC / H.264"
    case av1 = "AV1"
    case vp9 = "VP9"
    case wmv1 = "Windows Media Video 7 (WMV1)"
    case wmv2 = "Windows Media Video 8 (WMV2)"
    case wmv3 = "Windows Media Video 9 (WMV3)"
    case vc1 = "VC-1 / SMPTE 421M"
    case mpeg4 = "MPEG-4 Part 2 (DivX / Xvid)"
    case msmpeg4v1 = "Microsoft MPEG-4 v1"
    case msmpeg4v2 = "Microsoft MPEG-4 v2"
    case msmpeg4v3 = "Microsoft MPEG-4 v3 (DivX 3)"
    case h263 = "H.263"
    case mpeg1 = "MPEG-1 Video"
    case mpeg2 = "MPEG-2 Video / H.262"
    case unknown = "Unknown"

    /// FourCC representation for CoreMedia format description.
    /// Note: Custom FourCCs ('wmv1', 'wmv2', 'wmv3', 'vc-1', 'mp41', 'mp42', 'mp43') are used
    /// internally to carry format descriptions for software-decoded streams into CMSampleBuffers.
    public var cmVideoCodecType: CMVideoCodecType {
        switch self {
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .h264:
            return kCMVideoCodecType_H264
        case .av1:
            return kCMVideoCodecType_AV1
        case .vp9:
            return kCMVideoCodecType_VP9
        case .wmv1:
            // 'wmv1' = 0x776d7631
            return 0x776D_7631
        case .wmv2:
            // 'wmv2' = 0x776d7632
            return 0x776D_7632
        case .wmv3:
            // 'wmv3' = 0x776d7633
            return 0x776D_7633
        case .vc1:
            // 'vc-1' = 0x76632d31
            return 0x7663_2D31
        case .mpeg4:
            return kCMVideoCodecType_MPEG4Video
        case .msmpeg4v1:
            // 'mp41' = 0x6d703431
            return 0x6D70_3431
        case .msmpeg4v2:
            // 'mp42' = 0x6d703432
            return 0x6D70_3432
        case .msmpeg4v3:
            // 'mp43' = 0x6d703433
            return 0x6D70_3433
        case .h263:
            return kCMVideoCodecType_H263
        case .mpeg1:
            return kCMVideoCodecType_MPEG1Video
        case .mpeg2:
            return kCMVideoCodecType_MPEG2Video
        case .unknown:
            return 0
        }
    }

    /// Short label for the stream info panel.
    public var displayName: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .wmv1: "WMV1"
        case .wmv2: "WMV2"
        case .wmv3: "WMV3"
        case .vc1: "VC-1"
        case .mpeg4: "MPEG-4 Part 2"
        case .msmpeg4v1: "MS-MPEG4 v1"
        case .msmpeg4v2: "MS-MPEG4 v2"
        case .msmpeg4v3: "MS-MPEG4 v3"
        case .h263: "H.263"
        case .mpeg1: "MPEG-1"
        case .mpeg2: "MPEG-2"
        case .unknown: "Unknown"
        }
    }

    /// Cached detection of host AV1 hardware decoding capability.
    public static let isAV1HardwareSupported: Bool = isHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// Cached detection of host VP9 hardware decoding capability.
    public static let isVP9HardwareSupported: Bool = isHardwareDecodeSupported(kCMVideoCodecType_VP9)

    /// VP9 and AV1 hardware decoders ship as VideoToolbox *supplemental* decoders: until registered,
    /// `VTIsHardwareDecodeSupported` reports `false` and sessions can't use them (VP9 on M1/M2 reads
    /// `false` before and `true` after). Registering is a no-op when the hardware lacks the decoder.
    private static func isHardwareDecodeSupported(_ codecType: CMVideoCodecType) -> Bool {
        VTRegisterSupplementalVideoDecoderIfAvailable(codecType)
        return VTIsHardwareDecodeSupported(codecType)
    }

    /// Corresponding FFmpeg AVCodecID (package-internal to avoid leaking CFFmpeg to external modules).
    package var ffmpegCodecID: AVCodecID {
        switch self {
        case .hevc:
            return AV_CODEC_ID_HEVC
        case .h264:
            return AV_CODEC_ID_H264
        case .av1:
            return AV_CODEC_ID_AV1
        case .vp9:
            return AV_CODEC_ID_VP9
        case .wmv1:
            return AV_CODEC_ID_WMV1
        case .wmv2:
            return AV_CODEC_ID_WMV2
        case .wmv3:
            return AV_CODEC_ID_WMV3
        case .vc1:
            return AV_CODEC_ID_VC1
        case .mpeg4:
            return AV_CODEC_ID_MPEG4
        case .msmpeg4v1:
            return AV_CODEC_ID_MSMPEG4V1
        case .msmpeg4v2:
            return AV_CODEC_ID_MSMPEG4V2
        case .msmpeg4v3:
            return AV_CODEC_ID_MSMPEG4V3
        case .h263:
            return AV_CODEC_ID_H263
        case .mpeg1:
            return AV_CODEC_ID_MPEG1VIDEO
        case .mpeg2:
            return AV_CODEC_ID_MPEG2VIDEO
        case .unknown:
            return AV_CODEC_ID_NONE
        }
    }

    /// Indicates whether hardware decoding via Apple VideoToolbox is available on the current host.
    public var isHardwareAccelerated: Bool {
        switch self {
        case .hevc, .h264:
            return true
        case .av1:
            return Self.isAV1HardwareSupported
        case .vp9:
            return Self.isVP9HardwareSupported
        case .wmv1, .wmv2, .wmv3, .vc1, .mpeg4, .msmpeg4v1, .msmpeg4v2, .msmpeg4v3, .h263, .mpeg1, .mpeg2,
            .unknown:
            return false
        }
    }

    /// Whether the video bitstream requires NAL unit parameter sets (SPS/PPS/VPS) for CMVideoFormatDescription.
    public var requiresParameterSets: Bool {
        switch self {
        case .hevc, .h264:
            return true
        case .av1, .vp9, .wmv1, .wmv2, .wmv3, .vc1, .mpeg4, .msmpeg4v1, .msmpeg4v2, .msmpeg4v3, .h263, .mpeg1, .mpeg2,
            .unknown:
            return false
        }
    }

    /// Whether the video bitstream requires NAL unit rewriting to HVCC length-prefixed format for VideoToolbox.
    public var requiresHVCC: Bool {
        switch self {
        case .hevc, .h264:
            return true
        case .av1, .vp9, .wmv1, .wmv2, .wmv3, .vc1, .mpeg4, .msmpeg4v1, .msmpeg4v2, .msmpeg4v3, .h263, .mpeg1, .mpeg2,
            .unknown:
            return false
        }
    }

    /// Resolves a known VideoCodec from an FFmpeg AVCodecID (package-internal).
    package static func from(codecId: AVCodecID) -> VideoCodec? {
        switch codecId {
        case AV_CODEC_ID_HEVC:
            return .hevc
        case AV_CODEC_ID_H264:
            return .h264
        case AV_CODEC_ID_AV1:
            return .av1
        case AV_CODEC_ID_VP9:
            return .vp9
        case AV_CODEC_ID_WMV1:
            return .wmv1
        case AV_CODEC_ID_WMV2:
            return .wmv2
        case AV_CODEC_ID_WMV3:
            return .wmv3
        case AV_CODEC_ID_VC1:
            return .vc1
        case AV_CODEC_ID_MPEG4:
            return .mpeg4
        case AV_CODEC_ID_MSMPEG4V1:
            return .msmpeg4v1
        case AV_CODEC_ID_MSMPEG4V2:
            return .msmpeg4v2
        case AV_CODEC_ID_MSMPEG4V3:
            return .msmpeg4v3
        // Containers report H.263+ as plain H.263 (only RTP keeps H263P apart); one decoder handles both.
        case AV_CODEC_ID_H263, AV_CODEC_ID_H263P:
            return .h263
        case AV_CODEC_ID_MPEG1VIDEO:
            return .mpeg1
        case AV_CODEC_ID_MPEG2VIDEO:
            return .mpeg2
        default:
            return nil
        }
    }
}
