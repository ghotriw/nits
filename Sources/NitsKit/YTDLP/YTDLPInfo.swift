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
        var formatID: String?
        /// An audio format's bitrate (kbit/s), its channels and sample rate.
        var abr: Double?
        var tbr: Double?
        var width: Int?
        var height: Int?
        var fps: Double?
        var audioChannels: Int?
        var sampleRate: Int?
        /// The master playlist an HLS format is a variant of.
        var manifestURL: String?
        var httpHeaders: [String: String]?
        var downloaderOptions: DownloaderOptions?

        enum CodingKeys: String, CodingKey {
            case url, `protocol`, vcodec, acodec, language
            case formatNote = "format_note"
            case formatID = "format_id"
            case abr, tbr, width, height, fps
            case audioChannels = "audio_channels"
            case sampleRate = "asr"
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

    struct SubtitleEntry: Decodable, Sendable {
        var url: String?
        var ext: String?
        var name: String?
        var `protocol`: String?
        var httpHeaders: [String: String]?

        enum CodingKeys: String, CodingKey {
            case url, ext, name, `protocol`
            case httpHeaders = "http_headers"
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
    /// Every format the page has, from which the other audio languages are listed.
    var formats: [Format]?
    var chapters: [Chapter]?
    var subtitles: [String: [SubtitleEntry]]?
    var automaticCaptions: [String: [SubtitleEntry]]?

    enum CodingKeys: String, CodingKey {
        case type = "_type"
        case id, title, direct, url, `protocol`, duration, chapters, subtitles
        case extractorKey = "extractor_key"
        case manifestURL = "manifest_url"
        case httpHeaders = "http_headers"
        case downloaderOptions = "downloader_options"
        case requestedFormats = "requested_formats"
        case formats
        case automaticCaptions = "automatic_captions"
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

        let resolvedSubtitles = subtitleFiles()

        // HLS opens from its master playlist, which a URL without `.m3u8` needed yt-dlp to tell: its variants and
        // audio renditions, not the one variant `-f` chose, play with adaptive bitrate.
        if main.protocol?.hasPrefix("m3u8") == true, let master = main.manifestURL {
            return ResolvedMedia(
                path: master, headers: headers, subtitleFiles: resolvedSubtitles, chapters: resolvedChapters,
                title: title, historyKey: historyKey, actionButtons: buttons)
        }
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo && $0.url != nil }
        let pictures = otherPictures(like: picture)
        return ResolvedMedia(
            path: path,
            headers: headers,
            // The media's own sound: the picture has none. The one `-f` chose is read with the media; the page's other
            // languages are listed, and opened when one is selected.
            audioFiles: audio.compactMap { Self.audioFile(of: $0, isRequired: true) }
                + otherLanguages(than: audio).compactMap { Self.audioFile(of: $0, isRequired: false) },
            subtitleFiles: resolvedSubtitles,
            chapters: resolvedChapters,
            title: title,
            historyKey: historyKey,
            actionButtons: buttons,
            httpRequestSize: main.downloaderOptions?.httpChunkSize,
            videoFormats: pictures, selectedVideoFormatID: picture?.formatID)
    }

    /// The page's subtitle tracks: author-uploaded (`subtitles`) first, then original speech-to-text captions
    /// (`automatic_captions` without machine-translated `tlang=` URLs). Each track picks the best supported text
    /// format (`ass`/`ssa` > `vtt` > `srt`) over HTTP(S).
    func subtitleFiles() -> [MediaLoadRequest.SubtitleFile] {
        var result: [MediaLoadRequest.SubtitleFile] = []
        var seenURLs: Set<String> = []

        if let subtitles {
            for key in subtitles.keys.sorted() {
                let lowerKey = key.lowercased()
                guard lowerKey != "live_chat", lowerKey != "rechat",
                    let entries = subtitles[key],
                    let chosen = Self.bestSubtitleEntry(from: entries, allowTranslated: true),
                    let urlString = chosen.url, seenURLs.insert(urlString).inserted,
                    let url = URL(string: urlString)
                else { continue }
                let language = Self.normalizedSubtitleLanguage(from: key)
                let title = Self.subtitleTitle(of: chosen, isAutoGenerated: false)
                let lowerTitle = (chosen.name ?? "").lowercased()
                result.append(
                    MediaLoadRequest.SubtitleFile(
                        url: url,
                        title: title,
                        language: language,
                        headers: chosen.httpHeaders,
                        isForced: lowerTitle.contains("forced") || lowerKey.contains("forced"),
                        isSDH: lowerTitle.contains("sdh") || lowerTitle.contains("[cc]"),
                        isAutoGenerated: false,
                        format: Self.subtitleFormat(forExtension: chosen.ext)))
            }
        }

        if let automaticCaptions {
            // Sort keys without "-orig" before "-orig" so the clean language key claims the shared URL first.
            let sortedKeys = automaticCaptions.keys.sorted { lhs, rhs in
                let lhsOrig = lhs.lowercased().hasSuffix("-orig")
                let rhsOrig = rhs.lowercased().hasSuffix("-orig")
                if lhsOrig != rhsOrig { return !lhsOrig }
                return lhs < rhs
            }
            for key in sortedKeys {
                let lowerKey = key.lowercased()
                guard lowerKey != "live_chat", lowerKey != "rechat",
                    let entries = automaticCaptions[key],
                    let chosen = Self.bestSubtitleEntry(from: entries, allowTranslated: false),
                    let urlString = chosen.url, seenURLs.insert(urlString).inserted,
                    let url = URL(string: urlString)
                else { continue }
                let language = Self.normalizedSubtitleLanguage(from: key)
                let title = Self.subtitleTitle(of: chosen, isAutoGenerated: true)
                result.append(
                    MediaLoadRequest.SubtitleFile(
                        url: url,
                        title: title,
                        language: language,
                        headers: chosen.httpHeaders,
                        isAutoGenerated: true,
                        format: Self.subtitleFormat(forExtension: chosen.ext)))
            }
        }

        return result
    }

    private static func bestSubtitleEntry(
        from entries: [SubtitleEntry], allowTranslated: Bool
    ) -> SubtitleEntry? {
        var best: (entry: SubtitleEntry, rank: Int)?
        for entry in entries {
            guard entry.protocol == nil || entry.protocol == "http" || entry.protocol == "https",
                let urlString = entry.url, !urlString.isEmpty,
                let rank = subtitleExtensionRank(entry.ext)
            else { continue }
            if !allowTranslated, isTranslatedCaptionURL(urlString) {
                continue
            }
            if let current = best {
                if rank > current.rank { best = (entry, rank) }
            } else {
                best = (entry, rank)
            }
        }
        return best?.entry
    }

    private static func subtitleExtensionRank(_ ext: String?) -> Int? {
        switch ext?.lowercased() {
        case "ass", "ssa": return 3
        case "vtt": return 2
        case "srt": return 1
        default: return nil
        }
    }

    private static func subtitleFormat(forExtension ext: String?) -> SubtitleFormat {
        switch ext?.lowercased() {
        case "ass", "ssa": return .ass
        default: return .text
        }
    }

    private static func isTranslatedCaptionURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
            let items = components.queryItems
        else { return false }
        return items.contains { $0.name == "tlang" && !($0.value ?? "").isEmpty }
    }

    /// Strips yt-dlp's `-orig` marker and track-specific suffixes (e.g. YouTube's `en-uYU-mmqFLq8` or `en.track1`) to
    /// leave a clean BCP-47 language tag (`en`, `en-US`, `zh-Hans`, `es-419`).
    private static func normalizedSubtitleLanguage(from key: String) -> String? {
        var base = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix("-orig") {
            base = String(base.dropLast("-orig".count))
        }
        if let dot = base.firstIndex(of: ".") {
            base = String(base[..<dot])
        }
        let parts = base.split(separator: "-").map(String.init)
        guard let primary = parts.first,
            (2...3).contains(primary.count),
            primary.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) })
        else {
            return base.isEmpty ? nil : base
        }
        var kept = [primary.lowercased()]
        for subtag in parts.dropFirst() {
            let isLetters = subtag.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            let isDigits = subtag.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
            if subtag.count == 4 && isLetters {
                // Script subtag (e.g. Hans, Hant)
                kept.append(subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased())
            } else if (subtag.count == 2 && isLetters) || (subtag.count == 3 && isDigits) {
                // Region subtag (e.g. US, BR, 419)
                kept.append(subtag.uppercased())
            } else {
                break
            }
        }
        return kept.joined(separator: "-")
    }

    /// The track's name as the page gives it; `nil` without one, for the player to name it by its language.
    private static func subtitleTitle(of entry: SubtitleEntry, isAutoGenerated: Bool) -> String? {
        var name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isAutoGenerated {
            for suffix in [" (Original)", " (original)"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !name.isEmpty else { return nil }
        if isAutoGenerated && !name.lowercased().contains("auto") {
            return "\(name) (auto-generated)"
        }
        return name
    }

    /// The pictures the page offers as files, best first, to play instead of `chosen` (what `-f` picked): progressive
    /// HTTP(S) ones of the same kind (with sound only if it has), the best bitrate for each size, frame rate and codec.
    /// Empty when there is nothing to choose between.
    func otherPictures(like chosen: Format?) -> [VideoFormat] {
        guard let chosen, chosen.hasVideo, chosen.formatID != nil else { return [] }
        let key = { (format: Format) in
            "\(format.width ?? 0)x\(format.height ?? 0)@\(Int((format.fps ?? 0).rounded())) \(Self.pictureCodec(of: format.vcodec))"
        }
        // The chosen one is offered whatever else has its size and codec.
        var best: [String: Format] = [key(chosen): chosen]
        for format in (formats ?? []) where format.formatID != chosen.formatID {
            guard format.hasVideo, format.vcodec != nil, format.hasAudio == chosen.hasAudio, format.url != nil,
                format.protocol == "https" || format.protocol == "http", format.formatID != nil,
                format.width ?? 0 > 0, format.height ?? 0 > 0
            else { continue }
            if let current = best[key(format)],
                current.formatID == chosen.formatID || (current.tbr ?? 0) >= (format.tbr ?? 0)
            {
                continue
            }
            best[key(format)] = format
        }
        let pictures = best.values.compactMap { format -> VideoFormat? in
            guard let url = format.url, let id = format.formatID else { return nil }
            return VideoFormat(
                id: id, url: url, width: format.width ?? 0, height: format.height ?? 0, frameRate: format.fps,
                codec: Self.pictureCodec(of: format.vcodec), bitrate: Int((format.tbr ?? 0) * 1000),
                httpRequestSize: format.downloaderOptions?.httpChunkSize, headers: format.httpHeaders)
        }
        .sorted {
            let (lhs, rhs) = (($0.height, $0.frameRate ?? 0, $0.bitrate), ($1.height, $1.frameRate ?? 0, $1.bitrate))
            return lhs != rhs ? lhs > rhs : $0.id < $1.id
        }
        return pictures.count > 1 ? pictures : []
    }

    /// A video codec string ("av01.0.13M.08") as shown.
    static func pictureCodec(of codec: String?) -> String {
        let family = codec.flatMap { $0.split(separator: ".").first.map { String($0).lowercased() } } ?? ""
        switch family {
        case "av01": return "AV1"
        case "vp9", "vp09": return "VP9"
        case "avc1", "avc3", "h264": return "H.264"
        case "hev1", "hvc1", "hevc": return "HEVC"
        case "vp8": return "VP8"
        default: return family.uppercased()
        }
    }

    /// The page's audio in the languages `chosen` (what `-f` picked) lacks: for each, the highest bitrate over
    /// progressive HTTP in the codec of the chosen one, as `-f` picks. Not the dynamic-range-compressed copies.
    func otherLanguages(than chosen: [Format]) -> [Format] {
        guard let reference = chosen.first(where: { $0.language != nil }) ?? chosen.first else { return [] }
        let codec = Self.codecFamily(of: reference.acodec)
        let seen = Set(chosen.compactMap(\.language))
        let chosenIDs = Set(chosen.compactMap(\.formatID))
        var best: [String: Format] = [:]
        var order: [String] = []
        for format in formats ?? [] {
            guard let language = format.language, !seen.contains(language), format.hasAudio, !format.hasVideo,
                format.url != nil, !chosenIDs.contains(format.formatID ?? ""),
                format.protocol == "https" || format.protocol == "http",
                Self.codecFamily(of: format.acodec) == codec,
                format.formatID?.contains("drc") != true, format.formatNote?.contains("DRC") != true
            else { continue }
            let bitrate = { (format: Format) in format.abr ?? format.tbr ?? 0 }
            if let current = best[language] {
                if bitrate(format) > bitrate(current) { best[language] = format }
            } else {
                best[language] = format
                order.append(language)
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func codecFamily(of codec: String?) -> String {
        codec.flatMap { $0.split(separator: ".").first.map { String($0).lowercased() } } ?? ""
    }

    private static func audioFile(of format: Format, isRequired: Bool) -> MediaLoadRequest.AudioFile? {
        guard let url = format.url.flatMap(URL.init(string:)) else { return nil }
        // FFmpeg's names for the codecs of the formats' codec strings.
        let codecName =
            switch codecFamily(of: format.acodec) {
            case "mp4a": "aac"
            case "ec-3": "eac3"
            case "ac-3": "ac3"
            case let name: name
            }
        return MediaLoadRequest.AudioFile(
            url: url, title: audioTitle(of: format), language: format.language, headers: format.httpHeaders,
            isRequired: isRequired, httpRequestSize: format.downloaderOptions?.httpChunkSize,
            // The one read with the media is opened with it, and tells its streams itself.
            declaredStream: isRequired
                ? nil
                : .init(
                    codecName: codecName, channels: format.audioChannels ?? 2, sampleRate: format.sampleRate ?? 48000))
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
        let note = format.formatNote ?? ""
        if note.contains("original") { return "\(name), original" }
        return note.contains("dubbed") ? "\(name), dubbed" : name
    }
}
