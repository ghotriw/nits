import Foundation

/// Unified parser for playlist formats: M3U/M3U8, PLS, XSPF, and CUE.
public enum PlaylistParser {
    /// Supported playlist extensions.
    public static let supportedExtensions: Set<String> = ["m3u", "m3u8", "pls", "xspf", "cue"]

    /// Checks if a given URL or file extension corresponds to a supported playlist file.
    public static func isPlaylistFile(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Checks if a file path corresponds to a supported playlist file.
    public static func isPlaylistFile(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// Parses playlist content from a local file URL synchronously.
    /// Remote HTTP/HTTPS URLs should be parsed via `parseAsync(url:)` to prevent blocking the calling thread.
    /// - Parameters:
    ///   - url: The file URL of the playlist.
    /// - Returns: An array of `PlaylistItem` extracted from the playlist file.
    public static func parse(url: URL) -> [PlaylistItem] {
        guard url.isFileURL else {
            AppLog.warning(
                .playlist,
                "PlaylistParser.parse(url:) called with remote URL. Use parseAsync(url:) instead to avoid blocking.")
            return []
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }

        let content =
            TextFileEncoding.decode(data)?.text ?? ""

        guard !content.isEmpty else { return [] }

        let ext = url.pathExtension.lowercased()
        return parse(content: content, format: ext, baseURL: url.isFileURL ? url.deletingLastPathComponent() : url)
    }

    /// Asynchronously fetches and parses playlist content from a remote or local URL.
    /// - Parameter url: The URL of the playlist.
    /// - Returns: An array of `PlaylistItem`.
    public static func parseAsync(url: URL) async -> [PlaylistItem] {
        if url.isFileURL {
            return await Task.detached(priority: .userInitiated) {
                parse(url: url)
            }.value
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let content =
                TextFileEncoding.decode(data)?.text ?? ""
            guard !content.isEmpty else { return [] }
            let ext = url.pathExtension.lowercased()
            return parse(content: content, format: ext, baseURL: url)
        } catch {
            return []
        }
    }

    /// Whether a local file is an HLS manifest (read off the caller's thread).
    public static func isHLSManifest(fileAt url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let text = TextFileEncoding.decode(data)?.text else {
                return false
            }
            return isHLSManifest(content: text)
        }.value
    }

    /// Checks if M3U/M3U8 text content represents an HLS stream manifest rather than a track playlist.
    public static func isHLSManifest(content: String) -> Bool {
        var isHLS = false
        content.enumerateLines { line, stop in
            if isHLSTag(line.trimmingCharacters(in: .whitespaces)) {
                isHLS = true
                stop = true
            }
        }
        return isHLS
    }

    private static let hlsTags = [
        "#EXT-X-TARGETDURATION", "#EXT-X-STREAM-INF", "#EXT-X-MEDIA-SEQUENCE", "#EXT-X-VERSION",
    ]

    /// Whether a trimmed M3U line is a tag found only in HLS manifests.
    private static func isHLSTag(_ line: String) -> Bool {
        line.hasPrefix("#EXT-X-") && hlsTags.contains { line.hasPrefix($0) }
    }

    /// Parses playlist content string given a format hint or content auto-detection.
    /// - Parameters:
    ///   - content: Raw text content of the playlist.
    ///   - format: Format hint (e.g. "m3u", "pls", "xspf", "cue"). If nil or empty, format is inferred.
    ///   - baseURL: Base URL for resolving relative file or stream paths.
    /// - Returns: An array of `PlaylistItem`.
    public static func parse(content: String, format: String? = nil, baseURL: URL? = nil) -> [PlaylistItem] {
        let fmt = (format?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        if fmt == "m3u" || fmt == "m3u8" {
            return parseM3U(content: content, baseURL: baseURL)
        } else if fmt == "pls" {
            return parsePLS(content: content, baseURL: baseURL)
        } else if fmt == "xspf" {
            return parseXSPF(content: content, baseURL: baseURL)
        } else if fmt == "cue" {
            return parseCUE(content: content, baseURL: baseURL)
        }

        // Auto-detection fallback
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<?xml") || trimmed.contains("<playlist") {
            return parseXSPF(content: content, baseURL: baseURL)
        } else if trimmed.hasPrefix("[playlist]") || trimmed.lowercased().contains("[playlist]") {
            return parsePLS(content: content, baseURL: baseURL)
        } else if trimmed.contains("FILE ") && trimmed.contains("TRACK ") {
            return parseCUE(content: content, baseURL: baseURL)
        } else {
            return parseM3U(content: content, baseURL: baseURL)
        }
    }

    // MARK: - M3U / M3U8 Parser

    /// Returns no items for an HLS manifest (a single stream, not a track list); detected in the same pass.
    public static func parseM3U(content: String, baseURL: URL?) -> [PlaylistItem] {
        var items: [PlaylistItem] = []
        var pendingTitle: String? = nil
        var pendingDuration: Double? = nil
        var isHLS = false

        content.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            if isHLSTag(trimmed) {
                isHLS = true
                stop = true
            } else if trimmed.hasPrefix("#EXTINF:") {
                // Example: #EXTINF:180,Artist - Track Title
                // Example: #EXTINF:-1 tvg-id="..." group-title="...",Channel Name
                let info = String(trimmed.dropFirst("#EXTINF:".count))
                let parts = info.components(separatedBy: ",")
                if let firstPart = parts.first?.trimmingCharacters(in: .whitespaces) {
                    // Extract duration before space or comma
                    let durationStr = firstPart.components(separatedBy: .whitespaces).first ?? firstPart
                    if let dur = Double(durationStr), dur > 0 {
                        pendingDuration = dur
                    }
                }
                if parts.count > 1 {
                    let titlePart = parts.dropFirst().joined(separator: ",").trimmingCharacters(in: .whitespaces)
                    if !titlePart.isEmpty {
                        pendingTitle = titlePart
                    }
                }
            } else if trimmed.hasPrefix("#") {
                // Ignore other directive comments like #EXTM3U, #EXTVLCOPT, etc.
                return
            } else {
                // Media URI / File Path
                if let itemURL = resolveURL(string: trimmed, baseURL: baseURL) {
                    items.append(
                        PlaylistItem(
                            url: itemURL,
                            title: pendingTitle,
                            duration: pendingDuration,
                            originalIndex: items.count
                        )
                    )
                }
                pendingTitle = nil
                pendingDuration = nil
            }
        }

        return isHLS ? [] : items
    }

