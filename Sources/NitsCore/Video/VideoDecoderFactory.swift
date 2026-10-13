import Foundation
import VideoToolbox

/// Factory creating the optimal video decoder (hardware VideoToolbox or software FFmpegVideoDecoder)
/// based on the video codec and host Apple Silicon capabilities.
public enum VideoDecoderFactory {
    public static func makeDecoder(
        for codec: VideoCodec,
        demuxer: MediaDemuxer
    ) -> (any VideoDecoderProtocol)? {
        if codec.isHardwareAccelerated {
            AppLog.info(.video, "Using Hardware VideoToolbox decoder for \(codec.rawValue)")
            return VTVideoDecoder()
        }

        if let params = demuxer.getVideoCodecParameters() {
            AppLog.info(.video, "Using Software FFmpeg decoder for \(codec.rawValue)")
            if let softwareDecoder = FFmpegVideoDecoder(codecParameters: params, timebase: demuxer.timebase) {
                return softwareDecoder
            }
            AppLog.error(.video, "FFmpegVideoDecoder initialization failed: cannot decode \(codec.rawValue) stream")
            return nil
        } else {
            AppLog.error(.video, "Cannot obtain video codec parameters for \(codec.rawValue) stream")
            return nil
        }
    }
}
