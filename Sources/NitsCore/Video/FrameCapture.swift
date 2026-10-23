import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A still of the frame on screen, encoded (`PlayerEngine.captureFrame()`).
public struct CapturedFrame: Sendable {
    public let data: Data
    /// PNG, or HEIC for an HDR picture.
    public let contentType: UTType
    /// Presentation time of the frame, in seconds.
    public let pts: Double
    /// Whether `data` keeps the frame's HDR (PQ / HLG) rather than an SDR picture.
    public let isHDR: Bool

    public init(data: Data, contentType: UTType, pts: Double, isHDR: Bool) {
        self.data = data
        self.contentType = contentType
        self.pts = pts
        self.isHDR = isHDR
    }
}

/// Encodes a frame as the render mode shows it, at the source's resolution with the on-screen geometry (crop,
/// aspect ratio, zoom and pan: the renderer's `sourceRect`, stretched to the shape of the picture in the view).
///
/// - `.metalToneMap`: the frame through `MetalVideoRenderer` with the uniforms on screen, a 16-bit Display P3 PNG
///   holding the very values the layer shows.
/// - `.system`: the frame as the display layer is given it, decoded by Core Image from the buffer's colorimetry
///   attachments, as the layer reads them. HDR goes to a 10-bit HEIC in its own transfer (PQ / HLG), which the
///   viewer maps to its display as the layer does; SDR to a PNG in the frame's colour space. Dolby Vision Profile 5
///   is composed by the shader from its RPU instead (`dolbyVisionStill`), to the same HEIC.
enum FrameCapture {
    /// Pixel size of a still covering `sourceRect` (normalized, origin top left) of a `bufferWidth` × `bufferHeight`
    /// frame: its source rows, and the width the picture's on-screen shape (`displaySize`) gives them. Without a
    /// shape (no layout yet), the source columns.
    static func outputSize(
        bufferWidth: Int, bufferHeight: Int, sourceRect: CGRect, displaySize: CGSize
    ) -> (width: Int, height: Int) {
        let height = max(1, Int((sourceRect.height * Double(bufferHeight)).rounded()))
        guard displaySize.width > 0, displaySize.height > 0 else {
            return (max(1, Int((sourceRect.width * Double(bufferWidth)).rounded())), height)
        }
        return (max(1, Int((Double(height) * displaySize.width / displaySize.height).rounded())), height)
    }

    /// - Parameters:
    ///   - uniforms: Under `.metalToneMap`, those the frame was drawn with (`MetalVideoRenderer.lastDrawnFrame`); the
    ///     renderer's current ones without.
    ///   - dolbyVisionReshaping: The Profile 5 reshaping the frame is shown with (its RPU's, or the last RPU's for a
    ///     frame without one), when the media is Dolby Vision Profile 5; nil for other media.
    static func capture(
        _ pixelBuffer: CVPixelBuffer, pts: Double, mode: RenderMode, renderer: MetalVideoRenderer?,
        sourceRect: CGRect, displaySize: CGSize, uniforms: ToneMapUniforms? = nil,
        dolbyVisionReshaping: ToneMapUniforms.DolbyVisionReshaping? = nil
    ) -> CapturedFrame? {
        let size = outputSize(
            bufferWidth: CVPixelBufferGetWidth(pixelBuffer), bufferHeight: CVPixelBufferGetHeight(pixelBuffer),
            sourceRect: sourceRect, displaySize: displaySize)
        if mode == .metalToneMap, let renderer {
            guard
                let image = renderer.renderStill(
                    pixelBuffer: pixelBuffer, uniforms: uniforms ?? renderer.uniforms, sourceRect: sourceRect,
                    width: size.width, height: size.height),
                let data = pngData(of: image)
            else { return nil }
            return CapturedFrame(data: data, contentType: .png, pts: pts, isHDR: false)
        }
        if let dolbyVisionReshaping {
            // Core Image would read the IPT as YCbCr: no still rather than a picture in the wrong colours.
            guard let renderer else { return nil }
            return dolbyVisionStill(
                pixelBuffer, pts: pts, reshaping: dolbyVisionReshaping, renderer: renderer, sourceRect: sourceRect,
                size: size)
        }
        return systemStill(pixelBuffer, pts: pts, sourceRect: sourceRect, size: size)
    }

    /// Profile 5 is IPT-PQ-c2, which only the RPU's reshaping and matrices turn into a picture: the display layer
    /// composes it itself, while Core Image would read it as YCbCr (purple). The shader composes it the same way, to
    /// the BT.2100 PQ signal.
    private static func dolbyVisionStill(
        _ pixelBuffer: CVPixelBuffer, pts: Double, reshaping: ToneMapUniforms.DolbyVisionReshaping,
        renderer: MetalVideoRenderer, sourceRect: CGRect, size: (width: Int, height: Int)
    ) -> CapturedFrame? {
        guard
            let image = renderer.renderDolbyVisionSignal(
                pixelBuffer: pixelBuffer, sourceRect: sourceRect, width: size.width, height: size.height,
                reshaping: reshaping),
            let colorSpace = image.colorSpace,
            let data = try? CIContext(options: [.cacheIntermediates: false])
                .heif10Representation(of: CIImage(cgImage: image), colorSpace: colorSpace, options: [:])
        else { return nil }
        return CapturedFrame(data: data, contentType: .heic, pts: pts, isHDR: true)
    }

    private static func systemStill(
        _ pixelBuffer: CVPixelBuffer, pts: Double, sourceRect: CGRect, size: (width: Int, height: Int)
    ) -> CapturedFrame? {
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = frame.extent
        // Core Image puts the origin at the bottom left.
        let crop = CGRect(
            x: extent.minX + sourceRect.minX * extent.width,
            y: extent.minY + (1 - sourceRect.maxY) * extent.height,
            width: sourceRect.width * extent.width,
            height: sourceRect.height * extent.height)
        guard crop.width > 0, crop.height > 0 else { return nil }
        let output = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let image = frame.cropped(to: crop).clampedToExtent()
            .transformed(
                by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                    .concatenating(CGAffineTransform(scaleX: output.width / crop.width, y: output.height / crop.height))
            )
            .cropped(to: output)

        let context = CIContext(options: [.cacheIntermediates: false])
        if let hdrSpace = hdrColorSpace(of: pixelBuffer) {
            guard let data = try? context.heif10Representation(of: image, colorSpace: hdrSpace, options: [:])
            else { return nil }
            return CapturedFrame(data: data, contentType: .heic, pts: pts, isHDR: true)
        }
        let format: CIFormat = bitDepth(of: pixelBuffer) > 8 ? .RGBA16 : .RGBA8
        guard let colorSpace = frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let data = context.pngRepresentation(of: image, format: format, colorSpace: colorSpace)
        else { return nil }
        return CapturedFrame(data: data, contentType: .png, pts: pts, isHDR: false)
    }

    /// The BT.2100 space of a PQ or HLG frame, nil for SDR.
    private static func hdrColorSpace(of pixelBuffer: CVPixelBuffer) -> CGColorSpace? {
        let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
        if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        }
        if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        }
        return nil
    }

    private static func bitDepth(of pixelBuffer: CVPixelBuffer) -> Int {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA:
            return 8
        default:
            return 10
        }
    }

    static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
