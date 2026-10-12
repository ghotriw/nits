import NitsCore
import SwiftUI

public struct SubtitleOverlayView: View {
    public let cues: [SubtitleCue]
    public let fontSize: Double
    public let textColor: Color
    public let backgroundColor: Color
    public let backgroundOpacity: Double
    public let fontName: String
    public let fontWeight: String
    public let videoWidth: Int
    public let videoHeight: Int
    public let displayAspectRatio: Double

    public init(
        cues: [SubtitleCue],
        fontSize: Double = 24.0,
        textColor: Color = .white,
        backgroundColor: Color = .black,
        backgroundOpacity: Double = 0.65,
        fontName: String = "System Rounded",
        fontWeight: String = "Semibold",
        videoWidth: Int = 0,
        videoHeight: Int = 0,
        displayAspectRatio: Double = 0.0
    ) {
        self.cues = cues
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.fontName = fontName
        self.fontWeight = fontWeight
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.displayAspectRatio = displayAspectRatio
    }

    public init(
        cue: SubtitleCue?,
        fontSize: Double = 24.0,
        textColor: Color = .white,
        backgroundColor: Color = .black,
        backgroundOpacity: Double = 0.65,
        fontName: String = "System Rounded",
        fontWeight: String = "Semibold",
        videoWidth: Int = 0,
        videoHeight: Int = 0,
        displayAspectRatio: Double = 0.0
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
            displayAspectRatio: displayAspectRatio
        )
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
        if !cues.isEmpty {
            GeometryReader { geometry in
                let containerSize = geometry.size
                let videoFrame = Self.computeVideoFrame(
                    containerSize: containerSize,
                    videoWidth: videoWidth,
                    videoHeight: videoHeight,
                    displayAspectRatio: displayAspectRatio
                )
                let scale = videoFrame.height > 0 ? (videoFrame.height / Self.referenceViewportHeight) : 1.0
                let effectiveFontSize = min(max(fontSize * scale, Self.minFontSize), Self.maxFontSize)
                let verticalEdgePadding = max(20.0, 40.0 * scale)
                let horizontalMargin = max(16.0, 32.0 * scale)

                ZStack {
                    VStack(spacing: 8 * scale) {
                        // Top aligned cues
                        if !topCues.isEmpty {
                            VStack(spacing: 6 * scale) {
                                ForEach(topCues) { cue in
                                    cueRow(
                                        cue, effectiveFontSize: effectiveFontSize, horizontalMargin: horizontalMargin,
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
                                        cue, effectiveFontSize: effectiveFontSize, horizontalMargin: horizontalMargin,
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
                                        cue, effectiveFontSize: effectiveFontSize, horizontalMargin: horizontalMargin,
                                        scale: scale)
                                }
                            }
                            .padding(.bottom, verticalEdgePadding)
                        }
                    }
                    .frame(width: videoFrame.width, height: videoFrame.height)
                    .position(x: videoFrame.midX, y: videoFrame.midY)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.12)))
        }
    }

    /// Calculates the aspect-fit frame of the video inside the container,
    /// matching the placement of NativeVideoHostView / MetalVideoRenderer.
    nonisolated public static func computeVideoFrame(
        containerSize: CGSize,
        videoWidth: Int,
        videoHeight: Int,
        displayAspectRatio: Double = 0.0
    ) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        guard videoWidth > 0, videoHeight > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let aspect: Double = displayAspectRatio > 0 ? displayAspectRatio : (Double(videoWidth) / Double(videoHeight))

        let containerAspect = Double(containerSize.width) / Double(containerSize.height)

        if containerAspect > aspect {
            // Container is wider than video: pillarbox on sides
            let targetWidth = Double(containerSize.height) * aspect
            let offsetX = (Double(containerSize.width) - targetWidth) / 2.0
            return CGRect(x: offsetX, y: 0, width: targetWidth, height: Double(containerSize.height))
        } else {
            // Container is taller than video: letterbox on top/bottom
            let targetHeight = Double(containerSize.width) / aspect
            let offsetY = (Double(containerSize.height) - targetHeight) / 2.0
            return CGRect(x: 0, y: offsetY, width: Double(containerSize.width), height: targetHeight)
        }
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
        switch name {
        case "System Rounded", "":
            return .system(size: size, weight: weight, design: .rounded)
        case "System", "Standard":
            return .system(size: size, weight: weight, design: .default)
        case "System Serif", "Serif":
            return .system(size: size, weight: weight, design: .serif)
        case "System Monospaced", "Monospaced":
            return .system(size: size, weight: weight, design: .monospaced)
        default:
            return .custom(name, size: size).weight(weight)
        }
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
