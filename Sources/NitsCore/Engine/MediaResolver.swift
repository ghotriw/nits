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

/// The streams a `MediaResolver` found for a page.
public struct ResolvedMedia: Sendable, Equatable {
    /// The stream with the picture (or the only one), opened as the media.
    public var path: String
    /// What its streams are read with, in place of the request's.
    public var headers: [String: String]
    /// Audio of its own (a site's separate audio streams), before the request's.
    public var audioFiles: [MediaLoadRequest.AudioFile]
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

    public init(
        path: String, headers: [String: String] = [:], audioFiles: [MediaLoadRequest.AudioFile] = [],
        chapters: [MediaChapter] = [], title: String? = nil, historyKey: String? = nil,
        actionButtons: [PlaybackActionButton] = []
    ) {
        self.path = path
        self.headers = headers
        self.audioFiles = audioFiles
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
