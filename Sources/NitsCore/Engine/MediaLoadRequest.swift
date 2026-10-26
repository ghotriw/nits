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

    /// Bytes each HTTP request of a network input asks for, the file read in successive range requests; `nil` or 0
    /// asks for the rest of it in one. Some servers throttle a request for the whole file: YouTube's to about twice the
    /// stream's bitrate, which playback at 2x outruns, where requests of 10 MB come at the link's full rate.
    public var httpRequestSize: Int?

    /// Audio files that go with the media (a host's or yt-dlp's separate audio), opened with it and listed as its
    /// tracks; a network one with `headers`. The track to start with is chosen from them and the media's own alike.
    public var audioFiles: [AudioFile]

    /// An audio file of the media, and what to list its tracks as.
    public struct AudioFile: Sendable, Equatable {
        public var url: URL
        /// Shown for its tracks as given, over the stream's own title and the file's name ("English, original").
        public var title: String?
        /// Its language (ISO 639), over the one its streams tell.
        public var language: String?
        /// What a network one is read with; `nil` for those it comes with (the request's, or a resolved page's).
        public var headers: [String: String]?
        /// The media's own sound (a site's audio apart from its picture): the load fails without it, where a file
        /// that can't be read is otherwise left out.
        public var isRequired: Bool
        /// What a network one's HTTP requests ask for (`MediaLoadRequest.httpRequestSize`): `nil` for what it comes
        /// with, as `headers` (the request's, or a resolved page's); 0 for the rest of the file in one request, whatever
        /// that is (a load gives the request's own files 0 when a page's size would otherwise apply).
        public var httpRequestSize: Int?
        /// The one audio stream the file holds, when the host knows it. Its track is listed without opening the file,
        /// which is opened when the track is selected (a file that is `isRequired` is opened with the media anyway):
        /// a page with a dub in twenty languages doesn't open twenty files to list them.
        public var declaredStream: DeclaredStream?

        /// What the menu shows of a file's stream, and a decoder isn't made from: the file tells the rest once opened.
        public struct DeclaredStream: Sendable, Equatable {
            public var codecName: String
            public var channels: Int
            public var sampleRate: Int

            public init(codecName: String, channels: Int = 2, sampleRate: Int = 48000) {
                self.codecName = codecName
                self.channels = channels
                self.sampleRate = sampleRate
            }
        }

        /// Listed without being opened (`declaredStream`), until its track is selected.
        var isLazy: Bool { declaredStream != nil && !isRequired }

        public init(
            url: URL, title: String? = nil, language: String? = nil, headers: [String: String]? = nil,
            isRequired: Bool = false, httpRequestSize: Int? = nil, declaredStream: DeclaredStream? = nil
        ) {
            self.url = url
            self.title = title
            self.language = language
            self.headers = headers
            self.isRequired = isRequired
            self.httpRequestSize = httpRequestSize
            self.declaredStream = declaredStream
        }
    }

    /// An optional custom start playback position in seconds. Any value, including `0`, overrides the saved
    /// resume position; `nil` leaves resuming to `PlayerConfiguration.resumePlayback`.
    public var startTime: Double?

    /// Optional track identifier or language name to select for audio upon loading.
    public var audioTrack: String?

    /// Optional track identifier or language name to select for subtitles upon loading.
    public var subtitleTrack: String?

    /// Action buttons for this media; they replace the previous media's as soon as the load starts.
    public var actionButtons: [PlaybackActionButton]

    /// The host's queue around this media (see `PlayerEngine.onTrackNavigation`); like `actionButtons`, it replaces
    /// the previous media's as soon as the load starts.
    public var trackNavigation: TrackNavigation

    public init(
        path: String,
        title: String? = nil,
        artworkData: Data? = nil,
        artworkURL: URL? = nil,
        headers: [String: String] = [:],
        audioFiles: [AudioFile] = [],
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil,
        actionButtons: [PlaybackActionButton] = [],
        trackNavigation: TrackNavigation = TrackNavigation(),
        httpRequestSize: Int? = nil
    ) {
        self.httpRequestSize = httpRequestSize
        self.actionButtons = actionButtons
        self.trackNavigation = trackNavigation
        self.path = path
        self.title = title
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        self.headers = headers
        self.audioFiles = audioFiles
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

    public func httpRequestSize(_ value: Int?) -> Self {
        var copy = self
        copy.httpRequestSize = value
        return copy
    }

    public func audioFiles(_ value: [AudioFile]) -> Self {
        var copy = self
        copy.audioFiles = value
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

    public func trackNavigation(_ value: TrackNavigation) -> Self {
        var copy = self
        copy.trackNavigation = value
        return copy
    }
}
