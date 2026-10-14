import NitsCore
import SwiftUI

/// Stack of log messages mirrored to the screen when the debug OSD is enabled.
/// Visually matches `OSDOverlayView` badges, with a level-tinted icon.
public struct DebugOSDStackView: View {
    public let messages: [DebugOSDMessage]

    public init(messages: [DebugOSDMessage]) {
        self.messages = messages
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(messages) { message in
                DebugOSDBadge(message: message)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
    }
}

struct DebugOSDBadge: View {
    let message: DebugOSDMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.iconName(for: message.level))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.tint(for: message.level))
                .frame(width: 14)

            Text(message.category.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))

            Text(message.text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            if message.repeatCount > 1 {
                Text("×\(message.repeatCount)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Self.tint(for: message.level).opacity(0.35), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 0)
    }

    static func iconName(for level: LogLevel) -> String {
        switch level {
        case .debug: return "ladybug.fill"
        case .info: return "info.circle.fill"
        case .notice: return "bell.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    static func tint(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .cyan
        case .notice: return .mint
        case .warning: return .yellow
        case .error: return .red
        }
    }
}
