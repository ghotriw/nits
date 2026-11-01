import CFFmpeg
import CoreMedia
import Foundation
import VideoToolbox

public enum VideoCodec: Sendable, Hashable, CustomStringConvertible {
    case hevc
    case h264
    case av1
    case vp9
    case wmv1
    case wmv2
    case wmv3
    case vc1
    case mpeg4
    case msmpeg4v1
    case msmpeg4v2
    case msmpeg4v3
    case h263
    case mpeg1
    case mpeg2
    case flv1
    case vp6
    case vp8
    case theora
    case rv10
    case rv20
    case rv30
    case rv40
    /// Apple ProRes, by the FourCC of its profile (`apco` Proxy, `apcs` LT, `apcn` 422, `apch` 422 HQ, `ap4h` 4444,
    /// `ap4x` 4444 XQ). Decoded by VideoToolbox, which has a ProRes decoder (in hardware on Pro / Max / Ultra chips)
    /// on every Mac; `FFmpegVideoDecoder` takes over when a session can't be made, and for interlaced streams.
    case proRes(fourCC: UInt32)
    /// Any other video codec FFmpeg can decode (Motion JPEG, DV, Cinepak…), by its raw `AVCodecID`.
    /// Decoded by `FFmpegVideoDecoder`; frames that aren't 4:2:0 are converted with libswscale.
    case software(ffmpegCodecID: UInt32)
    case unknown

    /// Full name for logs.
    public var description: String {
        switch self {
        case .hevc: "HEVC / H.265"
        case .h264: "AVC / H.264"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .wmv1: "Windows Media Video 7 (WMV1)"
        case .wmv2: "Windows Media Video 8 (WMV2)"
        case .wmv3: "Windows Media Video 9 (WMV3)"
        case .vc1: "VC-1 / SMPTE 421M"
        case .mpeg4: "MPEG-4 Part 2 (DivX / Xvid)"
        case .msmpeg4v1: "Microsoft MPEG-4 v1"
        case .msmpeg4v2: "Microsoft MPEG-4 v2"
        case .msmpeg4v3: "Microsoft MPEG-4 v3 (DivX 3)"
        case .h263: "H.263"
        case .mpeg1: "MPEG-1 Video"
        case .mpeg2: "MPEG-2 Video / H.262"
        case .flv1: "Sorenson Spark (FLV1)"
        case .vp6: "On2 VP6"
        case .vp8: "VP8"
        case .theora: "Theora"
        case .rv10: "RealVideo 1.0"
        case .rv20: "RealVideo 2.0"
        case .rv30: "RealVideo 3.0"
        case .rv40: "RealVideo 4.0"
        case .proRes: "Apple \(displayName)"
        case .software: "\(displayName) (FFmpeg \(Self.ffmpegName(of: ffmpegCodecID)))"
        case .unknown: "Unknown"
        }
    }

