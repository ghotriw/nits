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
            "http_headers": \(headers), "downloader_options": {"http_chunk_size": 10485760}},
           {"url": "https://media.example/audio", "protocol": "https", "vcodec": "none", "acodec": "opus",
            "language": "en", "format_note": "English (US) original (default), medium", "http_headers": \(headers),
            "downloader_options": {"http_chunk_size": 5242880}}
         ]}
        """

    private func info(_ json: String) throws -> YTDLPInfo {
        try JSONDecoder().decode(YTDLPInfo.self, from: Data(json.utf8))
    }

    @Test(
        "A picture and its audio in separate files play as the media and an audio file of it, named by the page, each read in requests of its chunk size"
    )
    func readsSeparateStreams() throws {
        let resolved = try #require(try info(Self.separateStreams).resolvedMedia(for: Self.page))
        #expect(resolved.path == "https://media.example/video")
        #expect(resolved.headers["User-Agent"] == "Mozilla/5.0")
        #expect(resolved.httpRequestSize == 10 << 20)
        #expect(
            resolved.audioFiles
                == [
                    .init(
                        url: URL(string: "https://media.example/audio")!, title: "Opus, original", language: "en",
                        headers: ["User-Agent": "Mozilla/5.0", "Accept-Language": "en-us,en;q=0.5"], isRequired: true,
                        httpRequestSize: 5 << 20)
                ])
        #expect(resolved.title == "Big Buck Bunny")
        #expect(resolved.historyKey == "youtube:aqz-KE-bpKQ")
        #expect(resolved.chapters.isEmpty)
        #expect(resolved.actionButtons.isEmpty)
    }

    @Test(
        "The page's other audio languages are listed after the one chosen, each its best progressive stream in the chosen codec, to open when selected"
    )
    func listsOtherAudioLanguages() throws {
        let json = """
            {"_type": "video", "id": "dub", "title": "Dubbed", "extractor_key": "Youtube",
             "requested_formats": [
               {"url": "https://media.example/video", "protocol": "https", "vcodec": "av01", "acodec": "none"},
               {"url": "https://media.example/uk", "protocol": "https", "vcodec": "none", "acodec": "opus",
                "language": "uk", "format_note": "Ukrainian original (default), medium"}
             ],
             "formats": [
               {"format_id": "251-0", "url": "https://media.example/en-low", "protocol": "https", "vcodec": "none",
                "acodec": "opus", "language": "en-US", "format_note": "English (US) dubbed-auto, low", "abr": 40},
               {"format_id": "251-0", "url": "https://media.example/en", "protocol": "https", "vcodec": "none",
                "acodec": "opus", "language": "en-US", "format_note": "English (US) dubbed-auto, medium",
                "abr": 130, "audio_channels": 2, "asr": 48000},
               {"format_id": "251-drc", "url": "https://media.example/en-drc", "protocol": "https", "vcodec": "none",
                "acodec": "opus", "language": "en-US", "abr": 200},
               {"format_id": "140-0", "url": "https://media.example/en-aac", "protocol": "https", "vcodec": "none",
                "acodec": "mp4a.40.2", "language": "en-US", "abr": 130},
               {"format_id": "251", "url": "https://media.example/uk-again", "protocol": "https", "vcodec": "none",
                "acodec": "opus", "language": "uk", "abr": 130},
               {"format_id": "hls-de", "url": "https://media.example/de.m3u8", "protocol": "m3u8_native",
                "vcodec": "none", "acodec": "opus", "language": "de", "abr": 130}
             ]}
            """
        let resolved = try #require(try info(json).resolvedMedia(for: Self.page))
        #expect(
            resolved.audioFiles.map(\.url.absoluteString) == ["https://media.example/uk", "https://media.example/en"])
        #expect(resolved.audioFiles.map(\.isRequired) == [true, false])
        #expect(resolved.audioFiles.map(\.title) == ["Opus, original", "Opus, dubbed"])
        #expect(resolved.audioFiles[0].declaredStream == nil)
        #expect(resolved.audioFiles[1].declaredStream == .init(codecName: "opus", channels: 2, sampleRate: 48000))
    }

    @Test(
        "The page's other pictures of the kind chosen are offered, the best bitrate of each size and codec, best first")
    func listsOtherPictures() throws {
        let json = """
            {"_type": "video", "id": "pic", "extractor_key": "Youtube",
             "requested_formats": [
               {"format_id": "399", "url": "https://media.example/v399", "protocol": "https", "vcodec": "av01.0.13M.08",
                "acodec": "none", "width": 1920, "height": 1080, "fps": 30, "tbr": 2000},
               {"url": "https://media.example/audio", "protocol": "https", "vcodec": "none", "acodec": "opus"}
             ],
             "formats": [
               {"format_id": "399", "url": "https://media.example/v399", "protocol": "https", "vcodec": "av01.0.13M.08",
                "acodec": "none", "width": 1920, "height": 1080, "fps": 30, "tbr": 2000},
               {"format_id": "399p", "url": "https://media.example/v399p", "protocol": "https", "vcodec": "av01.0.13M.08",
                "acodec": "none", "width": 1920, "height": 1080, "fps": 30, "tbr": 3000},
               {"format_id": "248", "url": "https://media.example/v248", "protocol": "https", "vcodec": "vp9",
                "acodec": "none", "width": 1920, "height": 1080, "fps": 30, "tbr": 2500},
               {"format_id": "134", "url": "https://media.example/v134", "protocol": "https", "vcodec": "avc1.4d401e",
                "acodec": "none", "width": 640, "height": 360, "fps": 30, "tbr": 600},
               {"format_id": "18", "url": "https://media.example/v18", "protocol": "https", "vcodec": "avc1.42001E",
                "acodec": "mp4a.40.2", "width": 640, "height": 360, "fps": 30, "tbr": 500},
               {"format_id": "dash", "url": "https://media.example/dash", "protocol": "http_dash_segments",
                "vcodec": "vp9", "acodec": "none", "width": 3840, "height": 2160, "fps": 30, "tbr": 9000},
               {"format_id": "sb0", "url": "https://media.example/sb", "protocol": "mhtml", "vcodec": "none",
                "acodec": "none", "width": 48, "height": 27}
             ]}
            """
        let resolved = try #require(try info(json).resolvedMedia(for: Self.page))
        #expect(resolved.selectedVideoFormatID == "399")
        #expect(resolved.videoFormats.map(\.id) == ["248", "399", "134"], "\(resolved.videoFormats.map(\.id))")
        #expect(resolved.videoFormats.map(\.codec) == ["VP9", "AV1", "H.264"])
    }

    @Test("Reads author chapters from yt-dlp JSON into normalized MediaChapter markers")
    func readsAuthorChapters() throws {
        let json = """
            {"_type": "video", "id": "ch1", "title": "Tutorial", "extractor_key": "Youtube", "duration": 300,
             "url": "https://media.example/video", "protocol": "https",
             "chapters": [
               {"start_time": 0.0, "end_time": 60.0, "title": "Intro"},
               {"start_time": 60.0, "end_time": 200.0, "title": "Main Content"},
               {"start_time": 200.0, "end_time": 300.0, "title": "Outro"}
             ]}
            """
        let resolved = try #require(try info(json).resolvedMedia(for: Self.page))
        #expect(resolved.chapters.count == 3)
        #expect(resolved.chapters.map(\.title) == ["Intro", "Main Content", "Outro"])
        #expect(resolved.chapters.map(\.start) == [0.0, 60.0, 200.0])
        #expect(resolved.chapters.map(\.end) == [60.0, 200.0, 300.0])
        #expect(resolved.chapters.map(\.id) == [0, 1, 2])
    }

    @Test(
        "Reads manual subtitles and original automatic captions, preferring ASS/VTT over SRT and skipping machine translations and live_chat"
    )
    func readsSubtitlesAndAutomaticCaptions() throws {
        let json = """
            {"_type": "video", "id": "sub1", "title": "Subtitled", "extractor_key": "Youtube",
             "url": "https://media.example/video", "protocol": "https",
             "subtitles": {
               "live_chat": [
                 {"url": "https://www.youtube.com/live_chat?v=sub1", "ext": "json"}
               ],
               "uk": [
                 {"url": "https://www.youtube.com/api/timedtext?v=sub1&lang=uk&fmt=srv3", "ext": "srv3", "name": "Ukrainian"},
                 {"url": "https://www.youtube.com/api/timedtext?v=sub1&lang=uk&fmt=srt", "ext": "srt", "name": "Ukrainian"},
                 {"url": "https://www.youtube.com/api/timedtext?v=sub1&lang=uk&fmt=vtt", "ext": "vtt", "name": "Ukrainian",
                  "http_headers": \(Self.headers)}
               ],
               "ja-track1": [
                 {"url": "https://media.example/subs/ja.ass", "ext": "ass", "name": "Japanese (Styled)"}
               ]
             },
             "automatic_captions": {
               "en-orig": [
                 {"url": "https://www.youtube.com/api/timedtext?v=sub1&lang=en&caps=asr&fmt=vtt", "ext": "vtt",
                  "name": "English (Original)"}
               ],
               "en": [
                 {"url": "https://www.youtube.com/api/timedtext?v=sub1&lang=en&caps=asr&fmt=vtt", "ext": "vtt",
                  "name": "English"}
               ],
               "de": [
                 {"url": "https://www.youtube.com/api/timedtext?v=sub1&lang=en&caps=asr&tlang=de&fmt=vtt", "ext": "vtt",
                  "name": "German"}
               ]
             }}
            """
        let resolved = try #require(try info(json).resolvedMedia(for: Self.page))
        #expect(resolved.subtitleFiles.count == 3)
        #expect(
            resolved.subtitleFiles.map(\.url.absoluteString) == [
                "https://media.example/subs/ja.ass",
                "https://www.youtube.com/api/timedtext?v=sub1&lang=uk&fmt=vtt",
                "https://www.youtube.com/api/timedtext?v=sub1&lang=en&caps=asr&fmt=vtt",
            ])
        #expect(resolved.subtitleFiles.map(\.language) == ["ja", "uk", "en"])
        #expect(
            resolved.subtitleFiles.map(\.title) == [
                "Japanese (Styled)",
                "Ukrainian",
                "English (auto-generated)",
            ])
        #expect(resolved.subtitleFiles.map(\.isAutoGenerated) == [false, false, true])
        #expect(resolved.subtitleFiles.map(\.format) == [.ass, .text, .text])
        #expect(resolved.subtitleFiles[1].headers?["User-Agent"] == "Mozilla/5.0")
    }

    static let video600 = """
        {"_type": "video", "id": "sb1", "title": "Review", "extractor_key": "Youtube", "duration": 600,
         "url": "https://media.example/video", "protocol": "https"}
        """

    @Test("SponsorBlock segments become skip buttons, chapters none")
    func readsSponsorBlockActionButtons() throws {
        let segments = [
            ("intro", 10.0, 30.0), ("sponsor", 120, 180), ("chapter", 200, 250),
            ("preview", 400, 430), ("hook", 450, 470), ("selfpromo", 500, 550),
        ].map { SponsorBlockSegment(category: $0.0, start: $0.1, end: $0.2, videoDuration: 600) }
        let resolved = try #require(try info(Self.video600).resolvedMedia(for: Self.page, sponsorBlock: segments))
        #expect(resolved.actionButtons.count == 5)
        #expect(
            resolved.actionButtons.map(\.title) == [
                "Skip Intro", "Skip Sponsor", "Skip Preview", "Skip Hook", "Skip Promotion",
            ])
        #expect(resolved.actionButtons.map(\.start) == [10.0, 120.0, 400.0, 450.0, 500.0])
        #expect(resolved.actionButtons.map(\.end) == [30.0, 180.0, 430.0, 470.0, 550.0])
        #expect(resolved.actionButtons.map(\.allowsAutoPress) == [true, true, false, false, true])
        #expect(resolved.actionButtons.allSatisfy { $0.seeksToEnd })
    }

    @Test("SponsorBlock's community chapters stand in for the author's only when the author gave none")
    func readsCommunityChaptersWhenAuthorGivesNone() throws {
        let segments = [
            SponsorBlockSegment(category: "chapter", start: 0, end: 120, description: "Song 1"),
            SponsorBlockSegment(category: "chapter", start: 120, end: 600, description: "Song 2"),
        ]
        let resolved = try #require(try info(Self.video600).resolvedMedia(for: Self.page, sponsorBlock: segments))
        #expect(resolved.chapters.map(\.title) == ["Song 1", "Song 2"])
        #expect(resolved.chapters.map(\.start) == [0.0, 120.0])
        #expect(resolved.chapters.map(\.end) == [120.0, 600.0])

        let authored = Self.video600.replacingOccurrences(
            of: "}", with: #", "chapters": [{"start_time": 0, "end_time": 600, "title": "All"}]}"#)
        let byAuthor = try #require(try info(authored).resolvedMedia(for: Self.page, sponsorBlock: segments))
        #expect(byAuthor.chapters.map(\.title) == ["All"])
    }

    @Test("Segments marked on another version of the video are dropped, the rest snapped to its start and end")
    func dropsSegmentsOfAnotherVersion() throws {
        let segments = [
            SponsorBlockSegment(category: "sponsor", start: 0.4, end: 20, videoDuration: 600.3),
            // Marked on a version 30 s longer: the spans moved.
            SponsorBlockSegment(category: "sponsor", start: 100, end: 160, videoDuration: 630),
            SponsorBlockSegment(category: "outro", start: 570, end: 599.5, videoDuration: 600.5),
            SponsorBlockSegment(category: "sponsor", start: 0, end: 0),
        ]
        let resolved = try #require(try info(Self.video600).resolvedMedia(for: Self.page, sponsorBlock: segments))
        #expect(resolved.actionButtons.map(\.title) == ["Skip Sponsor", "Skip Outro"])
        #expect(resolved.actionButtons.map(\.start) == [0, 570])
        #expect(resolved.actionButtons.map(\.end) == [20, 600])
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

    @Test("The video id of a YouTube page's URL, asked of SponsorBlock while yt-dlp runs")
    func extractsYouTubeVideoID() {
        let id = { (url: String) in YTDLPResolver.youTubeVideoID(from: URL(string: url)!) }
        #expect(id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10") == "dQw4w9WgXcQ")
        #expect(id("https://m.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://youtu.be/dQw4w9WgXcQ?t=10") == "dQw4w9WgXcQ")
        #expect(id("https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://www.youtube.com/live/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        // A channel's live page names no video; nor another site, nor a malformed id.
        #expect(id("https://www.youtube.com/@channel/live") == nil)
        #expect(id("https://notyoutube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(id("https://www.youtube.com/watch?v=short") == nil)
        #expect(id("https://vimeo.com/12345") == nil)
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
