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

    /// - Parameters:
    ///   - customPath: The yt-dlp to run in place of the one found on the system (empty: search for it).
    ///   - sponsorBlock: Whether YouTube videos get SponsorBlock's skip buttons and chapters.
    public convenience init(customPath: String = "", sponsorBlock: Bool = true) {
        self.init(
            locator: YTDLPLocator(customPath: customPath), sponsorBlock: sponsorBlock ? SponsorBlockClient() : nil)
    }

    init(locator: YTDLPLocator, timeout: Duration = .seconds(60), sponsorBlock: SponsorBlockClient? = nil) {
        self.locator = locator
        self.timeout = timeout
        self.sponsorBlock = sponsorBlock
    }

    /// Asks for the streams `-f` picks: the best picture and audio over progressive HTTP (what YouTube gives as
    /// separate files), else a muxed one, else HLS (live). Not DASH manifests or fragments: `YTDLPInfo.isPlayable`.
    static let formatSelector: String = {
        let progressive = "[protocol^=http][protocol!*=dash]"
        let hls = "[protocol^=m3u8]"
        return ["bv*\(progressive)+ba\(progressive)", "b\(progressive)", "b\(hls)", "bv*\(hls)+ba\(hls)"]
            .joined(separator: "/")
    }()

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

    static func arguments(for url: URL, headers: [String: String]) -> [String] {
        var arguments = ["--dump-single-json", "--no-playlist", "--flat-playlist", "--no-warnings"]
        arguments += ["-f", formatSelector]
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
            executable, arguments: Self.arguments(for: url, headers: headers),
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
        let resolved = try info.resolvedMedia(for: url, sponsorBlock: segments)
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
