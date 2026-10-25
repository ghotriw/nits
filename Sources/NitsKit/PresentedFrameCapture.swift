import AppKit
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A still of the picture as the screen shows it, for `.system` HDR: the display layer maps the frame to the display
/// itself (Apple's video tone mapping, Dolby Vision metadata, the screen's EDR headroom), which a file of the frame's own
/// signal can't reproduce, as a viewer maps that its own way. ScreenCaptureKit captures the player window as composed,
/// HDR included, at the screen's pixels, which is then cropped to the picture.
@MainActor
enum PresentedFrameCapture {
    enum CaptureError: Error {
        /// ScreenCaptureKit doesn't list the window (off screen, or minimized).
        case windowNotShared
        case emptyPicture
        case encodingFailed
    }

    /// `videoRect` of `window` (in its base coordinates, points) as the screen shows it: a HEIC with an ISO gain map,
    /// an SDR base and the HDR the screen showed for displays with headroom. Asks for the Screen Recording permission the
    /// first time.
    static func capture(window: NSWindow, videoRect: CGRect) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError.windowNotShared
        }
        let filter = SCContentFilter(desktopIndependentWindow: shared)
        let windowSize = filter.contentRect.size
        // The window's backing scale: the filter's `pointPixelScale` came out 1 on a Retina XDR, halving the still.
        let pixelsPerPoint = window.backingScaleFactor
        let configuration = SCStreamConfiguration(preset: .captureHDRScreenshotLocalDisplay)
        configuration.captureResolution = .best
        configuration.width = Int((windowSize.width * pixelsPerPoint).rounded())
        configuration.height = Int((windowSize.height * pixelsPerPoint).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        // Window base coordinates start at the bottom left, the image at the top left.
        let scale = CGFloat(image.width) / windowSize.width
        let crop = CGRect(
            x: videoRect.minX * scale, y: (windowSize.height - videoRect.maxY) * scale,
            width: videoRect.width * scale, height: videoRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isEmpty, let picture = image.cropping(to: crop) else { throw CaptureError.emptyPicture }
        let headroom = Float(max(window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1, 1))
        return try encode(picture, headroom: headroom)
    }

    /// The picture in linear extended Display P3 (1.0 = SDR white), with the screen's headroom, as HEIC with a gain map.
    private static func encode(_ picture: CGImage, headroom: Float) throws -> Data {
        guard let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
            let linear = CIContext().createCGImage(
                CIImage(cgImage: picture), from: CGRect(x: 0, y: 0, width: picture.width, height: picture.height),
                format: .RGBAh, colorSpace: linearP3),
            let hdr = CGImageCreateCopyWithContentHeadroom(headroom, linear)
        else { throw CaptureError.encodingFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)
        else {
            throw CaptureError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination, hdr, [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodingFailed }
        return data as Data
    }
}