    // MARK: - PLS Parser

    public static func parsePLS(content: String, baseURL: URL?) -> [PlaylistItem] {
        var items: [PlaylistItem] = []
        var entries: [Int: (file: String?, title: String?, length: Double?)] = [:]
        var expectedEntries = 0

        // Enumerate lines lazily to avoid holding full split array in memory
        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { return }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { return }
            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            if key == "numberofentries", let n = Int(val), n > 0 {
                expectedEntries = n
                entries.reserveCapacity(n)
            } else if key.hasPrefix("file"), let num = Int(key.dropFirst("file".count)) {
                var entry = entries[num] ?? (nil, nil, nil)
                entry.file = val
                entries[num] = entry
            } else if key.hasPrefix("title"), let num = Int(key.dropFirst("title".count)) {
                var entry = entries[num] ?? (nil, nil, nil)
                entry.title = val
                entries[num] = entry
            } else if key.hasPrefix("length"), let num = Int(key.dropFirst("length".count)) {
                var entry = entries[num] ?? (nil, nil, nil)
                if let len = Double(val), len > 0 {
                    entry.length = len
                }
                entries[num] = entry
            }
        }

        if expectedEntries > 0 {
            items.reserveCapacity(expectedEntries)
        } else {
            items.reserveCapacity(entries.count)
        }

        for index in entries.keys.sorted() {
            guard let entry = entries[index], let fileStr = entry.file, !fileStr.isEmpty else { continue }
            if let itemURL = resolveURL(string: fileStr, baseURL: baseURL) {
                items.append(
                    PlaylistItem(
                        url: itemURL,
                        title: entry.title,
                        duration: entry.length,
                        originalIndex: items.count
                    )
                )
            }
        }

