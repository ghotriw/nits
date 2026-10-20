import NitsCore
import SwiftUI

public struct SubtitleOverlayView: View {
    public let cues: [SubtitleCue]
    public let images: [SubtitleImageCue]
    public let fontSize: Double
    public let textColor: Color
    public let backgroundColor: Color
    public let backgroundOpacity: Double
    public let fontName: String
    public let fontWeight: String
    public let videoWidth: Int
    public let videoHeight: Int
    public let sampleAspectRatio: RationalAspectRatio
    public let geometry: VideoGeometrySettings
    /// Size of picture subtitles against the stream's (`PlayerEngine.subtitleScale`); text has `fontSize`.
    public let imageScale: Double
    /// How far bottom subtitles are raised, as a fraction of the visible picture's height.
    public let raise: Double
    /// Called with the size in pixels of the picture area subtitles are drawn on, when it changes: what a renderer of
    /// styled subtitles needs to draw at.
    public let onRenderSizeChange: ((CGSize) -> Void)?
    @Environment(\.displayScale) private var displayScale

    public init(
        cues: [SubtitleCue],
        images: [SubtitleImageCue] = [],
        fontSize: Double = 24.0,
        textColor: Color = .white,
        backgroundColor: Color = .black,
        backgroundOpacity: Double = 0.65,
        fontName: String = SubtitleSystemFont.rounded.rawValue,
        fontWeight: String = "Semibold",
        videoWidth: Int = 0,
        videoHeight: Int = 0,
        sampleAspectRatio: RationalAspectRatio = .square,
        geometry: VideoGeometrySettings = VideoGeometrySettings(),
        imageScale: Double = 1,
        raise: Double = 0,
        onRenderSizeChange: ((CGSize) -> Void)? = nil
    ) {
        self.cues = cues
        self.images = images
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.fontName = fontName
        self.fontWeight = fontWeight
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.sampleAspectRatio = sampleAspectRatio
        self.geometry = geometry
        self.imageScale = imageScale
        self.raise = raise
        self.onRenderSizeChange = onRenderSizeChange
    }

    public init(
        cue: SubtitleCue?,
        fontSize: Double = 24.0,
        textColor: Color = .white,
        backgroundColor: Color = .black,
        backgroundOpacity: Double = 0.65,
        fontName: String = SubtitleSystemFont.rounded.rawValue,
        fontWeight: String = "Semibold",
        videoWidth: Int = 0,
        videoHeight: Int = 0,
        sampleAspectRatio: RationalAspectRatio = .square,
        geometry: VideoGeometrySettings = VideoGeometrySettings()
    ) {
        self.init(
            cues: cue.map { [$0] } ?? [],
            fontSize: fontSize,
            textColor: textColor,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            fontName: fontName,
            fontWeight: fontWeight,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            sampleAspectRatio: sampleAspectRatio,
            geometry: geometry
        )
    }

    nonisolated static func pixelSize(of frame: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
    }

    public static let referenceViewportHeight: Double = 720.0
    public static let minFontSize: Double = 14.0
    public static let maxFontSize: Double = 72.0

    private var topCues: [SubtitleCue] {
        cues.filter { isTopAligned($0.alignment) }
    }

    private var centerCues: [SubtitleCue] {
        cues.filter { $0.alignment == .center }
    }

    private var bottomCues: [SubtitleCue] {
        cues.filter { !isTopAligned($0.alignment) && $0.alignment != .center }
    }

    public var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let layout = Self.computeVideoLayout(
                containerSize: containerSize,
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                sampleAspectRatio: sampleAspectRatio,
                geometry: geometry,
                backingScale: displayScale
            )
            let videoFrame = layout.visibleRect
            let scale = videoFrame.height > 0 ? (videoFrame.height / Self.referenceViewportHeight) : 1.0
            let effectiveFontSize = min(max(fontSize * scale, Self.minFontSize), Self.maxFontSize)
            let verticalEdgePadding = max(20.0, 40.0 * scale)
            let horizontalMargin = max(16.0, 32.0 * scale)

