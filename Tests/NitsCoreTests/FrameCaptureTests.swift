import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import Testing

@testable import NitsCore

@Suite("Frame Capture Size")
struct FrameCaptureSizeTests {
    private let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    @Test func wholeFrameWithoutLayoutKeepsSourcePixels() {
        let size = FrameCapture.outputSize(bufferWidth: 1920, bufferHeight: 1080, sourceRect: full, displaySize: .zero)
        #expect(size == (1920, 1080))
    }

    @Test func anamorphicFrameIsStretchedToItsDisplayShape() {
        // DVD PAL 16:9 shown at 1024 × 576.
        let size = FrameCapture.outputSize(
            bufferWidth: 720, bufferHeight: 576, sourceRect: full, displaySize: CGSize(width: 2048, height: 1152))
        #expect(size == (1024, 576))
    }

    @Test func cropKeepsSourceRows() {
        // 2:1 crop of a 16:9 frame: the middle 960 rows, shown twice as wide.
        let rows = 960.0 / 1080.0
        let size = FrameCapture.outputSize(
            bufferWidth: 1920, bufferHeight: 1080, sourceRect: CGRect(x: 0, y: (1 - rows) / 2, width: 1, height: rows),
            displaySize: CGSize(width: 2000, height: 1000))
        #expect(size == (1920, 960))
    }
}

@Suite("Frame Capture Reshaping")
@MainActor
struct FrameCaptureReshapingTests {
    private static let curves = DolbyVisionFrameMetadata(
        sceneRefresh: false, l1: nil, l2Trims: [],
        reshapingCurvesState: .curves(
            Array(
                repeating: DolbyVisionFrameMetadata.ReshapingCurve(
                    pivots: [0.0, 1.0], polyCoeffs: [SIMD3<Float>(0.1, 0.8, 0.0)]),
                count: 3)))

    @Test("Under the system path, a Profile 5 frame without RPU is still composed with the last RPU's reshaping")
    func frameWithoutRPUKeepsLastReshaping() throws {
        let toneMapping = ToneMapController(renderer: nil)
        toneMapping.frameState.withLock { $0.reshaper.reset(isProfile5: true) }
        toneMapping.trackReshaping(doviMetadata: Self.curves)

        let withoutRPU = try #require(toneMapping.stillReshaping(doviMetadata: nil))
        #expect(withoutRPU.isActive == 1)
        let ownRPU = try #require(
            toneMapping.stillReshaping(
                doviMetadata: DolbyVisionFrameMetadata(sceneRefresh: false, l1: nil, l2Trims: [])))
        #expect(ownRPU.isActive == 0)
    }

    @Test func otherMediaHaveNoReshaping() {
        let toneMapping = ToneMapController(renderer: nil)
        toneMapping.trackReshaping(doviMetadata: Self.curves)
        #expect(toneMapping.stillReshaping(doviMetadata: Self.curves) == nil)
    }
}

