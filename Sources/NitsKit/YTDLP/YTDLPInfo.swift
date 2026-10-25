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

        enum CodingKeys: String, CodingKey {
            case url, `protocol`, vcodec, acodec, language
            case formatNote = "format_note"
            case manifestURL = "manifest_url"
            case httpHeaders = "http_headers"
        }

        /// A stream of the picture (perhaps with sound); yt-dlp says "none" for a stream without one, and nothing
        /// when it doesn't know (a site's single format).
        var hasVideo: Bool { vcodec != "none" }
        var hasAudio: Bool { acodec != "none" }
    }

    var type: String?
    var id: String?
    var title: String?
    var extractorKey: String?
    /// A URL the generic extractor found to be media itself, not a page.
    var direct: Bool?
    /// The format chosen, when it is one (a site's muxed stream): the top level carries it.
    var url: String?
    var `protocol`: String?
    var manifestURL: String?
    var httpHeaders: [String: String]?
    /// The formats chosen, when `-f` merged several (a picture and its audio).
    var requestedFormats: [Format]?

    enum CodingKeys: String, CodingKey {
        case type = "_type"
        case id, title, direct, url, `protocol`
        case extractorKey = "extractor_key"
        case manifestURL = "manifest_url"
        case httpHeaders = "http_headers"
        case requestedFormats = "requested_formats"
    }

    /// Protocols the demuxer reads: progressive HTTP and HLS. Not DASH manifests or fragments (FFmpeg's DASH demuxer
    /// isn't built), nor Smooth Streaming or HDS.
    static func isPlayable(_ protocol: String?) -> Bool {
        guard let `protocol` else { return true }
        return `protocol` == "http" || `protocol` == "https" || `protocol`.hasPrefix("m3u8")
    }

    /// The streams to play the page from; `nil` when `pageURL` is media itself, to open as it is.
    func resolvedMedia(for pageURL: URL) throws -> ResolvedMedia? {
        if type == "playlist" {
            throw MediaResolutionError("Playlists aren't supported yet")
        }
        if direct == true || (extractorKey == "Generic" && url == pageURL.absoluteString) { return nil }

        let formats = requestedFormats ?? []
        let picture = formats.first(where: \.hasVideo) ?? formats.first
        let main =
            picture
            ?? Format(url: url, protocol: `protocol`, manifestURL: manifestURL, httpHeaders: httpHeaders)
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
        // HLS opens from its master playlist, which a URL without `.m3u8` needed yt-dlp to tell: its variants and
        // audio renditions, not the one variant `-f` chose, play with adaptive bitrate.
        if main.protocol?.hasPrefix("m3u8") == true, let master = main.manifestURL {
            return ResolvedMedia(path: master, headers: headers, title: title, historyKey: historyKey)
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
                        headers: format.httpHeaders, isRequired: true)
                }
            },
            title: title,
            historyKey: historyKey)
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
