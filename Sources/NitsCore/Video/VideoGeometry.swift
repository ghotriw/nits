import CoreGraphics
import Foundation

/// How the picture is sized to the view.
public enum VideoScaling: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Whole picture inside the view, bars where the aspect ratios differ.
    case fit
    /// View covered, the picture's edges cut where the aspect ratios differ.
    case fill
    /// View covered, aspect ratio ignored.
    case stretch
    /// One video pixel per backing pixel; a picture larger than the view is fit.
    case original

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        case .original: "Original Size"
        }
    }

    /// The next mode, for cycling through them from a key.
    public var next: VideoScaling {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// How the decoded picture is placed in the view: aspect ratio, crop, scaling, zoom and pan. Presentation only, so
/// changing it never touches decoding or timing.
public struct VideoGeometrySettings: Sendable, Equatable, Codable {
    /// Display aspect ratio forced on the whole frame; `nil` uses the stream's (coded size and SAR).
    public var aspectRatio: RationalAspectRatio?
    /// Centered crop to this display aspect ratio, applied after `aspectRatio`; `nil` shows the whole frame.
    public var crop: RationalAspectRatio?
    public var scaling: VideoScaling
    /// Multiplies the scaled size; see `zoomRange`.
    public var zoom: Double
    /// Position of a picture larger than the view, per axis from -1 (its leading / top edge at the view's) to 1
    /// (trailing / bottom edge at the view's); 0 centers it. No effect on an axis the picture fits.
    public var pan: CGPoint

    public static let zoomRange: ClosedRange<Double> = 0.5...4.0
    /// Four zoom steps per doubling.
    public static let zoomStepFactor = pow(2.0, 0.25)

    public init(
        aspectRatio: RationalAspectRatio? = nil,
        crop: RationalAspectRatio? = nil,
        scaling: VideoScaling = .fit,
        zoom: Double = 1.0,
        pan: CGPoint = .zero
    ) {
        self.aspectRatio = aspectRatio
        self.crop = crop
        self.scaling = scaling
        self.zoom = zoom
        self.pan = pan
    }

    /// Whether the picture is laid out as the stream's plain aspect fit, the layout without any override.
    public var isSourceAspectFit: Bool {
        aspectRatio == nil && crop == nil && scaling == .fit && effectiveZoom == 1.0
    }

    /// `zoom` as applied: 1× when it isn't a finite positive number, otherwise clamped to `zoomRange`.
    public var effectiveZoom: Double {
        guard zoom.isFinite, zoom > 0 else { return 1.0 }
        return min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// These settings with the zoom changed by `steps` of `zoomStepFactor`, clamped to `zoomRange`; lands exactly on
    /// 1× when it passes it.
    public func zoomed(bySteps steps: Int) -> VideoGeometrySettings {
        var settings = self
        let exponent = (log(effectiveZoom) / log(Self.zoomStepFactor)).rounded() + Double(steps)
        let zoom = pow(Self.zoomStepFactor, exponent)
        settings.zoom = exponent == 0 ? 1.0 : min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        return settings
    }
}

extension RationalAspectRatio {
    /// Aspect ratios offered for overriding and cropping (the VLC / IINA lists).
    public static let displayPresets: [RationalAspectRatio] = [
        RationalAspectRatio(numerator: 4, denominator: 3),
        RationalAspectRatio(numerator: 16, denominator: 9),
        RationalAspectRatio(numerator: 16, denominator: 10),
        RationalAspectRatio(numerator: 185, denominator: 100),
        RationalAspectRatio(numerator: 221, denominator: 100),
        RationalAspectRatio(numerator: 235, denominator: 100),
        RationalAspectRatio(numerator: 239, denominator: 100),
        RationalAspectRatio(numerator: 5, denominator: 4),
        RationalAspectRatio(numerator: 1, denominator: 1),
    ]

    /// Whether both terms are positive, so it describes a real ratio.
    public var isValid: Bool { numerator > 0 && denominator > 0 }

    /// "16:9", or "2.35:1" for hundredths.
    public var displayName: String {
        guard denominator == 100 else { return "\(numerator):\(denominator)" }
        return String(format: "%.2f:1", multiplier)
    }

    /// The preset after `current` (`nil` is the stream's own ratio, first in the cycle), for cycling from a key.
    public static func nextDisplayPreset(after current: RationalAspectRatio?) -> RationalAspectRatio? {
        guard let current, let index = displayPresets.firstIndex(of: current) else { return displayPresets.first }
        return index + 1 < displayPresets.count ? displayPresets[index + 1] : nil
    }
}

/// Where the picture lands in a view, in the view's coordinates with the origin at the top left.
public struct VideoLayout: Equatable, Sendable {
    /// The whole decoded frame, before cropping; may extend past the view.
    public var frameRect: CGRect
    /// The cropped picture, zoomed and panned; may extend past the view.
    public var contentRect: CGRect
    /// `contentRect` clipped to the view: what is actually covered.
    public var visibleRect: CGRect
    /// The part of the decoded frame shown in `visibleRect`, normalized (0...1, origin at the top left).
    public var sourceRect: CGRect
    /// How far `contentRect` may move from the center on each axis, in points; pan ±1 moves it that far.
    public var panLimit: CGSize

    /// The normalized part of the decoded frame that `rect` (in the same coordinates as `frameRect`) shows.
    public func sourceRect(for rect: CGRect) -> CGRect {
        guard frameRect.width > 0, frameRect.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(
            x: (rect.minX - frameRect.minX) / frameRect.width,
            y: (rect.minY - frameRect.minY) / frameRect.height,
            width: rect.width / frameRect.width,
            height: rect.height / frameRect.height
        )
    }
}

/// Lays out the picture in a view (like mpv's `mp_get_src_dst_rects`). The single source of geometry for the display
/// layer, the Metal layer and the overlays drawn over the video.
public enum VideoGeometry {
    /// Display aspect ratio of the stream with the settings' aspect override and crop applied.
    public static func contentAspectRatio(
        videoWidth: Int, videoHeight: Int, sampleAspectRatio: RationalAspectRatio,
        settings: VideoGeometrySettings
    ) -> Double {
        let frameAspect = frameAspectRatio(
            videoWidth: videoWidth, videoHeight: videoHeight, sampleAspectRatio: sampleAspectRatio, settings: settings)
        let crop = cropRect(frameAspect: frameAspect, crop: settings.crop)
        return frameAspect * crop.width / crop.height
    }

    /// - Parameter backingScale: Backing pixels per point, for `.original`.
    public static func layout(
        viewSize: CGSize,
        videoWidth: Int,
        videoHeight: Int,
        sampleAspectRatio: RationalAspectRatio,
        settings: VideoGeometrySettings,
        backingScale: CGFloat = 1.0
    ) -> VideoLayout {
        let bounds = CGRect(origin: .zero, size: viewSize)
        guard viewSize.width.isFinite, viewSize.height.isFinite, viewSize.width > 0, viewSize.height > 0 else {
            return VideoLayout(
                frameRect: bounds, contentRect: bounds, visibleRect: bounds,
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), panLimit: .zero)
        }

        let frameAspect = frameAspectRatio(
            videoWidth: videoWidth, videoHeight: videoHeight, sampleAspectRatio: sampleAspectRatio, settings: settings)
        let crop = cropRect(frameAspect: frameAspect, crop: settings.crop)
        let contentAspect = frameAspect * crop.width / crop.height

        var size: CGSize
        switch settings.scaling {
        case .fit:
            size = fitSize(aspect: contentAspect, in: viewSize)
        case .fill:
            size = fillSize(aspect: contentAspect, in: viewSize)
        case .stretch:
            size = viewSize
        case .original:
            let height = Double(videoHeight) * crop.height / Double(max(backingScale, 0.01))
            size = CGSize(width: height * contentAspect, height: height)
            if videoHeight <= 0 || size.width > viewSize.width || size.height > viewSize.height {
                size = fitSize(aspect: contentAspect, in: viewSize)
            }
        }
        let zoom = settings.effectiveZoom
        size = CGSize(width: size.width * zoom, height: size.height * zoom)

        let panLimit = CGSize(
            width: max(0, (size.width - viewSize.width) / 2), height: max(0, (size.height - viewSize.height) / 2))
        let panX = settings.pan.x.isFinite ? min(max(settings.pan.x, -1), 1) : 0
        let panY = settings.pan.y.isFinite ? min(max(settings.pan.y, -1), 1) : 0
        let contentRect = CGRect(
            x: (viewSize.width - size.width) / 2 - panX * panLimit.width,
            y: (viewSize.height - size.height) / 2 - panY * panLimit.height,
            width: size.width,
            height: size.height
        )
        let frameSize = CGSize(width: size.width / crop.width, height: size.height / crop.height)
        let frameRect = CGRect(
            x: contentRect.minX - crop.minX * frameSize.width,
            y: contentRect.minY - crop.minY * frameSize.height,
            width: frameSize.width,
            height: frameSize.height
        )
        var visibleRect = contentRect.intersection(bounds)
        if visibleRect.isNull { visibleRect = .zero }

        var layout = VideoLayout(
            frameRect: frameRect, contentRect: contentRect, visibleRect: visibleRect, sourceRect: .zero,
            panLimit: panLimit)
        layout.sourceRect = layout.sourceRect(for: visibleRect)
        return layout
    }

    /// The pan that moves the picture by `translation` points from `settings.pan` (positive: right / down).
    public static func pan(
        _ settings: VideoGeometrySettings, movedBy translation: CGSize, in layout: VideoLayout
    ) -> CGPoint {
        var pan = settings.pan
        if layout.panLimit.width > 0 { pan.x = min(max(pan.x - translation.width / layout.panLimit.width, -1), 1) }
        if layout.panLimit.height > 0 {
            pan.y = min(max(pan.y - translation.height / layout.panLimit.height, -1), 1)
        }
        return pan
    }

    private static func frameAspectRatio(
        videoWidth: Int, videoHeight: Int, sampleAspectRatio: RationalAspectRatio,
        settings: VideoGeometrySettings
    ) -> Double {
        if let override = settings.aspectRatio, override.isValid { return override.multiplier }
        return RationalAspectRatio.computeDisplayAspectRatio(
            width: videoWidth, height: videoHeight, sar: sampleAspectRatio)
    }

    /// Normalized centered part of a frame of `frameAspect` with the display aspect ratio `crop`.
    private static func cropRect(frameAspect: Double, crop: RationalAspectRatio?) -> CGRect {
        guard let crop, crop.isValid, frameAspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let ratio = crop.multiplier
        if ratio > frameAspect {
            let height = frameAspect / ratio
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = ratio / frameAspect
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }

    private static func fitSize(aspect: Double, in size: CGSize) -> CGSize {
        if size.width / size.height > aspect {
            return CGSize(width: size.height * aspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspect)
    }

    private static func fillSize(aspect: Double, in size: CGSize) -> CGSize {
        if size.width / size.height > aspect {
            return CGSize(width: size.width, height: size.width / aspect)
        }
        return CGSize(width: size.height * aspect, height: size.height)
    }
}