@Suite("Frame Capture Encoding", .hostDependent)
struct FrameCaptureEncodingTests {
    /// A flat 4:2:0 frame (10-bit P010 or 8-bit NV12, video range) with the given luma code and colorimetry.
    private static func flatFrame(tenBit: Bool, transfer: CFString, primaries: CFString, matrix: CFString)
        -> CVPixelBuffer?
    {
        let format =
            tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var buffer: CVPixelBuffer?
        let attributes =
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, format, attributes, &buffer) == kCVReturnSuccess,
            let buffer
        else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // Mid grey: luma 512 / 128, neutral chroma; 10-bit codes sit in the top bits.
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            if tenBit {
                let samples = base.assumingMemoryBound(to: UInt16.self)
                for index in 0..<(bytes / 2) { samples[index] = 512 << 6 }
            } else {
                memset(base, 128, bytes)
            }
        }
        return buffer
    }

    private let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    @Test("Packed 10-bit texels unpack to 16-bit R, G, B in that order")
    func unpacksChannelsInOrder() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgr10a2Unorm, width: 1, height: 1, mipmapped: false)
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var texel: UInt32 = (3 << 30) | (1023 << 20) | (512 << 10) | 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &texel, bytesPerRow: 4)

        let image = try #require(MetalVideoRenderer.displayP3Image(of: texture))
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(image.bitsPerComponent == 16)
        let data = try #require(image.dataProvider?.data as Data?)
        let rgb = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        #expect(rgb == [65535, 32800, 0])
    }

    @Test("Under Metal tone mapping, the still is a neutral 16-bit P3 PNG of the requested size")
    func metalStillIsP3PNG() throws {
        guard let renderer = MetalVideoRenderer(),
            let frame = Self.flatFrame(
                tenBit: true, transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                primaries: kCVImageBufferColorPrimaries_ITU_R_2020, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        else { return }
        let still = try #require(
            FrameCapture.capture(
                frame, pts: 1, mode: .metalToneMap, renderer: renderer, sourceRect: full,
                displaySize: CGSize(width: 128, height: 64)))
        #expect(still.contentType == .png)
        #expect(!still.isHDR)
        let source = try #require(CGImageSourceCreateWithData(still.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64 && image.height == 32)
        #expect(image.bitsPerComponent == 16)
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
    }

    /// The RGB of the middle pixel of `data`'s image, in linear extended sRGB.
    private static func centerPixel(of data: Data) throws -> [Float] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var pixel = [Float](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 32, bytesPerRow: 16, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2), width: CGFloat(image.width),
                height: CGFloat(image.height)))
        return Array(pixel.prefix(3))
    }

    @Test("Under the system path, Dolby Vision Profile 5 is composed from IPT, not read as YCbCr")
    func systemProfile5StillIsComposed() throws {
        // Neutral IPT (P = T = 0) must come out grey. The VUI says BT.709, as Profile 5 streams often do: read by Core
        // Image the frame would be an SDR PNG, so an HDR HEIC shows the shader composed it.
        guard let renderer = MetalVideoRenderer(),
            let frame = Self.flatFrame(
                tenBit: true, transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        else { return }
        let still = try #require(
            FrameCapture.capture(
                frame, pts: 1, mode: .system, renderer: renderer, sourceRect: full, displaySize: .zero,
                dolbyVisionReshaping: ToneMapUniforms.DolbyVisionReshaping()))
        #expect(still.contentType == .heic)
        #expect(still.isHDR)
        let rgb = try Self.centerPixel(of: still.data)
        #expect(rgb.allSatisfy { $0 > 0.01 }, "\(rgb)")
        #expect(rgb.max()! - rgb.min()! < 0.01 * rgb.max()!, "not neutral: \(rgb)")
    }

    @Test("Without the Metal renderer, Dolby Vision Profile 5 gives no still rather than one read as YCbCr")
    func profile5WithoutRendererGivesNoStill() {
        guard
            let frame = Self.flatFrame(
                tenBit: true, transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        else { return }
        #expect(
            FrameCapture.capture(
                frame, pts: 1, mode: .system, renderer: nil, sourceRect: full, displaySize: .zero,
                dolbyVisionReshaping: ToneMapUniforms.DolbyVisionReshaping()) == nil)
    }

    @Test("Under the system path, a PQ frame becomes a 10-bit HDR HEIC")
    func systemPQStillIsHEIC() throws {
        guard
            let frame = Self.flatFrame(
                tenBit: true, transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                primaries: kCVImageBufferColorPrimaries_ITU_R_2020, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        else { return }
        let still = try #require(
            FrameCapture.capture(
                frame, pts: 1, mode: .system, renderer: nil, sourceRect: full, displaySize: .zero))
        #expect(still.contentType == .heic)
        #expect(still.isHDR)
        let source = try #require(CGImageSourceCreateWithData(still.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64 && image.height == 32)
        #expect(image.colorSpace.map(CGColorSpaceUsesITUR_2100TF) == true)
    }

    @Test("Under the system path, an SDR frame becomes a PNG cropped as shown")
    func systemSDRStillIsCroppedPNG() throws {
        guard
            let frame = Self.flatFrame(
                tenBit: false, transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        else { return }
        let still = try #require(
            FrameCapture.capture(
                frame, pts: 1, mode: .system, renderer: nil,
                sourceRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                displaySize: CGSize(width: 64, height: 32)))
        #expect(still.contentType == .png)
        #expect(!still.isHDR)
        let source = try #require(CGImageSourceCreateWithData(still.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 32 && image.height == 16)
    }
}