        return items
    }

    // MARK: - XSPF Parser (XML Shareable Playlist Format)

    public static func parseXSPF(content: String, baseURL: URL?) -> [PlaylistItem] {
        guard let data = content.data(using: .utf8) else { return [] }
        let delegate = XSPFParserDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    // MARK: - CUE Parser

    public static func parseCUE(content: String, baseURL: URL?) -> [PlaylistItem] {
        var items: [PlaylistItem] = []
        let lines = content.components(separatedBy: .newlines)

        var currentFile: URL? = nil
        var globalPerformer: String? = nil
        var currentTrackTitle: String? = nil
        var currentTrackPerformer: String? = nil
        var currentTrackStartTime: Double? = nil
        var inTrack = false

        let flushTrack = {
            if inTrack, let file = currentFile {
                var title = currentTrackTitle
                let performer = currentTrackPerformer ?? globalPerformer
                if let p = performer, let t = title, !p.isEmpty {
                    title = "\(p) - \(t)"
                }
                items.append(
                    PlaylistItem(
                        url: file,
                        title: title,
                        startTime: currentTrackStartTime,
                        originalIndex: items.count
                    )
                )
            }
            inTrack = false
            currentTrackTitle = nil
            currentTrackPerformer = nil
            currentTrackStartTime = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("FILE ") {
                flushTrack()
                currentFile = parseCUEFileName(from: trimmed, baseURL: baseURL)
            } else if trimmed.hasPrefix("TRACK ") {
                flushTrack()
                inTrack = true
            } else if trimmed.hasPrefix("INDEX 01 ") || trimmed == "INDEX 01" {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 3 {
                    currentTrackStartTime = parseCUETimestamp(parts[2])
                }
            } else if trimmed.hasPrefix("PERFORMER ") {
                let name = parseCUEQuotedValue(from: trimmed, prefix: "PERFORMER")
                if inTrack {
                    currentTrackPerformer = name
                } else {
                    globalPerformer = name
                }
            } else if trimmed.hasPrefix("TITLE ") {
                let title = parseCUEQuotedValue(from: trimmed, prefix: "TITLE")
                if inTrack {
                    currentTrackTitle = title
                }
            }
        }

        flushTrack()

        // If no tracks were found but file was present, add file itself
        if items.isEmpty, let file = currentFile {
            items.append(
                PlaylistItem(
                    url: file,
                    title: nil,
                    originalIndex: items.count
                )
            )
        } else {
            // Compute durations between sequential tracks of the same audio file
            for i in 0..<items.count {
                guard let start = items[i].startTime else { continue }
                if i + 1 < items.count,
                    items[i + 1].url == items[i].url,
                    let nextStart = items[i + 1].startTime,
                    nextStart > start
                {
                    items[i].duration = nextStart - start
                }
            }
        }

        return items
    }

    // MARK: - Helper Methods

    /// Never touches the file system: playlists often list thousands of files on network volumes,
    /// where the directory check `URL(fileURLWithPath:)` makes per path costs milliseconds each.
    static func resolveURL(string: String, baseURL: URL?) -> URL? {
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // Check if string is an absolute network URL
        if clean.lowercased().hasPrefix("http://")
            || clean.lowercased().hasPrefix("https://")
            || clean.lowercased().hasPrefix("rtmp://")
            || clean.lowercased().hasPrefix("rtsp://")
            || clean.lowercased().hasPrefix("mms://")
        {
            return URL(string: clean)
        }

        // Check file:// URL scheme
        if clean.lowercased().hasPrefix("file://") {
            if let parsedURL = URL(string: clean) {
                return parsedURL.standardizedFileURL
            }
            var stripped = String(clean.dropFirst("file://".count))
            // `file://localhost/path` names the same file as `file:///path`.
            if stripped.lowercased().hasPrefix("localhost/") {
                stripped.removeFirst("localhost".count)
            }
            let decoded = stripped.removingPercentEncoding ?? stripped
            return URL(filePath: decoded, directoryHint: .inferFromPath).standardizedFileURL
        }

        // Check absolute file path
        if clean.hasPrefix("/") {
            let decoded = clean.removingPercentEncoding ?? clean
            return URL(filePath: decoded, directoryHint: .inferFromPath).standardizedFileURL
        }

        // Relative path: resolve against baseURL
        if let baseURL {
            if baseURL.isFileURL {
                let isFileWithExtension = !baseURL.pathExtension.isEmpty
                let dirURL = isFileWithExtension ? baseURL.deletingLastPathComponent() : baseURL
                let decoded = clean.removingPercentEncoding ?? clean
                return dirURL.appending(path: decoded, directoryHint: .inferFromPath).standardizedFileURL
            } else {
                // For remote network URLs, strip query/fragment to accurately determine directory path
                let rawPath = baseURL.path
                let isFile =
                    !rawPath.isEmpty && !rawPath.hasSuffix("/") && (rawPath as NSString).pathExtension.isEmpty == false
                let dirURL: URL
                if isFile {
                    dirURL = baseURL.deletingLastPathComponent()
                } else if !baseURL.absoluteString.hasSuffix("/") {
                    dirURL = baseURL.appendingPathComponent("")
                } else {
                    dirURL = baseURL
                }
                return URL(string: clean, relativeTo: dirURL)?.absoluteURL.standardized
            }
        }

        let decoded = clean.removingPercentEncoding ?? clean
        return URL(filePath: decoded, directoryHint: .inferFromPath).standardizedFileURL
    }

    private static func parseCUEFileName(from line: String, baseURL: URL?) -> URL? {
        let afterFile = line.dropFirst("FILE ".count).trimmingCharacters(in: .whitespaces)
        if afterFile.hasPrefix("\"") {
            let components = afterFile.components(separatedBy: "\"")
            if components.count >= 2 {
                let filename = components[1]
                return resolveURL(string: filename, baseURL: baseURL)
            }
        } else {
            let filename = afterFile.components(separatedBy: .whitespaces).first ?? afterFile
            return resolveURL(string: filename, baseURL: baseURL)
        }
        return nil
    }

    private static func parseCUEQuotedValue(from line: String, prefix: String) -> String {
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") && rest.hasSuffix("\"") && rest.count >= 2 {
            return String(rest.dropFirst().dropLast())
        }
        return rest
    }

    /// Converts CUE timestamp format (mm:ss:ff, where ff is frames 1/75th sec) into seconds.
    private static func parseCUETimestamp(_ str: String) -> Double? {
        let parts = str.components(separatedBy: ":")
        guard parts.count == 3,
            let minutes = Double(parts[0]),
            let seconds = Double(parts[1]),
            let frames = Double(parts[2])
        else {
            return nil
        }
        return minutes * 60.0 + seconds + (frames / 75.0)
    }
}

