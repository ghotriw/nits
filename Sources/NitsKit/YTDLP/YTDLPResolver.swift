import Foundation
import NitsCore

extension LogCategory {
    static let ytdlp: LogCategory = "yt-dlp"
}

/// Plays the pages of video sites through the yt-dlp installed on the system (`YTDLPLocator`), as mpv and IINA do. As
/// in mpv, it is asked first for the sites known to have pages (`pageSites`), and for other network URLs only once
/// they failed to open as media: a media server's stream doesn't wait for it (seconds) or fail on its errors. Those it
/// finds no page in (`Unsupported URL`, a stream itself) open as they are. Without yt-dlp installed, nothing is
/// resolved.
public final class YTDLPResolver: MediaResolver {
    let locator: YTDLPLocator
    /// How long yt-dlp may take on a page (a slow site, a network that doesn't answer); the load fails after it.
    let timeout: Duration
    /// Asks SponsorBlock for a YouTube video's segments to skip (sponsors, intros, …) and chapters; `nil`: none.
    let sponsorBlock: SponsorBlockClient?
    /// Whether a YouTube live stream (or premiere on the air) plays from its history (`YouTubeLiveHistory`: a day of it, the broadcaster
    /// allowing) in place of its HLS playlist (an hour at most). The app's setting (`AppSettings.liveHistory`, on);
    /// off here by default, for the callers that read no live window (tests).
    let liveHistory: Bool
    /// How the history's server is asked; the system's network but in tests.
    let liveHistoryFetch: YouTubeLiveHistory.Fetch
    /// How long a segment past the head is waited for before the head is asked again (`LiveSegmentSource`), and how that
    /// is asked: the system's network but in tests.
    let liveSegmentWaitLimit: Duration
    let liveHeadRequest: YouTubeLiveSource.HeadRequest
    /// How long before the signature expires it is renewed, seconds.
    let liveRefreshMargin: Double

    /// - Parameters:
    ///   - customPath: The yt-dlp to run in place of the one found on the system (empty: search for it).
    ///   - sponsorBlock: Whether YouTube videos get SponsorBlock's skip buttons and chapters.
    ///   - liveHistory: Whether a YouTube live stream plays from its history, not just its last hour.
    public convenience init(customPath: String = "", sponsorBlock: Bool = true, liveHistory: Bool = false) {
        self.init(
            locator: YTDLPLocator(customPath: customPath), sponsorBlock: sponsorBlock ? SponsorBlockClient() : nil,
            liveHistory: liveHistory)
    }

    init(
        locator: YTDLPLocator, timeout: Duration = .seconds(60), sponsorBlock: SponsorBlockClient? = nil,
        liveHistory: Bool = false, liveHistoryFetch: @escaping YouTubeLiveHistory.Fetch = YouTubeLiveHistory.urlSession,
        liveSegmentWaitLimit: Duration = .seconds(60),
        liveHeadRequest: @escaping YouTubeLiveSource.HeadRequest = YouTubeLiveSource.urlSessionHead,
        liveRefreshMargin: Double = 1800
    ) {
        self.locator = locator
        self.timeout = timeout
        self.sponsorBlock = sponsorBlock
        self.liveHistory = liveHistory
        self.liveHistoryFetch = liveHistoryFetch
        self.liveSegmentWaitLimit = liveSegmentWaitLimit
        self.liveHeadRequest = liveHeadRequest
        self.liveRefreshMargin = liveRefreshMargin
    }

    /// yt-dlp asked for a live stream's page again, as the history was made from it: what the source asks it for after the
    /// load (a renewed signature, whether the stream is over).
    private func liveInfo(of page: URL, headers: [String: String]) async throws -> YTDLPInfo {
        guard let executable = locator.executable() else { throw MediaResolutionError("yt-dlp is gone") }
        let output = try await YTDLPProcess.run(
            executable, arguments: Self.arguments(for: page, headers: headers, liveHistory: true),
            path: locator.processPath(for: executable), timeout: timeout)
        guard output.status == 0 else { throw Self.error(in: output.stderr) }
        return try JSONDecoder().decode(YTDLPInfo.self, from: output.stdout)
    }

    /// Whether yt-dlp, asked for the page again, says the stream is no longer on the air: what `YouTubeLiveSource` decides
    /// the end of a stream by when its head stood still. An error is no answer (thrown), not an end.
    func liveStreamIsOver(page: URL, headers: [String: String]) async throws -> Bool {
        let info = try await liveInfo(of: page, headers: headers)
        guard let isLive = info.isLive else {
            throw MediaResolutionError("yt-dlp does not say if the stream is on the air")
        }
        return !isLive
    }

    /// New signed addresses of a live stream's streams, `keys` the ids of their formats, from yt-dlp asked for the page
    /// again: what `YouTubeLiveSource` renews them with. The manifest does not change, only the signature of what it names.
    func liveSegmentURLs(of page: URL, headers: [String: String], keys: Set<String>) async throws -> [String: String] {
        let info = try await liveInfo(of: page, headers: headers)
        var urls: [String: String] = [:]
        for format in info.formats ?? [] {
            guard let id = format.formatID, keys.contains(id), format.protocol == "https",
                let url = format.url, YTDLPInfo.isBroadcastSegment(url: url)
            else { continue }
            urls[id] = url
        }
        guard Set(urls.keys) == keys else {
            throw MediaResolutionError("The live stream's formats are no longer those it was made of")
        }
        return urls
    }

