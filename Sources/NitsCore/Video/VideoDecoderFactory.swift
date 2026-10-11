import Foundation
import VideoToolbox

/// Factory creating the optimal video decoder (hardware VideoToolbox or software libdav1d)
/// based on the video codec and host Apple Silicon capabilities.
public enum VideoDecoderFactory {
    public static func makeDecoder(
        for codec: VideoCodec,
        demuxer: MediaDemuxer
    ) -> (any VideoDecoderProtocol)? {
        if codec == .av1 {
            if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
                AppLog.info(.video, "Using Hardware VideoToolbox decoder for AV1")
                return VTVideoDecoder()
            } else if let params = demuxer.getVideoCodecParameters() {
                AppLog.info(.video, "Hardware AV1 not supported on host; using Software libdav1d decoder")
                if let dav1d = Dav1dVideoDecoder(codecParameters: params, timebase: demuxer.timebase) {
                    return dav1d
                }
                AppLog.error(.video, "Dav1dVideoDecoder initialization failed: cannot decode AV1 stream")
                return nil
            } else {
                AppLog.error(.video, "Cannot obtain video codec parameters for AV1 stream")
                return nil
            }
        }
        return VTVideoDecoder()
    }
}
