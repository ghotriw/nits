import Foundation

/// Turns the address of a page (a video site's) into the streams that play it, before the media opens: the host's
/// (Nits' yt-dlp). The load keeps the page's address: the history, the playlist and `PlayerEngine.currentPath` go by
/// it, and the streams, which expire, are resolved again on each load.
public protocol MediaResolver: Sendable {
    /// When to resolve `url`, if it may be a page: `nil` never. On the main actor, for each load of a network URL, so
    /// it must not wait.
    func order(for url: URL) -> MediaResolutionOrder?
    /// The streams of the page at `url`, asked with the request's `headers`; `nil` when `url` is no page the resolver
    /// knows (a stream itself, a site it doesn't support): it then opens as it is. Throws when the page has nothing to
    /// play; a cancelled task (the load replaced or stopped) may end it early, its result unused.
    func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia?
}

/// When a load asks its `MediaResolver` (mpv's order for yt-dlp).
public enum MediaResolutionOrder: Sendable, Equatable {
    /// Before the URL opens: a site known to have pages, which the demuxer can't read.
    case beforeOpening
    /// Once the URL failed to open as media: anything else, which would otherwise wait for the resolver (seconds)
    /// and fail on its errors (a media server's stream, which it doesn't know).
    case afterOpeningFails
}

/// A picture a page offers as a file of its own (yt-dlp's progressive formats), which the viewer may play instead of the
/// one chosen. Switching opens it as the media, the audio files and the position staying.
public struct VideoFormat: Sendable, Equatable, Identifiable {
    /// Names it among the page's (yt-dlp's `format_id`).
    public var id: String
    public var url: String
    public var width: Int
    public var height: Int
    public var frameRate: Double?
    /// As shown ("AV1", "VP9", "H.264").
    public var codec: String
    /// Bits per second; 0 when unknown.
    public var bitrate: Int
    /// What its requests ask for (`MediaLoadRequest.httpRequestSize`) and are read with, in place of the page's.
    public var httpRequestSize: Int?
    public var headers: [String: String]?

    public init(
        id: String, url: String, width: Int, height: Int, frameRate: Double? = nil, codec: String = "",
        bitrate: Int = 0,
        httpRequestSize: Int? = nil, headers: [String: String]? = nil
    ) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.bitrate = bitrate
        self.httpRequestSize = httpRequestSize
        self.headers = headers
    }
}

/// What a resolver knows of a live stream it gives as the segments of its past up to now (`ResolvedMedia.liveHistory`),
/// and the demuxer, which reads a manifest of segments, cannot: where the stream's time stands. Both in seconds of the
/// stream's own time (from its start, which the segments' timestamps count in).
public struct LiveHistory: Sendable, Equatable {
    /// The start of the first segment: the media's timeline begins here, and the engine's zero stands for it (it counts
    /// on times from zero), so what is saved of a position is its time plus this.
    public var origin: Double
    /// The end of the newest segment, when the manifest was made. The edge moves on from there with the clock
    /// (`LiveStream`).
    public var end: Double
    /// The number of that segment (the newest one then).
    public var headNumber: Int
    /// What the manifest's segments are asked for through (their addresses, the head, the signature), when the manifest
    /// goes on past the head: the segments to come are waited for (`LiveSegmentGate`). `nil`: the manifest ends at the head.
    public var source: (any LiveSegmentSource)?

    /// How long a segment of a live stream given as segments lasts, about (YouTube's): the end of a segment whose start is
    /// known and whose length is not, and the length of those to come.
    public static let nominalSegmentDuration = 5.0

    /// What a manifest names the stream `key` by: the address its segments are asked for (with `sq=N`) through the
    /// source (`LiveSegmentSource.url(for:number:)`), not an address that exists.
    package static func streamAddress(_ key: String) -> String {
        "https://\(LiveSegmentGate.host)/\(key)"
    }

    public init(origin: Double, end: Double, headNumber: Int = 0, source: (any LiveSegmentSource)? = nil) {
        self.origin = origin
        self.end = end
        self.headNumber = headNumber
        self.source = source
    }

