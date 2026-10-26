import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import NitsCore

@Suite("FrameFormatNormalizer: libswscale fallback to planar 4:2:0")
struct FrameFormatNormalizerTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let preset: SyntheticTestMediaFactory.Preset
        let pixelFormat: OSType
        /// Only RGB sources get a matrix from the converter; YCbCr ones keep the demuxer's.
        let matrix: String

        var testDescription: String { preset.rawValue }
    }

    static let cases: [Case] = [
        // yuvj422p: full range survives the chroma resampling.
        Case(
            preset: .mjpegAVI, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String),
        Case(
            preset: .dvNTSC, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String),
        Case(
            preset: .cinepakMOV, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String),
        // 10-bit sources keep their depth: P010.
        Case(
            preset: .proresMOV, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String),
    ]

    @Test("Frames that aren't planar 4:2:0 decode into NV12 / P010 with the right range and matrix", arguments: cases)
    func decodesThroughFallback(_ testCase: Case) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: testCase.preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let params = try #require(demuxer.getVideoCodecParameters())
        let decoder = try #require(FFmpegVideoDecoder(codecParameters: params, timebase: demuxer.timebase))

        struct Observed: Sendable {
            let pixelFormat: OSType
            let width: Int
            let height: Int
            let matrix: String?
            let chromaLocation: String?
        }
        let first = LockIsolated<Observed?>(nil)
        decoder.setOutputHandler { frame in
            let buffer = frame.pixelBuffer
            let observed = Observed(
                pixelFormat: CVPixelBufferGetPixelFormatType(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                matrix: CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String,
                chromaLocation: CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil)
                    as? String)
            first.withValue { if $0 == nil { $0 = observed } }
        }
        for _ in 0..<8 {
            guard let sample = demuxer.nextVideoSample() else { break }
            decoder.decode(sampleBuffer: sample)
        }
        decoder.drain()

        let observed = try #require(first.value)
        #expect(observed.pixelFormat == testCase.pixelFormat)
        #expect(observed.width == demuxer.width)
        #expect(observed.height == demuxer.height)
        #expect(observed.matrix == testCase.matrix)
        // libswscale centres the chroma it resamples, whatever the source's siting.
        #expect(observed.chromaLocation == kCVImageBufferChromaLocation_Center as String)
    }

    /// Pure red has a distinct luma per matrix (limited range): BT.709 ≈ 63, BT.601 ≈ 81. The converter must
    /// encode with the matrix it tags the frame with, which follows the demuxer's SD / HD default.
    @Test(
        "RGB converts with the BT.709 matrix at HD and BT.601 at SD, and reports it",
        arguments: [
            (1280, 720, 63, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String),
            (640, 360, 81, kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String),
        ])
    func rgbMatrixFollowsResolution(width: Int32, height: Int32, expectedLuma: Int, matrix: String) throws {
        var source: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&source) }
        let frame = try #require(source)
        frame.pointee.format = AV_PIX_FMT_RGB24.rawValue
        frame.pointee.width = width
        frame.pointee.height = height
        #expect(av_frame_get_buffer(frame, 0) >= 0)
        let base = try #require(frame.pointee.data.0)
        let stride = Int(frame.pointee.linesize.0)
        for row in 0..<Int(height) {
            for x in 0..<Int(width) {
                base[row * stride + x * 3] = 255
                base[row * stride + x * 3 + 1] = 0
                base[row * stride + x * 3 + 2] = 0
            }
        }

        let output = try #require(FrameFormatNormalizer().convert(frame))
        var converted: UnsafeMutablePointer<AVFrame>? = output.frame
        defer { av_frame_free(&converted) }

        #expect(output.frame.pointee.format == AV_PIX_FMT_YUV420P.rawValue)
        #expect(output.frame.pointee.color_range == AVCOL_RANGE_MPEG)
        #expect(output.yCbCrMatrix as String? == matrix)
        let luma = Int(try #require(output.frame.pointee.data.0)[0])
        #expect(abs(luma - expectedLuma) <= 1, "Red encoded to Y=\(luma), expected ≈\(expectedLuma)")
    }
}
