import Foundation
import NitsCore
import Testing

@testable import NitsKit

/// yt-dlp's answers read into streams, and yt-dlp found and run; a script stands in for it.
@Suite("yt-dlp resolver")
struct YTDLPResolverTests {
    static let page = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!
    static let headers = #"{"User-Agent": "Mozilla/5.0", "Accept-Language": "en-us,en;q=0.5"}"#

    /// A page's answer with a picture and its audio as separate HTTPS files, as YouTube's.
    static let separateStreams = """
        {"_type": "video", "id": "aqz-KE-bpKQ", "title": "Big Buck Bunny", "extractor_key": "Youtube",
         "requested_formats": [
           {"url": "https://media.example/video", "protocol": "https", "vcodec": "av01.0.13M.08", "acodec": "none",
            "http_headers": \(headers)},
           {"url": "https://media.example/audio", "protocol": "https", "vcodec": "none", "acodec": "opus",
            "language": "en", "format_note": "English (US) original (default), medium", "http_headers": \(headers)}
         ]}
        """

    private func info(_ json: String) throws -> YTDLPInfo {
        try JSONDecoder().decode(YTDLPInfo.self, from: Data(json.utf8))
    }

    @Test("A picture and its audio in separate files play as the media and an audio file of it, named by the page")
    func readsSeparateStreams() throws {
        let resolved = try #require(try info(Self.separateStreams).resolvedMedia(for: Self.page))
        #expect(resolved.path == "https://media.example/video")
        #expect(resolved.headers["User-Agent"] == "Mozilla/5.0")
        #expect(
            resolved.audioFiles
                == [
                    .init(
                        url: URL(string: "https://media.example/audio")!, title: "Opus, original", language: "en",
                        headers: ["User-Agent": "Mozilla/5.0", "Accept-Language": "en-us,en;q=0.5"], isRequired: true)
                ])
        #expect(resolved.title == "Big Buck Bunny")
        #expect(resolved.historyKey == "youtube:aqz-KE-bpKQ")
    }

    @Test("A muxed stream or HLS plays alone; media found by the generic extractor opens as it is")
    func readsSingleStreams() throws {
        let muxed = try #require(
            try info(
                #"{"id": "1", "extractor_key": "Vimeo", "url": "https://media.example/hls.m3u8", "protocol": "m3u8_native"}"#
            ).resolvedMedia(for: Self.page))
        #expect(muxed.path == "https://media.example/hls.m3u8")
        #expect(muxed.audioFiles.isEmpty)
        let file = URL(string: "https://media.example/clip")!
        let direct = #"{"id": "clip", "extractor_key": "Generic", "direct": true, "url": "https://media.example/clip"}"#
        #expect(try info(direct).resolvedMedia(for: file) == nil)
    }

    @Test("HLS opens from its master playlist, for its variants, and the generic extractor's ids name no history")
    func readsHLSMasterAndGenericPages() throws {
        let variant = """
            {"id": "video", "extractor_key": "Generic", "title": "A page",
             "requested_formats": [
               {"url": "https://media.example/master/v720", "protocol": "m3u8_native", "vcodec": "avc1",
                "acodec": "none", "manifest_url": "https://media.example/master?token=x"},
               {"url": "https://media.example/master/a1", "protocol": "m3u8_native", "vcodec": "none",
                "acodec": "mp4a.40.2", "manifest_url": "https://media.example/master?token=x"}
             ]}
            """
        let resolved = try #require(
            try info(variant).resolvedMedia(for: URL(string: "https://news.example/clips/video")!))
        #expect(resolved.path == "https://media.example/master?token=x")
        #expect(resolved.audioFiles.isEmpty, "The master's audio renditions were opened apart")
        #expect(resolved.historyKey == nil)
    }

    @Test("Playlists and DASH fail the load with a reason")
    func rejectsWhatDoesNotPlay() throws {
        #expect(throws: MediaResolutionError.self) {
            try info(#"{"_type": "playlist", "id": "PL1", "entries": []}"#).resolvedMedia(for: Self.page)
        }
        let dash = #"{"id": "1", "url": "https://media.example/a", "protocol": "http_dash_segments"}"#
        #expect(throws: MediaResolutionError.self) { try info(dash).resolvedMedia(for: Self.page) }
    }

    @Test("yt-dlp's reason drops the ERROR prefix, the extractor and the id")
    func readsErrorMessage() {
        let error = { (text: String) in YTDLPResolver.error(in: Data(text.utf8)) }
        let unavailable = error("WARNING: x\nERROR: [youtube] dQw4w9WgXcQ: Video unavailable\n")
        #expect(unavailable == MediaResolutionError("Video unavailable", isAboutPage: true))
        #expect(
            error("ERROR: Unsupported URL: https://example.com/\n").message == "Unsupported URL: https://example.com/")
        // Only failed to read the URL, as the demuxer did.
        let generic = error("ERROR: [generic] stream: Unable to download webpage: HTTP Error 401: Unauthorized\n")
        #expect(
            generic
                == MediaResolutionError("Unable to download webpage: HTTP Error 401: Unauthorized", isAboutPage: false))
        #expect(error("") == MediaResolutionError("yt-dlp failed", isAboutPage: false))
        // yt-dlp's own, about a page it read: as a site's.
        #expect(error("ERROR: Requested format is not available. Use --list-formats\n").isAboutPage)
        // Not an `ERROR:` line: a crash, about nothing it read.
        #expect(!error("Traceback (most recent call last):\n  File \"yt_dlp\", line 1\nKeyError: 'x'\n").isAboutPage)
    }

    @Test("The format selector keeps DASH out of every choice")
    func selectsPlayableFormats() {
        let choices = YTDLPResolver.formatSelector.split(separator: "/")
        #expect(choices.allSatisfy { $0.contains("[protocol^=m3u8]") || $0.contains("[protocol!*=dash]") })
        let arguments = YTDLPResolver.arguments(for: Self.page, headers: ["Referer": "https://a.example/"])
        #expect(arguments.suffix(4) == ["--add-headers", "Referer:https://a.example/", "--", Self.page.absoluteString])
    }

    // MARK: - Finding and running yt-dlp

    /// A directory of its own for a test, removed after it.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NitsYTDLP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An executable shell script at `directory/name` standing in for yt-dlp.
    @discardableResult
    private func makeScript(_ body: String, named name: String = "yt-dlp", in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("yt-dlp is found on PATH, then where package managers install it; a path of the user's alone when set")
    func findsExecutable() throws {
        let first = try makeDirectory()
        let second = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        // Not executable: skipped.
        try "".write(to: first.appendingPathComponent("yt-dlp"), atomically: true, encoding: .utf8)
        let found = try makeScript("", named: "yt-dlp_macos", in: second)
        let locator = YTDLPLocator(environmentPath: "\(first.path):\(second.path)", homeDirectory: "/nonexistent")
        #expect(locator.executable()?.path == found.path)
        #expect(locator.processPath(for: found).hasPrefix(second.path + ":"))
        #expect(locator.processPath(for: found).contains("/opt/homebrew/bin"), "Deno and FFmpeg wouldn't be found")

        let own = try makeScript("", named: "my-ytdlp", in: first)
        #expect(YTDLPLocator(customPath: own.path, environmentPath: second.path).executable()?.path == own.path)
        #expect(YTDLPLocator(customPath: "/nonexistent/yt-dlp", environmentPath: second.path).executable() == nil)
    }

    @Test("A page's answer is read past a pipe's buffer; an unsupported URL opens as it is; other failures tell why")
    func runsExecutable() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Over 64 KB, as a page's JSON is: read while yt-dlp still writes.
        let padding = String(repeating: "x", count: 300_000)
        let answer = Self.separateStreams.dropLast() + #", "description": "\#(padding)"}"#
        let json = directory.appendingPathComponent("answer.json")
        try answer.write(to: json, atomically: true, encoding: .utf8)
        let script = try makeScript(
            """
            for argument in "$@"; do last="$argument"; done
            case "$last" in
              *watch*) cat '\(json.path)' ;;
              *unsupported*) echo "ERROR: Unsupported URL: $last" >&2; exit 1 ;;
              *) echo "ERROR: [youtube] gone: Video unavailable" >&2; exit 1 ;;
            esac
            """, in: directory)
        let resolver = YTDLPResolver(locator: YTDLPLocator(customPath: script.path))

        #expect(resolver.order(for: Self.page) == .beforeOpening)
        #expect(resolver.order(for: URL(string: "https://music.youtube.com/watch?v=1")!) == .beforeOpening)
        #expect(resolver.order(for: URL(string: "https://jellyfin.example/Videos/1/stream")!) == .afterOpeningFails)
        #expect(resolver.order(for: URL(string: "https://notyoutube.com/watch")!) == .afterOpeningFails)
        #expect(resolver.order(for: URL(string: "https://media.example/movie.mkv")!) == nil)
        #expect(resolver.order(for: URL(string: "https://media.example/live.m3u8")!) == nil)
        let resolved = try #require(try await resolver.resolve(Self.page, headers: [:]))
        #expect(resolved.historyKey == "youtube:aqz-KE-bpKQ")
        #expect(try await resolver.resolve(URL(string: "https://a.example/unsupported")!, headers: [:]) == nil)
        await #expect(throws: MediaResolutionError("Video unavailable")) {
            try await resolver.resolve(URL(string: "https://a.example/gone")!, headers: [:])
        }
    }

    @Test("A yt-dlp that doesn't answer is stopped by a cancelled load and by the timeout")
    func stopsHungExecutable() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript("exec sleep 30", in: directory)

        let resolver = YTDLPResolver(locator: YTDLPLocator(customPath: script.path))
        let started = ContinuousClock.now
        let resolving = Task { try await resolver.resolve(Self.page, headers: [:]) }
        try await Task.sleep(for: .milliseconds(200))
        resolving.cancel()
        await #expect(throws: CancellationError.self) { try await resolving.value }
        #expect(ContinuousClock.now - started < .seconds(5))

        let impatient = YTDLPResolver(locator: YTDLPLocator(customPath: script.path), timeout: .milliseconds(300))
        await #expect(throws: MediaResolutionError.self) { try await impatient.resolve(Self.page, headers: [:]) }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test(
        "Stopping yt-dlp stops what it started, down to a grandchild (Deno under yt-dlp_macos's loader): its process group"
    )
    func stopsChildren() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        // The child's output goes elsewhere, as Deno's goes to yt-dlp.
        let script = try makeScript(
            "sh -c 'sleep 30 >/dev/null 2>&1 & echo $! > \"\(pidFile.path)\"; wait' >/dev/null 2>&1 &\nwait",
            in: directory)
        let resolver = YTDLPResolver(locator: YTDLPLocator(customPath: script.path))
        let resolving = Task { try await resolver.resolve(Self.page, headers: [:]) }
        var child: pid_t?
        for _ in 0..<50 where child == nil {
            try await Task.sleep(for: .milliseconds(20))
            child = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap {
                pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let pid = try #require(child)
        resolving.cancel()
        _ = try? await resolving.value
        var isGone = false
        for _ in 0..<50 where !isGone {
            try await Task.sleep(for: .milliseconds(20))
            isGone = kill(pid, 0) != 0
        }
        if !isGone { kill(pid, SIGKILL) }
        #expect(isGone, "yt-dlp's child outlived it")
    }
}
