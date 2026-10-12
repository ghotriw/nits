import SwiftUI

public struct OSDOverlayView: View {
    public let event: OSDEvent

    public init(event: OSDEvent) {
        self.event = event
    }

    public var body: some View {
        HStack(spacing: 12) {
            symbolView

            VStack(alignment: .leading, spacing: 3) {
                primaryTextView

                if let subtext = secondaryText {
                    Text(subtext)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }

                if let progress = progressValue {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                            Capsule()
                                .fill(Color.white)
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progress))))
                        }
                    }
                    .frame(width: 110, height: 4)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 0)
    }

    @ViewBuilder
    private var symbolView: some View {
        Image(systemName: iconName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
    }

    @ViewBuilder
    private var primaryTextView: some View {
        Text(primaryText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private var iconName: String {
        switch event {
        case .play:
            return "play.fill"
        case .pause:
            return "pause.fill"
        case .seek(let offset, _, _):
            return offset >= 0 ? "goforward" : "gobackward"
        case .volume(let level, let isMuted):
            if isMuted || level <= 0.001 {
                return "speaker.slash.fill"
            } else if level < 0.33 {
                return "speaker.wave.1.fill"
            } else if level < 0.66 {
                return "speaker.wave.2.fill"
            } else {
                return "speaker.wave.3.fill"
            }
        case .frameStep(let forward):
            return forward ? "forward.frame.fill" : "backward.frame.fill"
        case .audioTrack:
            return "waveform"
        case .subtitleTrack:
            return "captions.bubble.fill"
        case .renderMode:
            return "display"
        case .sharpness:
            return "wand.and.stars"
        case .playbackRate:
            return "gauge.with.dots.needle.bottom.50percent"
        case .custom(let symbol, _, _, _):
            return symbol
        }
    }

    private var primaryText: String {
        switch event {
        case .play:
            return "Play"
        case .pause:
            return "Pause"
        case .seek(let offset, _, _):
            return TimeParser.formatSeekOffset(offset)
        case .volume(let level, let isMuted):
            if isMuted {
                return "Muted"
            } else {
                return "\(Int(round(level * 100)))%"
            }
        case .frameStep(let forward):
            return forward ? "+1 Frame" : "-1 Frame"
        case .audioTrack(let title):
            return title
        case .subtitleTrack(let title):
            return title
        case .renderMode(let modeName):
            return modeName
        case .sharpness(let value):
            return "Sharpness: \(Int(round(value * 100)))%"
        case .playbackRate(let rate):
            let isTenth = abs((rate * 10).rounded() - (rate * 10)) < 1e-4
            return isTenth ? String(format: "%.1f×", rate) : String(format: "%.2f×", rate)
        case .custom(_, let text, _, _):
            return text
        }
    }

    private var secondaryText: String? {
        switch event {
        case .seek(_, let current, let duration):
            if duration.isFinite && duration > 0 {
                return "\(formatTime(current)) / \(formatTime(duration))"
            } else {
                return formatTime(current)
            }
        case .audioTrack:
            return "Audio Track"
        case .subtitleTrack:
            return "Subtitles"
        case .renderMode:
            return "Render Pipeline"
        case .playbackRate:
            return "Speed"
        case .custom(_, _, let subtext, _):
            return subtext
        default:
            return nil
        }
    }

    public var progressValue: Float? {
        switch event {
        case .seek(_, let current, let duration):
            guard duration.isFinite && duration > 0 && current.isFinite else { return nil }
            return max(0.0, min(1.0, Float(current / duration)))
        case .volume(let level, let isMuted):
            guard level.isFinite else { return 0.0 }
            return isMuted ? 0.0 : max(0.0, min(1.0, level))
        case .sharpness(let value):
            guard value.isFinite else { return 0.0 }
            return max(0.0, min(1.0, value))
        case .playbackRate(let rate):
            guard rate.isFinite else { return 0.25 }
            return max(0.0, min(1.0, Float((rate - 0.5) / 2.0)))
        case .custom(_, _, _, let progress):
            guard let progress, progress.isFinite else { return nil }
            return max(0.0, min(1.0, progress))
        default:
            return nil
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        TimeParser.format(seconds: seconds)
    }
}
