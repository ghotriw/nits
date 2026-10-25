import Foundation
import NitsCore

/// What Nits reads of yt-dlp's `--dump-single-json` (`-J`) for a page: the formats `-f` chose and how to read them.
struct YTDLPInfo: Decodable, Sendable {
    struct Format: Decodable, Sendable {
        var url: String?
        var `protocol`: String?
        var vcodec: String?
        var acodec: String?
        var language: String?
        var formatNote: String?
        /// The master playlist an HLS format is a variant of.
        var manifestURL: String?
        var httpHeaders: [String: String]?
        var downloaderOptions: DownloaderOptions?

        enum CodingKeys: String, CodingKey {
            case url, `protocol`, vcodec, acodec, language
            case formatNote = "format_note"
            case manifestURL = "manifest_url"
            case httpHeaders = "http_headers"
            case downloaderOptions = "downloader_options"
        }

        /// A stream of the picture (perhaps with sound); yt-dlp says "none" for a stream without one, and nothing
        /// when it doesn't know (a site's single format).
        var hasVideo: Bool { vcodec != "none" }
        var hasAudio: Bool { acodec != "none" }
    }

    /// How yt-dlp downloads a format: YouTube's HTTPS ones in requests of 10 MB (`http_chunk_size`), as it throttles a
    /// request for the whole file to about twice the stream's bitrate.
    struct DownloaderOptions: Decodable, Sendable {
        var httpChunkSize: Int?

        enum CodingKeys: String, CodingKey {
            case httpChunkSize = "http_chunk_size"
        }
    }

    struct Chapter: Decodable, Sendable {
        var startTime: Double?
        var endTime: Double?
        var title: String?

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case title
        }
    }

    var type: String?
    var id: String?
    var title: String?
    var extractorKey: String?
    /// A URL the generic extractor found to be media itself, not a page.
    var direct: Bool?
    var duration: Double?
    /// The format chosen, when it is one (a site's muxed stream): the top level carries it.
    var url: String?
    var `protocol`: String?
    var manifestURL: String?
    var httpHeaders: [String: String]?
    var downloaderOptions: DownloaderOptions?
    /// The formats chosen, when `-f` merged several (a picture and its audio).
    var requestedFormats: [Format]?
    var chapters: [Chapter]?

    enum CodingKeys: String, CodingKey {
        case type = "_type"
        case id, title, direct, url, `protocol`, duration, chapters
        case extractorKey = "extractor_key"
        case manifestURL = "manifest_url"
        case httpHeaders = "http_headers"
        case downloaderOptions = "downloader_options"
        case requestedFormats = "requested_formats"
    }

    /// Protocols the demuxer reads: progressive HTTP and HLS. Not DASH manifests or fragments (FFmpeg's DASH demuxer
    /// isn't built), nor Smooth Streaming or HDS.
    static func isPlayable(_ protocol: String?) -> Bool {
        guard let `protocol` else { return true }
        return `protocol` == "http" || `protocol` == "https" || `protocol`.hasPrefix("m3u8")
    }

    /// The streams to play the page from; `nil` when `pageURL` is media itself, to open as it is. `sponsorBlock`, the
    /// video's SponsorBlock segments, become skip buttons, and chapters when the author gave none.
    func resolvedMedia(for pageURL: URL, sponsorBlock: [SponsorBlockSegment] = []) throws -> ResolvedMedia? {
        if type == "playlist" {
            throw MediaResolutionError("Playlists aren't supported yet")
        }
        if direct == true || (extractorKey == "Generic" && url == pageURL.absoluteString) { return nil }

        let formats = requestedFormats ?? []
        let picture = formats.first(where: \.hasVideo) ?? formats.first
        let main =
            picture
            ?? Format(
                url: url, protocol: `protocol`, manifestURL: manifestURL, httpHeaders: httpHeaders,
                downloaderOptions: downloaderOptions)
        guard let path = main.url else { throw MediaResolutionError("yt-dlp found no stream to play") }
        let chosen = formats.isEmpty ? [main] : formats
        if let unplayable = chosen.first(where: { !Self.isPlayable($0.protocol) }) {
            throw MediaResolutionError(
                "Its streams need \(unplayable.protocol ?? "another protocol"), not supported yet")
        }
        let headers = main.httpHeaders ?? httpHeaders ?? [:]
        // The ids of the generic extractor are a URL's last component ("video"), the same on many sites: the history
        // keeps to the page's URL instead.
        let historyKey = extractorKey.flatMap { key in
            key == "Generic" ? nil : id.map { "\(key.lowercased()):\($0)" }
        }
        let segments = SponsorBlockSegment.matching(sponsorBlock, duration: duration)
        let authorRaw = (chapters ?? []).compactMap { ch -> MediaChapter.Raw? in
            guard let start = ch.startTime, start.isFinite else { return nil }
            return MediaChapter.Raw(title: ch.title, start: start, end: ch.endTime)
        }
        let rawChapters = !authorRaw.isEmpty ? authorRaw : SponsorBlockSegment.chapters(in: segments)
        let resolvedChapters = MediaChapter.normalized(rawChapters, duration: duration ?? 0)
        let buttons = SponsorBlockSegment.actionButtons(from: segments)

        // HLS opens from its master playlist, which a URL without `.m3u8` needed yt-dlp to tell: its variants and
        // audio renditions, not the one variant `-f` chose, play with adaptive bitrate.
        if main.protocol?.hasPrefix("m3u8") == true, let master = main.manifestURL {
            return ResolvedMedia(
                path: master, headers: headers, chapters: resolvedChapters, title: title, historyKey: historyKey,
                actionButtons: buttons)
        }
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo && $0.url != nil }
        return ResolvedMedia(
            path: path,
            headers: headers,
            // The media's own sound: the picture has none.
            audioFiles: audio.compactMap { format in
                format.url.flatMap(URL.init(string:)).map {
                    MediaLoadRequest.AudioFile(
                        url: $0, title: Self.audioTitle(of: format), language: format.language,
                        headers: format.httpHeaders, isRequired: true,
                        httpRequestSize: format.downloaderOptions?.httpChunkSize)
                }
            },
            chapters: resolvedChapters,
            title: title,
            historyKey: historyKey,
            actionButtons: buttons,
            httpRequestSize: main.downloaderOptions?.httpChunkSize)
    }

    /// The title of an audio format's track: its codec, and whether it is the original among dubs (YouTube notes
    /// "English (US) original (default), medium"). The views add the language.
    static func audioTitle(of format: Format) -> String {
        let codec = format.acodec.map { $0.split(separator: ".").first.map(String.init) ?? $0 } ?? ""
        let name: String
        switch codec.lowercased() {
        case "opus": name = "Opus"
        case "mp4a", "aac": name = "AAC"
        case "ec-3", "eac3": name = "E-AC-3"
        case "ac-3", "ac3": name = "AC-3"
        case "vorbis": name = "Vorbis"
        case "": name = "Audio"
        default: name = codec
        }
        return format.formatNote?.contains("original") == true ? "\(name), original" : name
    }
}
