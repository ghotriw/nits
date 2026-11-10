import CFFmpeg
import CoreVideo
import Foundation
import Testing

@testable import NitsCore

/// What a stream's colour tags make of it: the matrix an untagged one gets, wide-gamut SDR staying SDR, and the static
/// peak a title's metadata sets.
@Suite("Wide-gamut colorimetry")
struct WideGamutColorimetryTests {
    /// The colorimetry of codec parameters with these primaries and transfer and no matrix, at `width` × `height`.
    private static func colorimetry(
        primaries: AVColorPrimaries, transfer: AVColorTransferCharacteristic, width: Int = 3840, height: Int = 2160
    ) throws -> StreamColorimetry {
        let parameters = try #require(avcodec_parameters_alloc())
        var freed: UnsafeMutablePointer<AVCodecParameters>? = parameters
        defer { avcodec_parameters_free(&freed) }
        parameters.pointee.color_primaries = primaries
        parameters.pointee.color_trc = transfer
        parameters.pointee.color_space = AVCOL_SPC_UNSPECIFIED
        return StreamColorimetry(codecParameters: UnsafePointer(parameters), width: width, height: height)
    }

    @Test("An untagged matrix follows the primaries: BT.2020 for an HDR10 encode tagged without one")
    func untaggedMatrixFollowsPrimaries() throws {
        let hdr10 = try Self.colorimetry(primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_SMPTE2084)
        #expect(hdr10.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_2020)
        let ntsc = try Self.colorimetry(primaries: AVCOL_PRI_SMPTE170M, transfer: AVCOL_TRC_BT709)
        #expect(ntsc.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let hd = try Self.colorimetry(primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709)
        #expect(hd.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let untaggedSD = try Self.colorimetry(
            primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_UNSPECIFIED, width: 720, height: 576)
        #expect(untaggedSD.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
    }

    /// `FrameFormatNormalizer` converts RGB to Y'CbCr by resolution alone; the matrix the shader decodes with must match.
    @Test("RGB keeps the matrix its conversion uses, whatever its primaries")
    func rgbMatrixFollowsResolution() throws {
        let parameters = try #require(avcodec_parameters_alloc())
        var freed: UnsafeMutablePointer<AVCodecParameters>? = parameters
        defer { avcodec_parameters_free(&freed) }
        parameters.pointee.color_primaries = AVCOL_PRI_BT2020
        parameters.pointee.color_trc = AVCOL_TRC_BT709
        parameters.pointee.color_space = AVCOL_SPC_RGB
        let hd = StreamColorimetry(codecParameters: UnsafePointer(parameters), width: 1920, height: 1080)
        #expect(hd.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let sd = StreamColorimetry(codecParameters: UnsafePointer(parameters), width: 720, height: 480)
        #expect(sd.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)

        // RGB by its pixel format alone, the matrix unsignalled: the normalizer still converts it by resolution.
        parameters.pointee.color_space = AVCOL_SPC_UNSPECIFIED
        parameters.pointee.format = AV_PIX_FMT_GBRP10LE.rawValue
        let untagged = StreamColorimetry(codecParameters: UnsafePointer(parameters), width: 1920, height: 1080)
        #expect(untagged.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        #expect(StreamColorimetry.isRGB(format: AV_PIX_FMT_GBRP10LE.rawValue))
        #expect(!StreamColorimetry.isRGB(format: AV_PIX_FMT_YUV420P10LE.rawValue))
    }

    @Test("ICtCp outside Dolby Vision Profile 5 decodes with BT.2020's coefficients, not BT.709's")
    func ictcpTakesBT2020() {
        let bt2020 = ShaderColorimetry.yCbCrToRGB(kCVImageBufferYCbCrMatrix_ITU_R_2020)
        #expect(ShaderColorimetry.yCbCrToRGB("ITU_R_2100_ICtCp" as CFString) == bt2020)
    }

    @Test("10-bit BT.2020 with an SDR transfer is SDR")
    func wideGamutSDRIsNotHDR() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hevc10BitWideGamutSDR) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        #expect(demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020)
        #expect(demuxer.bitDepth == 10)
        #expect(!demuxer.isHDR)
    }

    /// The mastering display only stands in for a missing MaxCLL: a MaxCLL of 1000 (once the "no peak" default) read
    /// before a 4000-nit mastering display stays the peak.
    @Test("A MaxCLL of 1000 is kept when a 4000-nit mastering display follows it")
    func maxCLLOf1000IsKept() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hevc10BitWideGamutSDR) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        #expect(!demuxer.hasStaticPeak)
        // Prefix SEI NAL header, then CLL (144: MaxCLL 1000, MaxFALL 400) and mastering display (137: max 4000 nits,
        // min 0.005: 00 00 00 32, escaped as 00 00 03 00 32 and counted without the 03), then the RBSP trailing bits.
        let sei: [UInt8] =
            [0x4E, 0x01]
            + [144, 4, 0x03, 0xE8, 0x01, 0x90]
            + [137, 24, 0x21, 0x34, 0x9B, 0xAA, 0x19, 0x96, 0x08, 0xFC, 0x8A, 0x48, 0x39, 0x08, 0x3D, 0x13, 0x40, 0x42]
            + [0x02, 0x62, 0x5A, 0x00, 0x00, 0x03, 0x00, 0x00, 0x32]
            + [0x80]
        var masteringDisplay: Data?
        var contentLightLevel: Data?
        demuxer.applyHDRSEI(
            naluData: Data(sei), masteringDisplay: &masteringDisplay, contentLightLevel: &contentLightLevel)
        #expect(masteringDisplay != nil && contentLightLevel != nil)
        #expect(demuxer.maxPeakNits == 1000)
    }
}
