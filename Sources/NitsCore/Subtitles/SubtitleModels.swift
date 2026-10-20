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
    /// The cue as the source stored it (an ASS event line, tags included) for hosts that render it themselves;
    /// `nil` for formats whose `text` already says it all.
    public let rawPayload: String?

    public init(
        id: Int,
        startTime: Double,
        endTime: Double,
        text: String,
        alignment: SubtitleAlignment = .bottomCenter,
        rawPayload: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.alignment = alignment
        self.rawPayload = rawPayload
    }
}

/// How a subtitle track stores its cues, which decides how they are decoded and drawn.
public enum SubtitleFormat: Sendable, Equatable {
    /// Plain or lightly marked-up text: SRT, WebVTT, mov_text.
    case text
    /// Advanced SubStation Alpha / SubStation Alpha: styled, positioned text.
    case ass
    /// Pre-rendered pictures: PGS, VobSub, DVB.
    case bitmap
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
    public let format: SubtitleFormat

    public var isExternal: Bool { externalURL != nil }

    public init(
        id: Int,
        streamIndex: Int = -1,
        title: String,
        language: String,
        externalURL: URL? = nil,
        isForced: Bool = false,
        isSDH: Bool = false,
        format: SubtitleFormat = .text
    ) {
        self.format = format
        self.id = id
        self.streamIndex = streamIndex
        self.title = title
        self.language = language
        self.externalURL = externalURL
        self.isForced = isForced
        self.isSDH = isSDH
    }
}
