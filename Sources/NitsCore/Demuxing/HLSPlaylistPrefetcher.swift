import Foundation
import os

/// Downloads, side by side, what FFmpeg's HLS demuxer reads one request after another while it opens a master
/// playlist: every media playlist it lists, then the start of each one's first segment (and of its init section).
/// FFmpeg probes every playlist before it plays anything. Apple's AV1 example lists 36 (23 of them probed, at two
/// requests each on a connection of its own): it opened in 54 s on a cold CDN cache (answers after half a second to
/// most of a second) and in 12 s on a warm one. The demuxer's `io_open` serves FFmpeg what was downloaded here
/// (`take`, `FFmpegIOByteCounter`); what wasn't, or was redirected or failed, FFmpeg opens as before.
///
/// The master is downloaded here too (FFmpeg reads it again: a small file), and URIs are resolved against where each
/// playlist was served from, as FFmpeg does. A URI resolved otherwise than by FFmpeg only misses, as does a segment
/// FFmpeg starts elsewhere (`EXT-X-START`). Byte ranges (`EXT-X-BYTERANGE`, a variant in one file, as in Apple's
/// fragmented MP4 examples) are fetched from their offset; encrypted segments aren't fetched.
final class HLSPlaylistPrefetcher: Sendable {
    /// A download: a whole file, or bytes of one from an offset.
    struct Download: Sendable {
        let data: Data
        /// The file's size, when the server told it.
        let fileSize: Int64?
    }

    /// An input FFmpeg's probe opens: a file, or a byte range of one from `offset` (`length` long).
    struct Input: Equatable {
        let uri: String
        var offset: Int64 = 0
        var length: Int64?
    }

    private enum Entry {
        case pending
        case done(Download?)
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var isMasterRead = false
        var isCancelled = false
    }

    /// Bytes of a segment downloaded: FFmpeg's probe reads up to some 40 KB of a segment, an init section less.
    static let segmentStart = 128 << 10

