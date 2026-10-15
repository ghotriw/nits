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
    case unknown = "Unknown"

    /// FourCC representation for CoreMedia format description.
    /// Note: Custom FourCCs ('wmv1', 'wmv2', 'wmv3', 'vc-1') are used internally to carry
    /// format descriptions for software-decoded streams into CMSampleBuffers.
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
        case .unknown:
            return 0
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
        case .wmv1, .wmv2, .wmv3, .vc1, .unknown:
            return false
        }
    }

    /// Whether the video bitstream requires NAL unit parameter sets (SPS/PPS/VPS) for CMVideoFormatDescription.
    public var requiresParameterSets: Bool {
        switch self {
        case .hevc, .h264:
            return true
        case .av1, .vp9, .wmv1, .wmv2, .wmv3, .vc1, .unknown:
            return false
        }
    }

    /// Whether the video bitstream requires NAL unit rewriting to HVCC length-prefixed format for VideoToolbox.
    public var requiresHVCC: Bool {
        switch self {
        case .hevc, .h264:
            return true
        case .av1, .vp9, .wmv1, .wmv2, .wmv3, .vc1, .unknown:
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
        default:
            return nil
        }
    }
}
