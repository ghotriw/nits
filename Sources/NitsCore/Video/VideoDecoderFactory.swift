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
            // H.264 and HEVC have guaranteed VT hardware on Apple Silicon — no probe needed.
            // AV1 and VP9 report hardware support via VTIsHardwareDecodeSupported, but on
            // virtualised CI runners the hypervisor exposes the flag without the actual decoder
            // block, causing VTDecompressionSessionCreate to fail silently. Probe first and
            // fall through to FFmpeg when that happens.
            let needsProbe = codec == .av1 || codec == .vp9
            if !needsProbe || canCreateVTSession(for: codec, formatDescription: demuxer.formatDescription) {
                AppLog.info(.video, "Using Hardware VideoToolbox decoder for \(codec)")
                return VTVideoDecoder()
            }
            AppLog.warning(
                .video,
                "VTDecompressionSession probe failed for \(codec) — falling back to software decoder"
            )
        }

        if let params = demuxer.getVideoCodecParameters() {
            AppLog.info(.video, "Using Software FFmpeg decoder for \(codec)")
            if let softwareDecoder = FFmpegVideoDecoder(codecParameters: params, timebase: demuxer.timebase) {
                return softwareDecoder
            }
            AppLog.error(.video, "FFmpegVideoDecoder initialization failed: cannot decode \(codec) stream")
            return nil
        } else {
            AppLog.error(.video, "Cannot obtain video codec parameters for \(codec) stream")
            return nil
        }
    }

    /// Probes whether a VTDecompressionSession can be created for the given codec.
    /// Creates and immediately destroys a session — cheap, no frames decoded.
    private static func canCreateVTSession(
        for codec: VideoCodec,
        formatDescription: CMVideoFormatDescription?
    ) -> Bool {
        guard let formatDescription else {
            // No format description yet — optimistically allow VT; it will fail gracefully on first decode.
            return true
        }
        let spec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        if status != noErr {
            AppLog.warning(.video, "VT probe session failed for \(codec): \(status)")
        }
        return status == noErr
    }
}
