import Foundation

/// Screen alignment for subtitle caption positioning (matching ASS/WebVTT positions).
public enum SubtitleAlignment: Sendable, Equatable {
    case bottomCenter  // Default (\an2)
    case topCenter  // Top Center (\an8)
    case bottomLeft  // Bottom Left (\an1)
    case bottomRight  // Bottom Right (\an3)
    case topLeft  // Top Left (\an7)
    case topRight  // Top Right (\an9)
    case center  // Center / Middle (\an5)
}

/// Represents an individual timed subtitle caption.
public struct SubtitleCue: Sendable, Equatable, Identifiable {
    public let id: Int
    public let startTime: Double  // in seconds
    public let endTime: Double  // in seconds
    public let text: String  // clean text
    public let alignment: SubtitleAlignment

    public init(
        id: Int,
        startTime: Double,
        endTime: Double,
        text: String,
        alignment: SubtitleAlignment = .bottomCenter
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.alignment = alignment
    }
}

/// Metadata and descriptor for a subtitle stream or external subtitle file.
public struct SubtitleTrack: Sendable, Identifiable, Equatable {
    public let id: Int
    public let streamIndex: Int
    public let title: String
    public let language: String
    /// The subtitle file of an external track; `nil` for a stream of the media.
    public let externalURL: URL?
    public let isForced: Bool
    public let isSDH: Bool

    public var isExternal: Bool { externalURL != nil }

    public init(
        id: Int,
        streamIndex: Int = -1,
        title: String,
        language: String,
        externalURL: URL? = nil,
        isForced: Bool = false,
        isSDH: Bool = false
    ) {
        self.id = id
        self.streamIndex = streamIndex
        self.title = title
        self.language = language
        self.externalURL = externalURL
        self.isForced = isForced
        self.isSDH = isSDH
    }
}