            ZStack {
                // Pictures come and go at once, without the text's fade: a typeset sign belongs to its shot, and a
                // libass frame fades by itself (`\fad`).
                imageLayer(in: layout)

                if !cues.isEmpty {
                    VStack(spacing: 8 * scale) {
                        // Top aligned cues
                        if !topCues.isEmpty {
                            VStack(spacing: 6 * scale) {
                                ForEach(topCues) { cue in
                                    cueRow(
                                        cue, effectiveFontSize: effectiveFontSize,
                                        horizontalMargin: horizontalMargin,
                                        scale: scale)
                                }
                            }
                            .padding(.top, verticalEdgePadding)
                        }

                        Spacer()

                        // Center aligned cues
                        if !centerCues.isEmpty {
                            VStack(spacing: 6 * scale) {
                                ForEach(centerCues) { cue in
                                    cueRow(
                                        cue, effectiveFontSize: effectiveFontSize,
                                        horizontalMargin: horizontalMargin,
                                        scale: scale)
                                }
                            }
                        }

                        Spacer()

                        // Bottom aligned cues
                        if !bottomCues.isEmpty {
                            VStack(spacing: 6 * scale) {
                                ForEach(bottomCues) { cue in
                                    cueRow(
                                        cue, effectiveFontSize: effectiveFontSize,
                                        horizontalMargin: horizontalMargin,
                                        scale: scale)
                                }
                            }
                            .padding(.bottom, verticalEdgePadding + raise * videoFrame.height)
                        }
                    }
                    .frame(width: videoFrame.width, height: videoFrame.height)
                    .position(x: videoFrame.midX, y: videoFrame.midY)
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: Self.pixelSize(of: videoFrame, scale: displayScale), initial: true) { _, size in
                onRenderSizeChange?(size)
            }
        }
    }

    /// Bitmap cues: each region placed on its canvas (`imageFrames`).
    @ViewBuilder
    private func imageLayer(in layout: VideoLayout) -> some View {
        ForEach(images) { cue in
            let canvas = CGSize(
                width: Double(cue.canvasWidth > 0 ? cue.canvasWidth : videoWidth),
                height: Double(cue.canvasHeight > 0 ? cue.canvasHeight : videoHeight))
            let frames = Self.imageFrames(of: cue, canvas: canvas, in: layout, scale: imageScale, raise: raise)
            ForEach(Array(cue.regions.enumerated()), id: \.offset) { index, region in
                let frame = frames[index]
                if !frame.isEmpty, let image = Self.cachedImage(of: region, cue: cue.id, index: index) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        // At most SDR white over HDR video on an XDR display, like the text, as mpv and VLC show them.
                        .allowedDynamicRange(.standard)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }

    /// Where a bitmap region lands in `videoFrame`. A canvas of the picture's proportions is stretched over it. One
    /// of other proportions (PGS keeps the 16:9 of the disc while a rip cut the black bars off) is fitted whole and
    /// centered with its scale kept equal on both axes, so the picture isn't distorted and nothing leaves the frame.
    nonisolated public static func imageFrame(
        of region: SubtitleImageCue.Region, canvas: CGSize, in videoFrame: CGRect
    ) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, videoFrame.width > 0, videoFrame.height > 0 else { return .zero }
        var scaleX = videoFrame.width / canvas.width
        var scaleY = videoFrame.height / canvas.height
        if abs(scaleX / scaleY - 1) > 0.01 {
            scaleX = min(scaleX, scaleY)
            scaleY = scaleX
        }
        let originX = videoFrame.minX + (videoFrame.width - canvas.width * scaleX) / 2
        let originY = videoFrame.minY + (videoFrame.height - canvas.height * scaleY) / 2
        return CGRect(
            x: originX + Double(region.x) * scaleX, y: originY + Double(region.y) * scaleY,
            width: Double(region.width) * scaleX, height: Double(region.height) * scaleY)
    }

    /// Where each region of `cue` lands. A libass frame covers the visible picture it was drawn for (libass scaled and
    /// raised its dialogue itself). A stream's canvas covers the whole decoded frame, so a crop or zoom cuts and
    /// scales it with the picture rather than squeezing it into what is left. The regions of each half of the frame
    /// are then handled as a block, so lines keep their spacing and a sign at the top doesn't drag the dialogue at the
    /// bottom: scaled by `scale` from the frame's edge they are near, the bottom block raised by `raise` (a fraction of
    /// the visible height), and blocks off the visible part (dialogue in the bars a crop removed) moved inside it.
    nonisolated public static func imageFrames(
        of cue: SubtitleImageCue, canvas: CGSize, in layout: VideoLayout, scale: Double = 1, raise: Double = 0
    ) -> [CGRect] {
        guard cue.placement == .decodedFrame else {
            return cue.regions.map { imageFrame(of: $0, canvas: canvas, in: layout.visibleRect) }
        }
        var frames = cue.regions.map { imageFrame(of: $0, canvas: canvas, in: layout.frameRect) }
        let bounds = layout.visibleRect
        guard !bounds.isEmpty else { return frames }
        let halves = Dictionary(grouping: frames.indices.filter { !frames[$0].isEmpty }) {
            frames[$0].midY < layout.frameRect.midY
        }
        for (isTop, group) in halves {
            var union = group.dropFirst().reduce(frames[group[0]]) { $0.union(frames[$1]) }
            if scale != 1 {
                let anchor = CGPoint(x: union.midX, y: isTop ? union.minY : union.maxY)
                for index in group {
                    let frame = frames[index]
                    frames[index] = CGRect(
                        x: anchor.x + (frame.minX - anchor.x) * scale, y: anchor.y + (frame.minY - anchor.y) * scale,
                        width: frame.width * scale, height: frame.height * scale)
                }
                union = group.dropFirst().reduce(frames[group[0]]) { $0.union(frames[$1]) }
            }
            // Inside the visible part first, then raised from there, as text is from the visible bottom: raised
            // before, a block a crop pushed up would only come back to the edge. A raise that would take it past the
            // top stops there.
            var shift = CGPoint(
                x: offset(moving: union.minX...union.maxX, into: bounds.minX...bounds.maxX),
                y: offset(moving: union.minY...union.maxY, into: bounds.minY...bounds.maxY))
            if !isTop, raise > 0 {
                let top = union.minY + shift.y
                shift.y -= min(raise * bounds.height, max(top - bounds.minY, 0))
            }
            for index in group { frames[index] = frames[index].offsetBy(dx: shift.x, dy: shift.y) }
        }
        return frames
    }

    /// The shift that brings `span` inside `bounds`, or centers it on them when it is longer.
    private nonisolated static func offset(
        moving span: ClosedRange<CGFloat>, into bounds: ClosedRange<CGFloat>
    ) -> CGFloat {
        let length = span.upperBound - span.lowerBound
        if length > bounds.upperBound - bounds.lowerBound {
            return (bounds.lowerBound + bounds.upperBound - span.lowerBound - span.upperBound) / 2
        }
        if span.lowerBound < bounds.lowerBound { return bounds.lowerBound - span.lowerBound }
        if span.upperBound > bounds.upperBound { return bounds.upperBound - span.upperBound }
        return 0
    }

    /// Pictures of the regions on screen, so a redraw of the view (the time ticks) doesn't expand and wrap the pixels
    /// again. A cue's regions never change, and libass frames get a new id with every render. A libass frame may hold a
    /// picture per sign on screen, so the count is roomy; bytes bound the frames already replaced.
    private nonisolated(unsafe) static let imageCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    private static func cachedImage(of region: SubtitleImageCue.Region, cue: Int, index: Int) -> CGImage? {
        let key = "\(cue)-\(index)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = makeImage(region) else { return nil }
        imageCache.setObject(image, forKey: key, cost: region.width * region.height * 4)
        return image
    }

    nonisolated static func makeImage(_ region: SubtitleImageCue.Region) -> CGImage? {
        guard region.width > 0, region.height > 0,
            let provider = CGDataProvider(data: region.premultipliedBGRA() as CFData)
        else { return nil }
        return CGImage(
            width: region.width, height: region.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: region.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The part of the container the picture covers (`VideoLayout.visibleRect`), matching the placement of
    /// NativeVideoHostView / MetalVideoRenderer: cues stay on the visible picture when it is cropped or zoomed.
    nonisolated public static func computeVideoFrame(
        containerSize: CGSize,
        videoWidth: Int,
        videoHeight: Int,
        sampleAspectRatio: RationalAspectRatio = .square,
        geometry: VideoGeometrySettings = VideoGeometrySettings(),
        backingScale: CGFloat = 1.0
    ) -> CGRect {
        computeVideoLayout(
            containerSize: containerSize, videoWidth: videoWidth, videoHeight: videoHeight,
            sampleAspectRatio: sampleAspectRatio, geometry: geometry, backingScale: backingScale
        ).visibleRect
    }

    /// The picture's layout in the container; the whole container when either size is unknown.
    nonisolated public static func computeVideoLayout(
        containerSize: CGSize,
        videoWidth: Int,
        videoHeight: Int,
        sampleAspectRatio: RationalAspectRatio = .square,
        geometry: VideoGeometrySettings = VideoGeometrySettings(),
        backingScale: CGFloat = 1.0
    ) -> VideoLayout {
        let container = CGRect(origin: .zero, size: containerSize)
        guard containerSize.width > 0, containerSize.height > 0, videoWidth > 0, videoHeight > 0 else {
            return VideoLayout(
                frameRect: container, contentRect: container, visibleRect: container,
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), panLimit: .zero)
        }
        return VideoGeometry.layout(
            viewSize: containerSize,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            sampleAspectRatio: sampleAspectRatio,
            settings: geometry,
            backingScale: backingScale
        )
    }

    @ViewBuilder
    private func cueRow(_ cue: SubtitleCue, effectiveFontSize: Double, horizontalMargin: Double, scale: Double)
        -> some View
    {
        HStack {
            if isTrailingAligned(cue.alignment) {
                Spacer()
            }

            subtitleLabel(
                cue.text, textAlignment: textAlignment(for: cue.alignment), effectiveFontSize: effectiveFontSize,
                scale: scale)

            if isLeadingAligned(cue.alignment) {
                Spacer()
            }
        }
        .padding(.horizontal, horizontalMargin)
    }

    public static func resolveWeight(_ name: String) -> Font.Weight {
        switch name.lowercased() {
        case "ultralight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return .semibold
        }
    }

    public static func resolveFont(name: String, size: Double, weightName: String = "Semibold") -> Font {
        let weight = resolveWeight(weightName)
        guard let system = SubtitleSystemFont(fontName: name) else {
            return .custom(name, size: size).weight(weight)
        }
        let design: Font.Design =
            switch system {
            case .rounded: .rounded
            case .standard: .default
            case .serif: .serif
            case .monospaced: .monospaced
            }
        return .system(size: size, weight: weight, design: design)
    }

    @ViewBuilder
    private func subtitleLabel(_ text: String, textAlignment: TextAlignment, effectiveFontSize: Double, scale: Double)
        -> some View
    {
        let outlineWidth = max(1.0, 1.5 * scale)

        Text(text)
            .font(Self.resolveFont(name: fontName, size: effectiveFontSize, weightName: fontWeight))
            .foregroundStyle(textColor)
            .multilineTextAlignment(textAlignment)
            .subtitleOutline(radius: outlineWidth, color: .black.opacity(0.95))
            .shadow(color: .black.opacity(0.4), radius: max(1.5, 2.0 * scale), x: 0, y: max(1.0, 1.5 * scale))
            .padding(.horizontal, max(10.0, 16.0 * scale))
            .padding(.vertical, max(5.0, 8.0 * scale))
            .background(
                RoundedRectangle(cornerRadius: max(5.0, 8.0 * scale))
                    .fill(backgroundColor.opacity(backgroundOpacity))
            )
    }

    private func isTopAligned(_ alignment: SubtitleAlignment) -> Bool {
        alignment == .topCenter || alignment == .topLeft || alignment == .topRight
    }

    private func isLeadingAligned(_ alignment: SubtitleAlignment) -> Bool {
        alignment == .topLeft || alignment == .bottomLeft
    }

    private func isTrailingAligned(_ alignment: SubtitleAlignment) -> Bool {
        alignment == .topRight || alignment == .bottomRight
    }

    private func textAlignment(for alignment: SubtitleAlignment) -> TextAlignment {
        if isLeadingAligned(alignment) {
            return .leading
        } else if isTrailingAligned(alignment) {
            return .trailing
        }
        return .center
    }
}
