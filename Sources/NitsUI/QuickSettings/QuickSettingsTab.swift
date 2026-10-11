import Foundation

public enum QuickSettingsTab: String, CaseIterable, Identifiable, Sendable {
    case video = "Video"
    case audio = "Audio"
    case subtitles = "Subtitles"
    case info = "Info"

    public var id: String { rawValue }

    public var title: String { rawValue }

    public var iconName: String {
        switch self {
        case .video:
            return "film"
        case .audio:
            return "waveform"
        case .subtitles:
            return "captions.bubble"
        case .info:
            return "info.circle"
        }
    }
}