    /// Asks for the streams `-f` picks: the best picture and audio over progressive HTTP (what YouTube gives as
    /// separate files), else a muxed one, else HLS (live), else segments of one URL (a live stream's recording YouTube
    /// has not turned into files yet: `YTDLPInfo.isSegmented`). Not DASH manifests: `YTDLPInfo.isPlayable`.
    static let formatSelector: String = {
        let progressive = "[protocol^=http][protocol!*=dash]"
        let hls = "[protocol^=m3u8]"
        let segments = "[protocol=\(YTDLPInfo.segmentedProtocol)]"
        return [
            "bv*\(progressive)+ba\(progressive)", "b\(progressive)", "b\(hls)", "bv*\(hls)+ba\(hls)",
            "bv*\(segments)+ba\(segments)",
        ]
        .joined(separator: "/")
    }()

    /// Asked first when a live stream's history is wanted: the adaptive formats of a live stream, which yt-dlp marks
    /// "incomplete" (no other page has one), in MP4 and H.264: the segments' start times are read from their `moof`
    /// (`FragmentStartTime`; a WebM's clusters have none), and what the Mac decodes in hardware at any size and frame
    /// rate. A stream without them falls through to `formatSelector`'s (its HLS playlist).
    static let liveHistorySelector =
        "bv*[format_note*=incomplete][ext=mp4][vcodec^=avc1]+ba[format_note*=incomplete][ext=m4a]"

    /// Extensions of media and playlists, which open without asking yt-dlp.
    static let mediaExtensions = PlaylistManager.supportedExtensions.union(["mpd", "ism", "f4m"])

    /// Sites whose URLs are pages, resolved before they open (mpv's `include`, and a few more); their subdomains too.
    static let pageSites = [
        "youtube.com", "youtu.be", "youtube-nocookie.com", "twitch.tv", "vimeo.com", "dailymotion.com",
        "soundcloud.com",
    ]

    static func isPageSite(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return pageSites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func order(for url: URL) -> MediaResolutionOrder? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard !Self.mediaExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard locator.executable() != nil else { return nil }
        return Self.isPageSite(url) ? .beforeOpening : .afterOpeningFails
    }

