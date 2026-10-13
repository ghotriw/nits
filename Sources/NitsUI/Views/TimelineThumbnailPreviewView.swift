import AppKit
import NitsCore
import SwiftUI

/// Floating thumbnail preview card displayed above the timeline slider on hover / scrub.
public struct TimelineThumbnailPreviewView: View {
    public let thumbnail: ThumbnailItem?
    public let time: Double
    public let duration: Double

    public init(thumbnail: ThumbnailItem?, time: Double, duration: Double) {
        self.thumbnail = thumbnail
        self.time = time
        self.duration = duration
    }

    public var body: some View {
        VStack(spacing: 5) {
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 160, height: 90)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }

            Text(formatTime(time))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(minWidth: duration >= 3600 ? 54 : 38)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(thumbnail != nil ? Color.black.opacity(0.65) : Color.clear)
                )
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
        .allowsHitTesting(false)
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
