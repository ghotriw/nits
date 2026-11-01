import CFFmpeg
import Foundation

/// The family of a codec told by a streaming manifest's `CODECS` / `codecs` string ("avc1.64001f,mp4a.40.2"): what the
/// HLS and DASH manifests are read for, to tell which streams are of the same kind.
enum CodecFamily {
    /// The video codec of a list, by family: the first entry that is a video codec's, its four-character code with a
    /// profile's variants made one (`avc1` and `avc3`, `hvc1` and `hev1`, `dvh1` and `dvhe`). Nil for a list without one.
    static func video(in codecs: String) -> String? {
        let families = [
            "avc1": "avc", "avc3": "avc", "hvc1": "hevc", "hev1": "hevc", "dvh1": "dvhevc", "dvhe": "dvhevc",
            "dva1": "dvavc", "dvav": "dvavc", "av01": "av1", "dav1": "dvav1", "vp09": "vp9", "vp08": "vp8",
            "vp9": "vp9", "vp8": "vp8",
        ]
        return codecs.split(separator: ",").lazy.compactMap { entry in
            families[String(entry.trimmingCharacters(in: .whitespaces).prefix { $0 != "." })]
        }.first
    }

    /// Whether the bundled FFmpeg decodes the audio codec of a list (its first entry): nil for a codec this does not
    /// know by name, which is left to be tried. The sounds are all decoded by FFmpeg, so its decoders are the answer
    /// (it has none for AC-4 and MPEG-H 3D Audio, which a broadcaster's manifest may list over the AAC).
    static func canDecodeAudio(in codecs: String) -> Bool? {
        let entry =
            codecs.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let parts = entry.split(separator: ".").map(String.init)
        guard let family = parts.first else { return nil }
        let id: AVCodecID? =
            switch family {
            case "mp4a":
                // The object type: 0x40 is AAC, 0x69 and 0x6b MPEG audio, 0xa5 AC-3, 0xa6 E-AC-3, 0xa9 and up DTS.
                switch parts.dropFirst().first {
                case "40": AV_CODEC_ID_AAC
                case "69", "6b": AV_CODEC_ID_MP3
                case "a5": AV_CODEC_ID_AC3
                case "a6": AV_CODEC_ID_EAC3
                case "a9", "aa", "ab", "ac": AV_CODEC_ID_DTS
                default: nil
                }
            case "ac-3": AV_CODEC_ID_AC3
            case "ec-3": AV_CODEC_ID_EAC3
            case "ac-4": AV_CODEC_ID_AC4
            case "mhm1", "mhm2", "mha1", "mha2": AV_CODEC_ID_MPEGH_3D_AUDIO
            case "opus": AV_CODEC_ID_OPUS
            case "vorbis": AV_CODEC_ID_VORBIS
            case "flac": AV_CODEC_ID_FLAC
            case "mp3": AV_CODEC_ID_MP3
            case "alac": AV_CODEC_ID_ALAC
            case "dtsc", "dtsh", "dtse", "dtsl", "dtsx": AV_CODEC_ID_DTS
            default: nil
            }
        return id.map { avcodec_find_decoder($0) != nil }
    }

    /// Whether a video family (`video(in:)`) is Dolby Vision.
    static func isDolbyVision(_ family: String) -> Bool {
        family.hasPrefix("dv")
    }

    /// A video family as shown ("H.264", "HEVC", "AV1", "VP9").
    static func displayName(ofVideo family: String) -> String {
        switch family {
        case "avc": "H.264"
        case "hevc": "HEVC"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "dvhevc", "dvavc", "dvav1": "Dolby Vision"
        default: family.uppercased()
        }
    }
}
