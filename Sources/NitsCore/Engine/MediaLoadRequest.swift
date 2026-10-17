import Foundation

/// A structured request object encapsulating all parameters required to load and initialize media.
public struct MediaLoadRequest: Sendable, Equatable {
    /// The media file path or stream URL string.
    public var path: String

    /// An optional explicit display title for the media.
    public var title: String?

    /// Optional raw artwork image data for Now Playing integration.
    public var artworkData: Data?

    /// Optional artwork URL for Now Playing integration.
    public var artworkURL: URL?

    /// HTTP/HTTPS or streaming headers (e.g. auth tokens, custom user-agent).
    public var headers: [String: String]

    /// An optional custom start playback position in seconds.
    public var startTime: Double?

    /// Optional track identifier or language name to select for audio upon loading.
    public var audioTrack: String?

    /// Optional track identifier or language name to select for subtitles upon loading.
    public var subtitleTrack: String?

    /// Action buttons for this media; they replace the previous media's as soon as the load starts.
    public var actionButtons: [PlaybackActionButton]

    public init(
        path: String,
        title: String? = nil,
        artworkData: Data? = nil,
        artworkURL: URL? = nil,
        headers: [String: String] = [:],
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil,
        actionButtons: [PlaybackActionButton] = []
    ) {
        self.actionButtons = actionButtons
        self.path = path
        self.title = title
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        self.headers = headers
        self.startTime = startTime
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
    }

    // MARK: - Fluent Builder Helpers

    public func title(_ value: String?) -> Self {
        var copy = self
        copy.title = value
        return copy
    }

    public func artworkData(_ value: Data?) -> Self {
        var copy = self
        copy.artworkData = value
        return copy
    }

    public func artworkURL(_ value: URL?) -> Self {
        var copy = self
        copy.artworkURL = value
        return copy
    }

    public func headers(_ value: [String: String]) -> Self {
        var copy = self
        copy.headers = value
        return copy
    }

    public func startTime(_ value: Double?) -> Self {
        var copy = self
        copy.startTime = value
        return copy
    }

    public func audioTrack(_ value: String?) -> Self {
        var copy = self
        copy.audioTrack = value
        return copy
    }

    public func subtitleTrack(_ value: String?) -> Self {
        var copy = self
        copy.subtitleTrack = value
        return copy
    }

    public func actionButtons(_ value: [PlaybackActionButton]) -> Self {
        var copy = self
        copy.actionButtons = value
        return copy
    }
}