    public static func == (lhs: LiveHistory, rhs: LiveHistory) -> Bool {
        lhs.origin == rhs.origin && lhs.end == rhs.end && lhs.headNumber == rhs.headNumber && lhs.source === rhs.source
    }
}

/// The streams a `MediaResolver` found for a page.
public struct ResolvedMedia: Sendable, Equatable {
    /// The stream with the picture (or the only one), opened as the media.
    public var path: String
    /// What its streams are read with, in place of the request's.
    public var headers: [String: String]
    /// What the HTTP requests of `path` ask for (`MediaLoadRequest.httpRequestSize`; yt-dlp's `http_chunk_size`).
    /// An audio file of `audioFiles` without its own takes it, as it takes `headers`.
    public var httpRequestSize: Int?
    /// Audio of its own (a site's separate audio streams), before the request's.
    public var audioFiles: [MediaLoadRequest.AudioFile]
    /// Subtitles of its own (a site's subtitle tracks), before the request's.
    public var subtitleFiles: [MediaLoadRequest.SubtitleFile]
    /// Chapters of the media (a site's chapters, e.g. from yt-dlp), used when the stream's container has none.
    public var chapters: [MediaChapter]
    /// The page's title, shown when the request gives none.
    public var title: String?
    /// What the history saves the media as, the same for every address of the page (yt-dlp's extractor and id,
    /// `youtube:dQw4w9WgXcQ`); `nil` saves it as the page's URL, which the history keys without its query, so pages
    /// told apart by it (`watch?v=`) would share one record.
    public var historyKey: String?
    /// Action buttons for spans of the timeline (e.g. SponsorBlock "Skip Sponsor" / "Skip Intro").
    public var actionButtons: [PlaybackActionButton]
    /// The pictures the page offers, best first, and which of them `path` is (`nil` when it is none of them); empty
    /// when there is nothing to choose from.
    public var videoFormats: [VideoFormat]
    public var selectedVideoFormatID: String?
    /// Set when `path` is a live stream's past and present as segments the resolver numbered (a manifest of its own),
    /// not a playlist the demuxer reads the window of: the demuxer plays it as live, on a timeline from zero.
    public var liveHistory: LiveHistory?

    public init(
        path: String, headers: [String: String] = [:], audioFiles: [MediaLoadRequest.AudioFile] = [],
        subtitleFiles: [MediaLoadRequest.SubtitleFile] = [],
        chapters: [MediaChapter] = [], title: String? = nil, historyKey: String? = nil,
        actionButtons: [PlaybackActionButton] = [], httpRequestSize: Int? = nil, videoFormats: [VideoFormat] = [],
        selectedVideoFormatID: String? = nil, liveHistory: LiveHistory? = nil
    ) {
        self.liveHistory = liveHistory
        self.videoFormats = videoFormats
        self.selectedVideoFormatID = selectedVideoFormatID
        self.path = path
        self.headers = headers
        self.httpRequestSize = httpRequestSize
        self.audioFiles = audioFiles
        self.subtitleFiles = subtitleFiles
        self.chapters = chapters
        self.title = title
        self.historyKey = historyKey
        self.actionButtons = actionButtons
    }
}

/// A page the resolver found nothing to play in, with its reason (yt-dlp's message).
public struct MediaResolutionError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// The resolver knew the page (a site it supports: "Video unavailable"), so its reason is the one to show. When
    /// it only failed to read the URL as the demuxer did (an HTTP error, a timeout), a URL resolved once it failed to
    /// open shows the demuxer's reason instead.
    public var isAboutPage: Bool

    public init(_ message: String, isAboutPage: Bool = true) {
        self.message = message
        self.isAboutPage = isAboutPage
    }

    public var description: String { message }
}

extension ResolvedMedia {
    /// The streams with the picture `id` of `videoFormats` as the media, read with its headers and request size;
    /// `nil` when the page has no such picture.
    public func selecting(videoFormat id: String) -> ResolvedMedia? {
        guard let format = videoFormats.first(where: { $0.id == id }) else { return nil }
        var media = self
        media.path = format.url
        media.selectedVideoFormatID = id
        if let headers = format.headers { media.headers = headers }
        media.httpRequestSize = format.httpRequestSize
        return media
    }
}