// MARK: - XSPF XML Parser Delegate

private final class XSPFParserDelegate: NSObject, XMLParserDelegate {
    var items: [PlaylistItem] = []
    let baseURL: URL?

    private var currentElement: String = ""
    private var currentText: String = ""
    private var inTrack: Bool = false

    private var trackLocation: String? = nil
    private var trackTitle: String? = nil
    private var trackCreator: String? = nil
    private var trackDuration: Double? = nil

    init(baseURL: URL?) {
        self.baseURL = baseURL
        super.init()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        currentText = ""
        if currentElement == "track" {
            inTrack = true
            trackLocation = nil
            trackTitle = nil
            trackCreator = nil
            trackDuration = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inTrack {
            switch element {
            case "location":
                trackLocation = text
            case "title":
                trackTitle = text
            case "creator":
                trackCreator = text
            case "duration":
                // XSPF duration is in milliseconds
                if let ms = Double(text), ms > 0 {
                    trackDuration = ms / 1000.0
                }
            case "track":
                if let loc = trackLocation, !loc.isEmpty {
                    if let url = PlaylistParser.resolveURL(string: loc, baseURL: baseURL) {
                        var title = trackTitle
                        if let creator = trackCreator, let t = title, !creator.isEmpty {
                            title = "\(creator) - \(t)"
                        }
                        items.append(
                            PlaylistItem(
                                url: url,
                                title: title,
                                duration: trackDuration,
                                originalIndex: items.count
                            )
                        )
                    }
                }
                inTrack = false
            default:
                break
            }
        }
    }
}