    /// FourCC representation for CoreMedia format description.
    /// Note: Custom FourCCs ('wmv1', 'wmv2', 'wmv3', 'vc-1', 'mp41', 'mp42', 'mp43', 'flv1', 'vp60', 'vp08', 'theo',
    /// 'rv10'-'rv40', 'ffsw') are used internally to carry format descriptions for software-decoded streams into
    /// CMSampleBuffers.
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
        case .flv1:
            // 'flv1' = 0x666c7631
            return 0x666C_7631
        case .vp6:
            // 'vp60' = 0x76703630
            return 0x7670_3630
        case .vp8:
            // 'vp08' = 0x76703038
            return 0x7670_3038
        case .theora:
            // 'theo' = 0x7468656f
            return 0x7468_656F
        case .rv10:
            // 'rv10' = 0x72763130
            return 0x7276_3130
        case .rv20:
            // 'rv20' = 0x72763230
            return 0x7276_3230
        case .rv30:
            // 'rv30' = 0x72763330
            return 0x7276_3330
        case .rv40:
            // 'rv40' = 0x72763430
            return 0x7276_3430
        case .proRes(let fourCC):
            return fourCC
        case .software:
            // 'ffsw' = 0x66667377
            return 0x6666_7377
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
        case .flv1: "Sorenson Spark"
        case .vp6: "VP6"
        case .vp8: "VP8"
        case .theora: "Theora"
        case .rv10: "RealVideo 1"
        case .rv20: "RealVideo 2"
        case .rv30: "RealVideo 3"
        case .rv40: "RealVideo 4"
        case .proRes(let fourCC): Self.proResProfileName(fourCC)
        case .software(let id): Self.ffmpegLongName(of: AVCodecID(rawValue: id))
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
        case .flv1:
            return AV_CODEC_ID_FLV1
        case .vp6:
            return AV_CODEC_ID_VP6
        case .vp8:
            return AV_CODEC_ID_VP8
        case .theora:
            return AV_CODEC_ID_THEORA
        case .rv10:
            return AV_CODEC_ID_RV10
        case .rv20:
            return AV_CODEC_ID_RV20
        case .rv30:
            return AV_CODEC_ID_RV30
        case .rv40:
            return AV_CODEC_ID_RV40
        case .proRes:
            return AV_CODEC_ID_PRORES
        case .software(let id):
            return AVCodecID(rawValue: id)
        case .unknown:
            return AV_CODEC_ID_NONE
        }
    }

    /// Indicates whether hardware decoding via Apple VideoToolbox is available on the current host.
    /// Every other codec is decoded in software by `FFmpegVideoDecoder`.
    public var isHardwareAccelerated: Bool {
        switch self {
        case .hevc, .h264:
            return true
        case .av1:
            return Self.isAV1HardwareSupported
        case .vp9:
            return Self.isVP9HardwareSupported
        case .proRes:
            // VideoToolbox's ProRes decoder runs in hardware where the chip has the media engine block and in
            // software otherwise; either way it is faster than FFmpeg's, and the factory probes the session.
            return true
        default:
            return false
        }
    }

    /// The FourCCs of the ProRes profiles (`CMVideoCodecType`s), in FFmpeg's profile order.
    package static let proResFourCCs: [UInt32] = [
        kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422,
        kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
    ]

    private static func proResProfileName(_ fourCC: UInt32) -> String {
        switch fourCC {
        case kCMVideoCodecType_AppleProRes422Proxy: "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422: "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes4444: "ProRes 4444"
        case kCMVideoCodecType_AppleProRes4444XQ: "ProRes 4444 XQ"
        default: "ProRes"
        }
    }

    /// The video codec of a stream. Like `from(codecId:)`, but names the ProRes profile, which the codec ID
    /// doesn't: the container's tag (MOV, MXF, MKV with a `V_QUICKTIME` tag) says it, else FFmpeg's profile.
    package static func from(parameters: UnsafePointer<AVCodecParameters>) -> VideoCodec? {
        guard parameters.pointee.codec_id == AV_CODEC_ID_PRORES else {
            return from(codecId: parameters.pointee.codec_id)
        }
        // FFmpeg's tags are little-endian FourCCs; CoreMedia's are big-endian.
        let tag = parameters.pointee.codec_tag.byteSwapped
        if proResFourCCs.contains(tag) {
            return .proRes(fourCC: tag)
        }
        let profile = Int(parameters.pointee.profile)
        if proResFourCCs.indices.contains(profile) {
            return .proRes(fourCC: proResFourCCs[profile])
        }
        // Profile unknown (a bare stream): 4:4:4 content is 4444, anything else the common 422.
        let is444 =
            parameters.pointee.format == AV_PIX_FMT_YUV444P10LE.rawValue
            || parameters.pointee.format == AV_PIX_FMT_YUVA444P10LE.rawValue
        return .proRes(fourCC: is444 ? kCMVideoCodecType_AppleProRes4444 : kCMVideoCodecType_AppleProRes422)
    }

    /// Whether the video bitstream requires NAL unit parameter sets (SPS/PPS/VPS) for CMVideoFormatDescription.
    public var requiresParameterSets: Bool {
        self == .hevc || self == .h264
    }

    /// Whether the video bitstream requires NAL unit rewriting to HVCC length-prefixed format for VideoToolbox.
    public var requiresHVCC: Bool {
        self == .hevc || self == .h264
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
        case AV_CODEC_ID_FLV1:
            return .flv1
        // VP6F is VP6 as Flash stores it (flipped, with its own header); VP6A adds an alpha plane.
        case AV_CODEC_ID_VP6, AV_CODEC_ID_VP6F, AV_CODEC_ID_VP6A:
            return .vp6
        case AV_CODEC_ID_VP8:
            return .vp8
        case AV_CODEC_ID_THEORA:
            return .theora
        case AV_CODEC_ID_RV10:
            return .rv10
        case AV_CODEC_ID_RV20:
            return .rv20
        case AV_CODEC_ID_RV30:
            return .rv30
        case AV_CODEC_ID_RV40:
            return .rv40
        default:
            // Anything else FFmpeg has a video decoder for plays in software.
            guard let decoder = avcodec_find_decoder(codecId), decoder.pointee.type == AVMEDIA_TYPE_VIDEO else {
                return nil
            }
            return .software(ffmpegCodecID: codecId.rawValue)
        }
    }

    /// FFmpeg's short codec name (e.g. "mjpeg").
    private static func ffmpegName(of id: AVCodecID) -> String {
        String(cString: avcodec_get_name(id))
    }

    /// FFmpeg's descriptive codec name (e.g. "Motion JPEG"), or its short name when it has none.
    private static func ffmpegLongName(of id: AVCodecID) -> String {
        guard let longName = avcodec_descriptor_get(id)?.pointee.long_name else { return ffmpegName(of: id) }
        return String(cString: longName)
    }
}
