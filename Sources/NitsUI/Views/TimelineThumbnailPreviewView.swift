import AppKit
import NitsCore
import SwiftUI

/// Borderless thumbnail preview displayed above the timeline slider on hover / scrub.
/// The frame itself is the card; the time label is overlaid at its bottom edge.
public struct TimelineThumbnailPreviewView: View {
    public let thumbnail: ThumbnailItem?
    public let time: Double
    public let duration: Double

    private static let maxImageSize = CGSize(width: 176, height: 132)
    private static let cornerRadius: CGFloat = 8

    public init(thumbnail: ThumbnailItem?, time: Double, duration: Double) {
        self.thumbnail = thumbnail
        self.time = time
        self.duration = duration
    }

    /// Size of the rendered preview, used by the timeline to position and clamp it.
    public static func size(thumbnail: ThumbnailItem?, duration: Double) -> CGSize {
        guard let thumbnail, thumbnail.width > 0, thumbnail.height > 0 else {
            return CGSize(width: timeLabelMinWidth(duration: duration) + 10, height: 18)
        }
        let aspect = CGFloat(thumbnail.width) / CGFloat(thumbnail.height)
        let width = min(maxImageSize.width, maxImageSize.height * aspect)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    private static func timeLabelMinWidth(duration: Double) -> CGFloat {
        duration >= 3600 ? 54 : 38
    }

    public var body: some View {
        Group {
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
        .allowsHitTesting(false)
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
