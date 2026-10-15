import AppKit
import NitsCore
import SwiftUI

/// Borderless thumbnail preview displayed above the timeline slider on hover / scrub.
/// The frame itself is the card; the time label is overlaid at its bottom edge and the hovered
/// chapter's title, if any, sits above it.
public struct TimelineThumbnailPreviewView: View {
    public let thumbnail: ThumbnailItem?
    public let time: Double
    public let duration: Double
    public let chapterTitle: String?

    private static let maxImageSize = CGSize(width: 176, height: 132)
    private static let cornerRadius: CGFloat = 8
    /// Width of the chapter title when there is no thumbnail to size it by.
    private static let titleOnlyWidth: CGFloat = 160

    public init(thumbnail: ThumbnailItem?, time: Double, duration: Double, chapterTitle: String? = nil) {
        self.thumbnail = thumbnail
        self.time = time
        self.duration = duration
        self.chapterTitle = chapterTitle
    }

    /// Size of the rendered card (without the chapter title's height), used by the timeline to
    /// position and clamp it.
    public static func size(thumbnail: ThumbnailItem?, duration: Double, hasChapterTitle: Bool = false) -> CGSize {
        guard let thumbnail, thumbnail.width > 0, thumbnail.height > 0 else {
            let labelWidth = timeLabelMinWidth(duration: duration) + 10
            return CGSize(width: hasChapterTitle ? max(labelWidth, titleOnlyWidth) : labelWidth, height: 18)
        }
        let aspect = CGFloat(thumbnail.width) / CGFloat(thumbnail.height)
        let width = min(maxImageSize.width, maxImageSize.height * aspect)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    private static func timeLabelMinWidth(duration: Double) -> CGFloat {
        duration >= 3600 ? 54 : 38
    }

    public var body: some View {
        VStack(spacing: 5) {
            if let chapterTitle {
                Text(chapterTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
            }
            card
        }
        // The timeline positions the preview by this width.
        .frame(width: Self.size(thumbnail: thumbnail, duration: duration, hasChapterTitle: chapterTitle != nil).width)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var card: some View {
        if let thumbnail {
            let size = Self.size(thumbnail: thumbnail, duration: duration)
            Image(decorative: thumbnail.image, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .overlay(alignment: .bottom) {
                    timeLabel
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 5)
                }
                .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)
        } else {
            timeLabel
                .background(Color.black.opacity(0.6), in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
        }
    }

    private var timeLabel: some View {
        Text(formatTime(time))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: Self.timeLabelMinWidth(duration: duration))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let total = Int(max(seconds, 0))
        let secs = total % 60
        let mins = (total / 60) % 60
        let hours = total / 3600
        if duration >= 3600 || hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }
}