    private let masterURL: URL
    private let headers: [String: String]
    private let session: URLSession
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Signalled when a download ends, for the one thread that waits in `take` (FFmpeg's, opening the input).
    private let changed = DispatchSemaphore(value: 0)

    /// `headers` are the source's HTTP headers (the user agent among them), sent with every request.
    init(masterURL: URL, headers: [String: String]) {
        self.masterURL = masterURL
        self.headers = headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // An HTTP/1.1 server (Apple's CDN) answers a request per connection at a time: 6, the default, took six
        // rounds of answers for 36 playlists.
        configuration.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    /// Whether `url` is worth prefetching for: an HTTP(S) `.m3u8` / `.m3u`.
    static func applies(to url: String) -> Bool {
        guard MediaURL.isNetworkURL(url), let parsed = URL(string: url) else { return false }
        return ["m3u8", "m3u"].contains(parsed.pathExtension.lowercased())
    }

    /// Downloads the master, then every media playlist it lists, then their segments' starts, each as soon as it can.
    ///
    /// On the session's own queue, through completion handlers, not tasks: the demuxer opens synchronously, often
    /// from a task, and waits in `take` with its thread; downloads needing the cooperative pool could wait for it in
    /// turn (they did, in a full test run).
    func start() {
        download(masterURL, range: nil) { [self] master in
            guard let master, master.servedFrom.absoluteString == masterURL.absoluteString,
                let text = String(data: master.download.data, encoding: .utf8)
            else {
                finishMaster(registering: [])
                return
            }
            let playlists = Self.mediaPlaylists(in: text).compactMap { playlist in
                URL(string: playlist.uri, relativeTo: masterURL).map { (url: $0.absoluteURL, playlist.isSubtitles) }
            }
            let registered = finishMaster(registering: playlists.map(\.url))
            for (url, isSubtitles) in playlists where registered.contains(url) {
                fetchPlaylist(url, segments: !isSubtitles)
            }
        }
    }

    /// What was downloaded for `url` from `offset`, once; waits for its download while `shouldWait` holds. Nil when
    /// it isn't one fetched here, or its download failed: FFmpeg then opens it itself.
    func take(_ url: String, offset: Int64, shouldWait: () -> Bool) -> Download? {
        // FFmpeg reads the master itself, alongside: waiting for this download would only put it after.
        guard url != masterURL.absoluteString else { return nil }
        let key = Self.key(url, offset)
        while true {
            let found = state.withLock { state -> Entry in
                switch state.entries[key] {
                case .done(let download):
                    state.entries[key] = nil
                    return .done(download)
                case .pending:
                    return .pending
                case nil:
                    // Before the master is read, its playlists aren't known.
                    return state.isMasterRead || state.isCancelled ? .done(nil) : .pending
                }
            }
            switch found {
            case .done(let download): return download
            case .pending:
                guard shouldWait() else { return nil }
                // Signalled as each download ends; the timeout checks `shouldWait` again (a cancelled load).
                _ = changed.wait(timeout: .now() + .milliseconds(50))
            }
        }
    }

    /// FFmpeg opened the input: what is left isn't needed.
    func cancel() {
        state.withLock {
            $0.isCancelled = true
            $0.entries.removeAll()
        }
        session.invalidateAndCancel()
    }

    private static func key(_ url: String, _ offset: Int64) -> String {
        offset == 0 ? url : "\(url) @\(offset)"
    }

    /// Registers the master's playlists as pending; the ones new, unless cancelled.
    @discardableResult
    private func finishMaster(registering urls: [URL]) -> Set<URL> {
        defer { changed.signal() }
        return state.withLock { state in
            state.isMasterRead = true
            guard !state.isCancelled else { return [] }
            let new = urls.filter { state.entries[$0.absoluteString] == nil }
            for url in new { state.entries[url.absoluteString] = .pending }
            return Set(new)
        }
    }

    /// Downloads a media playlist, then (`segments`) the start of the segment FFmpeg probes and of its init section,
    /// registered before the playlist is handed out: FFmpeg asks for them once it has read it.
    private func fetchPlaylist(_ url: URL, segments: Bool) {
        download(url, range: nil) { [self] downloaded in
            // Served from elsewhere, the playlist's segments resolve against that place, which FFmpeg reading it from
            // memory wouldn't know: it reads that one itself.
            let playlist = downloaded.flatMap {
                $0.servedFrom.absoluteString == url.absoluteString ? $0.download : nil
            }
            let starts =
                segments
                ? playlist.flatMap { String(data: $0.data, encoding: .utf8) }.map { Self.probedInputs(in: $0) } ?? []
                : []
            let fetched = state.withLock { state -> [(url: URL, input: Input)] in
                guard !state.isCancelled else { return [] }
                let new = starts.compactMap { input in
                    URL(string: input.uri, relativeTo: url).map { (url: $0.absoluteURL, input: input) }
                }.filter { state.entries[Self.key($0.url.absoluteString, $0.input.offset)] == nil }
                for start in new { state.entries[Self.key(start.url.absoluteString, start.input.offset)] = .pending }
                state.entries[url.absoluteString] = .done(playlist)
                return new
            }
            changed.signal()
            for (start, input) in fetched {
                let length = min(input.length ?? Int64(Self.segmentStart), Int64(Self.segmentStart))
                download(start, range: input.offset..<(input.offset + length)) { [self] downloaded in
                    let data = downloaded.flatMap {
                        $0.servedFrom.absoluteString == start.absoluteString ? $0.download : nil
                    }
                    state.withLock { state in
                        if !state.isCancelled {
                            state.entries[Self.key(start.absoluteString, input.offset)] = .done(data)
                        }
                    }
                    changed.signal()
                }
            }
        }
    }

    /// `url`, its bytes in `range` when given, and where it was served from: nil when it failed.
    private func download(
        _ url: URL, range: Range<Int64>?,
        completion: @escaping @Sendable ((download: Download, servedFrom: URL)?) -> Void
    ) {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        }
        session.dataTask(with: request) { data, response, _ in
            completion(data.flatMap { Self.download(of: $0, answering: response, range: range) })
        }.resume()
    }

    private static func download(of data: Data, answering response: URLResponse?, range: Range<Int64>?) -> (
        download: Download, servedFrom: URL
    )? {
        guard let http = response as? HTTPURLResponse, let servedFrom = http.url else { return nil }
        switch http.statusCode {
        case 200:
            // The whole file, for a range from its start too (the server ignored it).
            guard (range?.lowerBound ?? 0) == 0 else { return nil }
            return (Download(data: data, fileSize: Int64(data.count)), servedFrom)
        case 206:
            // `bytes 0-131071/12000000`: from the offset asked for, the size after the slash (`*` when unknown).
            guard let range, let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                contentRange.hasPrefix("bytes \(range.lowerBound)-")
            else { return nil }
            // Less than asked for ends the file.
            let fileSize =
                contentRange.split(separator: "/").last.flatMap { Int64($0) }
                ?? (Int64(data.count) < Int64(range.count) ? range.lowerBound + Int64(data.count) : nil)
            return (Download(data: data, fileSize: fileSize), servedFrom)
        default:
            return nil
        }
    }

    /// The playlists a master playlist lists: a variant's (the line after `EXT-X-STREAM-INF`) and a rendition's
    /// (`EXT-X-MEDIA`'s `URI`), and whether it is of subtitles, which FFmpeg doesn't probe. I-frame playlists FFmpeg
    /// doesn't read.
    static func mediaPlaylists(in text: String) -> [(uri: String, isSubtitles: Bool)] {
        var playlists: [(uri: String, isSubtitles: Bool)] = []
        var expectsVariant = false
        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                expectsVariant = true
            } else if line.hasPrefix("#EXT-X-MEDIA:"), let uri = attribute("URI", of: line) {
                playlists.append((uri, attribute("TYPE", of: line) == "SUBTITLES"))
            } else if expectsVariant, !line.isEmpty, !line.hasPrefix("#") {
                playlists.append((line, false))
                expectsVariant = false
            }
        }
        return playlists
    }

    /// What FFmpeg's probe of a media playlist opens: its init section (`EXT-X-MAP`) and the segment it starts from,
    /// the first of a finished playlist, the third from the end of a live one (`live_start_index`). Byte ranges are
    /// placed as FFmpeg places them: a range without an offset follows the one before (`parse_playlist`). None when
    /// segments are encrypted.
    static func probedInputs(in text: String) -> [Input] {
        var initSection: Input?
        var segments: [Input] = []
        var isFinished = false
        var next: (offset: Int64, length: Int64?) = (0, nil)
        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                guard let range = byteRange(line.dropFirst("#EXT-X-BYTERANGE:".count)) else { return [] }
                next = (range.offset ?? next.offset, range.length)
            } else if line.hasPrefix("#EXT-X-KEY:"), attribute("METHOD", of: line) != "NONE" {
                return []
            } else if line.hasPrefix("#EXT-X-MAP:") {
                guard segments.isEmpty, let uri = attribute("URI", of: line) else { continue }
                if let attribute = attribute("BYTERANGE", of: line) {
                    guard let range = byteRange(Substring(attribute)) else { return [] }
                    initSection = Input(uri: uri, offset: range.offset ?? 0, length: range.length)
                } else {
                    initSection = Input(uri: uri)
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                isFinished = true
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if let length = next.length {
                    segments.append(Input(uri: line, offset: next.offset, length: length))
                    next = (next.offset + length, nil)
                } else {
                    segments.append(Input(uri: line))
                    next = (0, nil)
                }
            }
        }
        guard !segments.isEmpty else { return [] }
        let first = isFinished ? 0 : max(segments.count - 3, 0)
        return (initSection.map { [$0] } ?? []) + [segments[first]]
    }

    /// `length[@offset]`.
    private static func byteRange(_ text: Substring) -> (length: Int64, offset: Int64?)? {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard let length = Int64(parts[0]), length >= 0, parts.count <= 2 else { return nil }
        guard parts.count == 2 else { return (length, nil) }
        guard let offset = Int64(parts[1]), offset >= 0 else { return nil }
        return (length, offset)
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The value of `name` in a tag's attribute list (`NAME=value` or `NAME="value"`).
    private static func attribute(_ name: String, of line: String) -> String? {
        guard let range = line.range(of: name + "=") else { return nil }
        let before = line[..<range.lowerBound].last
        guard before == ":" || before == "," else { return nil }
        let rest = line[range.upperBound...]
        if rest.first == "\"" {
            let value = rest.dropFirst()
            return value.firstIndex(of: "\"").map { String(value[..<$0]) }
        }
        return String(rest.prefix { $0 != "," })
    }
}