    /// The id of the YouTube video `url` is a page of (`watch?v=`, `youtu.be/`, `/shorts/`, `/embed/`, `/live/`), to
    /// ask SponsorBlock while yt-dlp runs; `nil` for other pages.
    static func youTubeVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        let id: String?
        if host == "youtu.be" {
            id = path.first
        } else if ["youtube.com", "youtube-nocookie.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            if path.first == "watch" {
                id =
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "v" })?.value
            } else if path.count >= 2, ["shorts", "embed", "live", "v"].contains(path[0]) {
                id = path[1]
            } else {
                id = nil
            }
        } else {
            id = nil
        }
        // 11 characters of base64url.
        guard let id, id.count == 11,
            id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        else { return nil }
        return id
    }

    private static func segments(
        from sponsorBlock: SponsorBlockClient?, for videoID: String?
    ) async -> [SponsorBlockSegment] {
        guard let sponsorBlock, let videoID else { return [] }
        return await sponsorBlock.segments(for: videoID)
    }

    static func arguments(for url: URL, headers: [String: String], liveHistory: Bool = false) -> [String] {
        var arguments = ["--dump-single-json", "--no-playlist", "--flat-playlist", "--no-warnings"]
        arguments += ["-f", liveHistory ? liveHistorySelector + "/" + formatSelector : formatSelector]
        // Lists a live stream's adaptive formats (numbered segments of one URL), which yt-dlp leaves out as incomplete:
        // it adds no format to any other page.
        if liveHistory { arguments += ["--extractor-args", "youtube:formats=incomplete"] }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            arguments += ["--add-headers", "\(name):\(value)"]
        }
        return arguments + ["--", url.absoluteString]
    }

    public func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
        guard let executable = locator.executable() else { return nil }
        let started = ContinuousClock.now
        // SponsorBlock answers while yt-dlp runs, which takes longer.
        let sponsorBlock = sponsorBlock
        let pageVideoID = sponsorBlock != nil ? Self.youTubeVideoID(from: url) : nil
        async let pageSegments = Self.segments(from: sponsorBlock, for: pageVideoID)

        let output = try await YTDLPProcess.run(
            executable, arguments: Self.arguments(for: url, headers: headers, liveHistory: liveHistory),
            path: locator.processPath(for: executable), timeout: timeout)
        let elapsed = ContinuousClock.now - started
        guard output.status == 0 else {
            let error = Self.error(in: output.stderr)
            if error.message.hasPrefix("Unsupported URL") {
                AppLog.info(.ytdlp, "No page in \(url.absoluteString) (\(elapsed)): opening it as it is")
                return nil
            }
            AppLog.warning(.ytdlp, "\(url.absoluteString): \(error.message)")
            throw error
        }
        let info: YTDLPInfo
        do {
            info = try JSONDecoder().decode(YTDLPInfo.self, from: output.stdout)
        } catch {
            throw MediaResolutionError(
                "yt-dlp answered what Nits can't read: \(error.localizedDescription)", isAboutPage: false)
        }
        var segments = await pageSegments
        // A YouTube page whose URL doesn't name the video (a channel's live page) is asked once yt-dlp tells its id.
        if info.extractorKey == "Youtube", let id = info.id, id != pageVideoID {
            segments = await Self.segments(from: sponsorBlock, for: id)
        }
        var chosen = info
        var history: YouTubeLiveHistory.Window?
        // Incomplete formats that are not a history (not on the air by the page's word, not a broadcast's segments) are
        // no stream either: the server ends them. The HLS playlist, if the page has one.
        if liveHistory, info.liveHistoryFormats() == nil, info.choseIncompleteFormats {
            guard let hls = info.choosingHLS() else {
                throw MediaResolutionError("The live stream has neither a history nor a playlist that plays")
            }
            AppLog.warning(.ytdlp, "\(url.absoluteString): incomplete formats chosen that are no live history: its HLS")
            chosen = hls
        }
        if liveHistory, let formats = info.liveHistoryFormats() {
            let historyStarted = ContinuousClock.now
            do {
                let streamHeaders = formats.first?.httpHeaders ?? info.httpHeaders ?? [:]
                var window = try await YouTubeLiveHistory.window(
                    of: info.segmentStreams(of: formats), headers: streamHeaders, fetch: liveHistoryFetch)
                // The manifest names the streams by keys; the addresses are the source's, which renews them.
                let keys = Set(window.signedURLs.keys)
                window.source = YouTubeLiveSource(
                    urls: window.signedURLs, headers: streamHeaders, segmentWaitLimit: liveSegmentWaitLimit,
                    refreshMargin: liveRefreshMargin,
                    renew: { [self] in try await liveSegmentURLs(of: url, headers: headers, keys: keys) },
                    isOver: { [self] in try await liveStreamIsOver(page: url, headers: headers) },
                    headRequest: liveHeadRequest)
                history = window
                AppLog.info(
                    .ytdlp,
                    "\(url.absoluteString): live history of segments \(window.firstNumber)...\(window.lastNumber), "
                        + "\(Int(window.lastStartTime - window.startTime)) s, in \(ContinuousClock.now - historyStarted) "
                        + "after yt-dlp's \(elapsed): \(window.timings)")
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                // The adaptive formats are no stream by themselves (the server ends them): the HLS playlist plays.
                AppLog.warning(.ytdlp, "\(url.absoluteString): no live history (\(error)): playing its HLS playlist")
                guard let hls = info.choosingHLS() else {
                    throw MediaResolutionError("The live stream's history can't be read (\(error))")
                }
                chosen = hls
            }
        }
        let resolved = try chosen.resolvedMedia(for: url, sponsorBlock: segments, liveHistory: history)
        AppLog.info(
            .ytdlp,
            "\(url.absoluteString) in \(elapsed): "
                + (resolved.map { "\(1 + $0.audioFiles.count) stream(s), \($0.historyKey ?? "no id")" }
                    ?? "media itself"))
        return resolved
    }

    /// yt-dlp's reason for failing, from its last `ERROR:` line, without the extractor and id it starts with
    /// ("ERROR: [youtube] dQw4w9WgXcQ: Video unavailable"). About the page (`isAboutPage`) when an extractor of a site
    /// tells it, or yt-dlp itself, without one, once it read the page ("Requested format is not available": a page
    /// with only DASH); not the generic extractor's ("[generic] stream: Unable to download webpage: HTTP Error 404"),
    /// which is only about reading the URL, nor what isn't an `ERROR:` line (a traceback, nothing).
    static func error(in stderr: Data) -> MediaResolutionError {
        let lines = String(decoding: stderr, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard
            var message = lines.last(where: { $0.hasPrefix("ERROR:") }).map(String.init) ?? lines.last.map(String.init)
        else { return MediaResolutionError("yt-dlp failed", isAboutPage: false) }
        let isReported = message.hasPrefix("ERROR:")
        if isReported { message = String(message.dropFirst("ERROR:".count)) }
        message = message.trimmingCharacters(in: .whitespaces)
        var extractor: String?
        if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
            extractor = String(message[message.index(after: message.startIndex)..<close]).lowercased()
            var rest = message[message.index(after: close)...].drop { $0 == " " }
            // The id, before its colon (an id has no spaces).
            if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains(" ") {
                rest = rest[rest.index(after: colon)...].drop { $0 == " " }
            }
            message = String(rest)
        }
        return MediaResolutionError(
            message.isEmpty ? "yt-dlp failed" : message, isAboutPage: extractor.map { $0 != "generic" } ?? isReported)
    }
}
