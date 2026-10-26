import CFFmpeg
import CoreVideo
import Foundation
import os

/// Converts decoded frames that `FFmpegVideoDecoder`'s NV12 / P010 copy can't take as they are (4:2:2,
/// 4:4:4, 4:1:1, 4:1:0, RGB, palette, gray) to planar 4:2:0 with libswscale: 10-bit when the source
/// carries more than 8 bits, 8-bit otherwise.
///
/// Only legacy and intermediate codecs (Motion JPEG, DV, Cinepak, QuickTime Animation, ProRes…) take this
/// path, so its cost (~1 ms per 1080p frame) doesn't matter the way it would for the common 4:2:0 codecs.
final class FrameFormatNormalizer: @unchecked Sendable {
    struct Output {
        /// Planar 4:2:0 frame with the source's timing and colour fields; the caller frees it with `av_frame_free`.
        let frame: UnsafeMutablePointer<AVFrame>
        /// YCbCr matrix an RGB source was encoded with, which the pixel buffer must be tagged with; `nil` when
        /// the source already was YCbCr and keeps its own.
        let yCbCrMatrix: CFString?
        /// Where libswscale put the chroma, which replaces the source's: centred, its default for both ends.
        let chromaLocation: CFString = kCVImageBufferChromaLocation_Center
    }

    private struct Configuration: Equatable {
        var sourceFormat: Int32
        var width: Int32
        var height: Int32
        var targetFormat: Int32
    }

    private let lock = OSAllocatedUnfairLock()
    private var context: UnsafeMutablePointer<SwsContext>?
    private var configuration: Configuration?

    deinit {
        if let context {
            sws_freeContext(context)
        }
    }

    /// Formats `FFmpegVideoDecoder` copies directly into NV12 / P010.
    static func isDirectlySupported(_ format: Int32) -> Bool {
        format == AV_PIX_FMT_YUV420P.rawValue
            || format == AV_PIX_FMT_YUVJ420P.rawValue
            || format == AV_PIX_FMT_YUV420P10LE.rawValue
            // VP6A (Flash VP6 with alpha): the first three planes are plain 4:2:0; alpha is dropped.
            || format == AV_PIX_FMT_YUVA420P.rawValue
    }

    func convert(_ source: UnsafeMutablePointer<AVFrame>) -> Output? {
        let width = source.pointee.width
        let height = source.pointee.height
        guard width > 0, height > 0,
            let descriptor = av_pix_fmt_desc_get(AVPixelFormat(rawValue: source.pointee.format))
        else { return nil }

        let flags = descriptor.pointee.flags
        let isRGB = (flags & UInt64(AV_PIX_FMT_FLAG_RGB)) != 0 || (flags & UInt64(AV_PIX_FMT_FLAG_PAL)) != 0
        let targetFormat = descriptor.pointee.comp.0.depth > 8 ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P

        // RGB becomes limited-range YCbCr in the matrix the demuxer tags untagged streams with (BT.601 at SD,
        // BT.709 above). YCbCr sources keep their matrix and range; only the chroma is resampled.
        let isStandardDefinition =
            StreamColorimetry.standardDefinitionPrimaries(width: Int(width), height: Int(height)) != nil
        let rgbMatrix = isStandardDefinition ? SWS_CS_ITU601 : SWS_CS_ITU709
        let sourceFullRange = isRGB || source.pointee.color_range == AVCOL_RANGE_JPEG || Self.isJPEGFormat(source)
        let targetFullRange = !isRGB && sourceFullRange
        let coefficients = sws_getCoefficients(isRGB ? rgbMatrix : SWS_CS_DEFAULT)

        guard let target = av_frame_alloc() else { return nil }
        target.pointee.format = targetFormat.rawValue
        target.pointee.width = width
        target.pointee.height = height
        guard av_frame_get_buffer(target, 0) >= 0, av_frame_copy_props(target, source) >= 0 else {
            var discarded: UnsafeMutablePointer<AVFrame>? = target
            av_frame_free(&discarded)
            return nil
        }
        target.pointee.color_range = targetFullRange ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG

        let scaled = scale(
            source, into: target, targetFormat: targetFormat, coefficients: coefficients,
            sourceFullRange: sourceFullRange, targetFullRange: targetFullRange)

        guard scaled else {
            var discarded: UnsafeMutablePointer<AVFrame>? = target
            av_frame_free(&discarded)
            return nil
        }
        let matrix: CFString? =
            isRGB
            ? (isStandardDefinition ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            : nil
        return Output(frame: target, yCbCrMatrix: matrix)
    }

    /// Runs the shared `SwsContext`, rebuilt when the source format or size changes. Locked: the decoder may
    /// convert from its feeding and seek threads.
    private func scale(
        _ source: UnsafeMutablePointer<AVFrame>,
        into target: UnsafeMutablePointer<AVFrame>,
        targetFormat: AVPixelFormat,
        coefficients: UnsafePointer<Int32>?,
        sourceFullRange: Bool,
        targetFullRange: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let width = source.pointee.width
        let height = source.pointee.height
        let wanted = Configuration(
            sourceFormat: source.pointee.format, width: width, height: height, targetFormat: targetFormat.rawValue)
        if configuration != wanted || context == nil {
            if let context {
                sws_freeContext(context)
            }
            context = sws_getContext(
                width, height, AVPixelFormat(rawValue: source.pointee.format),
                width, height, targetFormat,
                Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            configuration = context != nil ? wanted : nil
        }
        guard let context else { return false }
        _ = sws_setColorspaceDetails(
            context, coefficients, sourceFullRange ? 1 : 0, coefficients, targetFullRange ? 1 : 0, 0, 1 << 16, 1 << 16)

        let ret = withUnsafePointer(to: &source.pointee.data) { sourceData in
            withUnsafePointer(to: &source.pointee.linesize) { sourceLinesize in
                withUnsafeMutablePointer(to: &target.pointee.data) { targetData in
                    withUnsafeMutablePointer(to: &target.pointee.linesize) { targetLinesize in
                        sws_scale(
                            context,
                            UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(sourceData)),
                            UnsafePointer<Int32>(OpaquePointer(sourceLinesize)),
                            0,
                            height,
                            UnsafePointer<UnsafeMutablePointer<UInt8>?>(OpaquePointer(targetData)),
                            UnsafePointer<Int32>(OpaquePointer(targetLinesize))
                        )
                    }
                }
            }
        }
        return ret > 0
    }
    /// Deprecated `yuvj*` formats imply full range without setting `color_range`.
    private static func isJPEGFormat(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let format = frame.pointee.format
        return format == AV_PIX_FMT_YUVJ420P.rawValue || format == AV_PIX_FMT_YUVJ422P.rawValue
            || format == AV_PIX_FMT_YUVJ444P.rawValue || format == AV_PIX_FMT_YUVJ440P.rawValue
            || format == AV_PIX_FMT_YUVJ411P.rawValue
    }
}
