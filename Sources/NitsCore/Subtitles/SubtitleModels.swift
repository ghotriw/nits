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
    /// For ASS / SSA, the event as a `Dialogue:` line in `AssScript.eventFormat` (tags included), timed like the cue
    /// on the media timeline, for hosts that draw it themselves after `subtitleAssHeader`; whatever field order the
    /// file or container used. `nil` for formats whose `text` already says it all.
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

/// The designs of the system font the subtitle style offers, by the name `subtitleFontName` stores for each; any
/// other name is a font family. The one list of these names: the text overlay and libass both resolve through it.
public enum SubtitleSystemFont: String, CaseIterable, Sendable {
    case rounded = "System Rounded"
    case standard = "System"
    case serif = "System Serif"
    case monospaced = "System Monospaced"

    /// The design a stored font name stands for, its short alias, or an empty name (the default design); `nil`
    /// for a font family.
    public init?(fontName: String) {
        switch fontName {
        case Self.rounded.rawValue, "": self = .rounded
        case Self.standard.rawValue, "Standard": self = .standard
        case Self.serif.rawValue, "Serif": self = .serif
        case Self.monospaced.rawValue, "Monospaced": self = .monospaced
        default: return nil
        }
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
    /// For CEA-608 closed captions, the field they are read from: 0 for CC1, 1 for CC3. Captions in the pictures of a
    /// video stream (`streamIndex` is that stream's) or an MP4 caption track (`c608`); `nil` for other tracks.
    public let closedCaptionField: Int?
    /// Closed captions in the pictures of the video stream `streamIndex` names: no stream of their own, so the index
    /// doesn't name the track (CC1 and CC3 share it).
    public let captionsInVideo: Bool

    public var isExternal: Bool { externalURL != nil }

    public init(
        id: Int,
        streamIndex: Int = -1,
        title: String,
        language: String,
        externalURL: URL? = nil,
        isForced: Bool = false,
        isSDH: Bool = false,
        format: SubtitleFormat = .text,
        closedCaptionField: Int? = nil,
        captionsInVideo: Bool = false
    ) {
        self.format = format
        self.closedCaptionField = closedCaptionField
        self.captionsInVideo = captionsInVideo
        self.id = id
        self.streamIndex = streamIndex
        self.title = title
        self.language = language
        self.externalURL = externalURL
        self.isForced = isForced
        self.isSDH = isSDH
    }
}
