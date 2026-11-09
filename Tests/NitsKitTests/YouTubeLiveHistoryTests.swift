import Foundation
import NitsCore
import Testing
import os

@testable import NitsKit

/// A YouTube live stream's history as a window of numbered segments, from a server that is a model of YouTube's: it
/// answers a request without a number with the newest segment, keeps segments from some number on, tells the head in
/// every answer, and gives each segment its own start time.
@Suite("YouTube live history")
struct YouTubeLiveHistoryTests {
    // MARK: A model of the server

    fileprivate static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian, Array.init) + Array(type.utf8) + payload
    }

    fileprivate static func uint32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    fileprivate static func uint64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

    /// The start of a segment: `moov` with a timescale of 90 000, `moof` with its decode time, some media data.
    fileprivate static func fragment(startingAt time: Double) -> Data {
        let mdhd = box("mdhd", [0, 0, 0, 0] + uint32(0) + uint32(0) + uint32(90000) + uint32(0))
        let moov = box("moov", box("trak", box("mdia", mdhd)))
        let tfdt = box("tfdt", [1, 0, 0, 0] + uint64(UInt64(time * 90000)))
        let moof = box("moof", box("traf", tfdt))
        return Data(box("ftyp", Array("dash".utf8)) + moov + moof + box("mdat", [UInt8](repeating: 1, count: 500)))
    }

    /// Segments of 5 s but a run of 4.933 s, numbered from 0 (the stream's start), the server keeping `oldest` on.
    struct Server: Sendable {
        var head: Int
        var oldest: Int
        var tellsHead = true
        var requests = OSAllocatedUnfairLock(initialState: [String]())

        func start(of number: Int) -> Double {
            var time = 0.0
            for segment in 0..<number { time += (400..<500).contains(segment) ? 4.9333 : 5.0 }
            return time
        }

        func answer(_ request: URLRequest) -> YouTubeLiveHistory.Answer {
            let query = request.url?.query ?? ""
            let number = query.components(separatedBy: "&").first { $0.hasPrefix("sq=") }.flatMap {
                Int($0.dropFirst(3))
            }
            requests.withLock { $0.append(number.map { "sq=\($0)" } ?? "head") }
            var headers: [String: String] = [:]
            if tellsHead {
                headers["x-head-seqnum"] = "\(head)"
                headers["x-head-time-millis"] = "\(Int(start(of: head) * 1000))"
            }
            let wanted = number ?? head
            guard wanted >= oldest, wanted <= head else { return .init(status: 404, headers: headers, data: Data()) }
            if tellsHead { headers["x-sequence-num"] = "\(wanted)" }
            return .init(
                status: 206, headers: headers, data: YouTubeLiveHistoryTests.fragment(startingAt: start(of: wanted)))
        }
    }

    private static let streams: [SegmentedDASHManifest.Stream] = [
        .init(
            kind: .video, id: "134", container: "mp4",
            url: "https://rr1.googlevideo.example/videoplayback?id=live&itag=134"),
        .init(
            kind: .audio, id: "140", container: "mp4",
            url: "https://rr1.googlevideo.example/videoplayback?id=live&itag=140"),
    ]

    private func window(_ server: Server) async throws -> YouTubeLiveHistory.Window {
        try await YouTubeLiveHistory.window(of: Self.streams, headers: ["User-Agent": "Test/1"]) { server.answer($0) }
    }

    // MARK: Window

    @Test("A young stream is played from its first segment, the timeline running from zero")
    func youngStream() async throws {
        let server = Server(head: 2160, oldest: 0)
        let window = try await window(server)
        #expect(window.firstNumber == 0)
        #expect(window.lastNumber == 2160)
        #expect(window.startTime == 0)
        #expect(abs(window.lastStartTime - server.start(of: 2160)) < 0.001)
        let text = window.manifest.text()
        #expect(text.contains(#"startNumber="0""#))
        // Anchors every hour: a run of 4.933 s segments (400…499) is seen by the anchor after it (segment 720).
        #expect(text.contains(#"<S t="0""#))
        // It asked for the head, the first segment, and a handful of anchors: not for every segment.
        #expect(server.requests.withLock { $0.count } < 20)
        // And the log says how many, by part: the head, one for the first segment (it was there), the times of the rest.
        let timings = window.timings
        let counted = timings.requests.head + timings.requests.first + timings.requests.anchors
        #expect(counted == server.requests.withLock { $0.count }, "\(timings)")
        #expect(timings.requests.head == 1)
        #expect(timings.requests.first == 1)
        #expect(timings.firstFoundBy == "a day back")
    }

    @Test("An old stream is played from a day back, on the stream's own time, whatever more the server keeps")
    func oldStream() async throws {
        let server = Server(head: 30_000, oldest: 100)
        let window = try await window(server)
        #expect(window.firstNumber == 30_000 - YouTubeLiveHistory.maxHistory)
        #expect(window.lastNumber == 30_000)
        #expect(abs(window.startTime - server.start(of: window.firstNumber)) < 0.001)
        let text = window.manifest.text()
        #expect(text.contains(#"startNumber="12720""#))
        #expect(text.contains(#"<S t="\#(Int(server.start(of: 12_720) * 1000))""#), "\(text)")
        // One request told that the day is there; the segments before it were not asked for.
        #expect(server.requests.withLock { $0.contains { $0 == "sq=12720" } })
        #expect(server.requests.withLock { $0.contains { $0 == "sq=0" || $0 == "sq=100" } } == false)
    }

    @Test("A stream whose server keeps less than a day starts inside the edge it finds, which is not exact")
    func shortHistory() async throws {
        let server = Server(head: 30_000, oldest: 29_000)
        let window = try await window(server)
        #expect(window.firstNumber >= 29_000, "starts at \(window.firstNumber), before the server's first")
        #expect(window.firstNumber < 29_000 + 360 + YouTubeLiveHistory.edgeMargin + 1)
        #expect(window.lastNumber == 30_000)
        // The log says that it looked for the edge, which is what takes long on a real server.
        #expect(window.timings.firstFoundBy.contains("edge"), "\(window.timings)")
        #expect(window.timings.requests.first > 1, "\(window.timings)")
        // Every segment the window asks for is there.
        #expect(
            server.requests.withLock { $0.filter { $0.hasPrefix("sq=") }.compactMap { Int($0.dropFirst(3)) } }.contains
            { $0 < 29_000 } == true)
    }

    @Test("The manifest names the streams by keys, not by their signed addresses, and goes on a day past the head")
    func namesStreamsByKeys() async throws {
        let server = Server(head: 3000, oldest: 0)
        let window = try await window(server)
        let text = window.manifest.text()
        #expect(!text.contains("googlevideo"), "a signed address is in the manifest")
        #expect(text.contains("https://live.nits.invalid/134?sq=$Number$"))
        #expect(text.contains("https://live.nits.invalid/140?sq=$Number$"))
        #expect(window.signedURLs == ["134": Self.streams[0].url, "140": Self.streams[1].url])
        let runs = try #require(window.manifest.runs)
        #expect(runs.last == .init(duration: 5, count: YouTubeLiveHistory.futureSegments))
        // The segments up to the head and the day to come: 3001 and 17280.
        #expect(runs.reduce(0) { $0 + $1.count } == window.lastNumber - window.firstNumber + 1 + 17280)
    }

    @Test("A stream with next to no history starts inside its few segments")
    func almostNoHistory() async throws {
        let server = Server(head: 50_000, oldest: 49_994)
        let window = try await window(server)
        #expect(window.firstNumber >= 49_994)
        #expect(window.firstNumber < 50_000)
    }

    @Test("The timeline is right at every anchor and off by seconds between")
    func timelineAccuracy() async throws {
        let server = Server(head: 3000, oldest: 0)
        let window = try await window(server)
        // Sum the lengths the manifest tells to the anchor at 1440 and compare with the model.
        let runs = try #require(window.manifest.runs)
        var number = window.firstNumber
        var time = window.startTime
        for run in runs {
            for _ in 0..<run.count where number <= window.lastNumber {
                if number % 720 == 0 { #expect(abs(time - server.start(of: number)) < 0.01, "segment \(number)") }
                number += 1
                time += run.duration
            }
        }
        // The runs go on past the head, to the segments to come.
        #expect(number == window.lastNumber + 1)
    }

    @Test("A server that doesn't tell the head, or a segment that can't be read, fails the window")
    func failures() async throws {
        var silent = Server(head: 100, oldest: 0)
        silent.tellsHead = false
        await #expect(throws: YouTubeLiveHistory.Failure.noHead) { _ = try await window(silent) }

        await #expect(throws: YouTubeLiveHistory.Failure.self) {
            _ = try await YouTubeLiveHistory.window(of: Self.streams, headers: [:]) { request in
                var answer = Server(head: 100, oldest: 0).answer(request)
                answer.data = Data("<html>".utf8)
                return answer
            }
        }
    }

    // MARK: The page's answer

    static let liveJSON = """
        {"_type": "video", "id": "umLWFz4izTM", "title": "Live", "extractor_key": "Youtube", "is_live": true,
         "requested_formats": [
           {"url": "https://rr1.googlevideo.example/videoplayback?id=live&itag=134&source=yt_live_broadcast",
            "protocol": "https", "vcodec": "avc1.4D401E", "acodec": "none", "format_id": "134", "ext": "mp4",
            "width": 640, "height": 360, "fps": 30, "tbr": 772.6, "http_headers": {"User-Agent": "Test/1"}},
           {"url": "https://rr1.googlevideo.example/videoplayback?id=live&itag=140&source=yt_live_broadcast",
            "protocol": "https", "vcodec": "none", "acodec": "mp4a.40.2", "format_id": "140", "ext": "m4a",
            "abr": 144, "asr": 44100, "http_headers": {"User-Agent": "Test/1"}}
         ],
         "formats": [
           {"url": "https://rr1.googlevideo.example/videoplayback?id=live&itag=134&source=yt_live_broadcast&sig=fresh",
            "protocol": "https", "vcodec": "avc1.4D401E", "acodec": "none", "format_id": "134", "ext": "mp4"},
           {"url": "https://rr1.googlevideo.example/videoplayback?id=live&itag=140&source=yt_live_broadcast&sig=fresh",
            "protocol": "https", "vcodec": "none", "acodec": "mp4a.40.2", "format_id": "140", "ext": "m4a"},
           {"url": "https://rr1.googlevideo.example/hls/360", "manifest_url": "https://manifest.example/hls/360.m3u8",
            "protocol": "m3u8_native", "vcodec": "avc1.4D401E", "acodec": "none", "format_id": "230", "height": 360, "tbr": 962},
           {"url": "https://rr1.googlevideo.example/hls/720", "manifest_url": "https://manifest.example/hls/master.m3u8",
            "protocol": "m3u8_native", "vcodec": "avc1.4D4020", "acodec": "none", "format_id": "311", "height": 720, "tbr": 2922}
         ]}
        """

    private func info(_ json: String) throws -> YTDLPInfo {
        try JSONDecoder().decode(YTDLPInfo.self, from: Data(json.utf8))
    }

    @Test("Only a YouTube live stream's adaptive segments are a history; its best HLS picture is the way back")
    func recognisesLiveHistory() throws {
        let live = try info(Self.liveJSON)
        #expect(live.liveHistoryFormats()?.count == 2)
        #expect(live.choosingHLS()?.requestedFormats?.first?.formatID == "311")
        // Not a stream on the air, not YouTube, not segments of a live broadcast.
        #expect(
            try info(Self.liveJSON.replacingOccurrences(of: #""is_live": true"#, with: #""is_live": false"#))
                .liveHistoryFormats() == nil)
        #expect(try info(Self.liveJSON.replacingOccurrences(of: "Youtube", with: "Twitch")).liveHistoryFormats() == nil)
        #expect(
            try info(Self.liveJSON.replacingOccurrences(of: "yt_live_broadcast", with: "yt_vod")).liveHistoryFormats()
                == nil)
        #expect(try info(YTDLPResolverTests.separateStreams).liveHistoryFormats() == nil)
        // A premiere on the air is numbered like a live stream.
        #expect(
            try info(Self.liveJSON.replacingOccurrences(of: "yt_live_broadcast", with: "yt_premiere_broadcast"))
                .liveHistoryFormats() != nil)
    }

    @Test("The manifest of the window is the media; the page's title and history key stay")
    func resolvesWindow() throws {
        let live = try info(Self.liveJSON)
        let formats = try #require(live.liveHistoryFormats())
        var manifest = SegmentedDASHManifest(
            streams: live.segmentStreams(of: formats), segmentDuration: 5, segmentCount: 10)
        manifest.firstNumber = 100
        let window = YouTubeLiveHistory.Window(
            manifest: manifest, firstNumber: 100, lastNumber: 109, startTime: 500, lastStartTime: 545)
        let resolved = try #require(try live.resolvedMedia(for: YTDLPResolverTests.page, liveHistory: window))
        // What the demuxer is told of the stream's time: the timeline's zero, and the end of the newest segment.
        #expect(resolved.liveHistory == LiveHistory(origin: 500, end: 550, headNumber: 109))
        #expect(MediaURL.isInlineDASHManifest(resolved.path))
        #expect(resolved.historyKey == "youtube:umLWFz4izTM")
        #expect(resolved.title == "Live")
        #expect(resolved.headers["User-Agent"] == "Test/1")
        #expect(resolved.audioFiles.isEmpty)
    }

    @Test("yt-dlp is asked to list the adaptive formats of a live stream only when history is wanted")
    func asksForIncompleteFormats() {
        let url = YTDLPResolverTests.page
        #expect(!YTDLPResolver.arguments(for: url, headers: [:]).contains("--extractor-args"))
        let wanted = YTDLPResolver.arguments(for: url, headers: [:], liveHistory: true)
        let index = wanted.firstIndex(of: "--extractor-args")
        #expect(index.map { wanted[$0 + 1] } == "youtube:formats=incomplete")
    }

    // MARK: The resolver

    private func scriptResolver(
        liveHistory: Bool, answer: String = YouTubeLiveHistoryTests.liveJSON, fetch: @escaping YouTubeLiveHistory.Fetch
    ) throws -> (YTDLPResolver, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NitsYTDLP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent("answer.json")
        try answer.write(to: json, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("yt-dlp")
        try "#!/bin/sh\ncat '\(json.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (
            YTDLPResolver(
                locator: YTDLPLocator(customPath: script.path), liveHistory: liveHistory, liveHistoryFetch: fetch),
            directory
        )
    }

    @Test(
        "Incomplete formats chosen that are no live history are not played: the HLS playlist is, when the page has one")
    func incompleteFormatsThatAreNoHistory() async throws {
        // The page does not say it is on the air, and what was chosen is a live stream's segments, which end after seconds.
        let stale = Self.liveJSON
            .replacingOccurrences(of: #""is_live": true"#, with: #""is_live": false"#)
            .replacingOccurrences(
                of: #""protocol": "https", "vcodec": "avc1.4D401E""#,
                with: #""format_note": "360p (incomplete)", "protocol": "https", "vcodec": "avc1.4D401E""#)
        let info = try info(stale)
        #expect(info.choseIncompleteFormats)
        #expect(info.liveHistoryFormats() == nil)
        let (resolver, directory) = try scriptResolver(liveHistory: true, answer: stale) { _ in
            .init(status: 404, headers: [:], data: Data())
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = try #require(try await resolver.resolve(YTDLPResolverTests.page, headers: [:]))
        #expect(resolved.path == "https://manifest.example/hls/master.m3u8")
        #expect(resolved.liveHistory == nil)
        // Without a playlist there is nothing that plays: an error, not formats the server ends after seconds.
        let noPlaylist = stale.replacingOccurrences(
            of: #""protocol": "m3u8_native""#, with: #""protocol": "http_dash_segments""#)
        let (bare, bareDirectory) = try scriptResolver(liveHistory: true, answer: noPlaylist) { _ in
            .init(status: 404, headers: [:], data: Data())
        }
        defer { try? FileManager.default.removeItem(at: bareDirectory) }
        await #expect(throws: MediaResolutionError.self) {
            _ = try await bare.resolve(YTDLPResolverTests.page, headers: [:])
        }
        // A page whose chosen formats are complete is not touched.
        #expect(try self.info(YTDLPResolverTests.separateStreams).choseIncompleteFormats == false)
    }

    @Test("yt-dlp says whether the stream is over; what it can't read is no answer")
    func asksYtDlpIfTheStreamIsOver() async throws {
        let live = try scriptResolver(liveHistory: true) { _ in .init(status: 404, headers: [:], data: Data()) }
        defer { try? FileManager.default.removeItem(at: live.1) }
        #expect(try await live.0.liveStreamIsOver(page: YTDLPResolverTests.page, headers: [:]) == false)

        let ended = Self.liveJSON.replacingOccurrences(of: #""is_live": true"#, with: #""is_live": false"#)
        let over = try scriptResolver(liveHistory: true, answer: ended) { _ in
            .init(status: 404, headers: [:], data: Data())
        }
        defer { try? FileManager.default.removeItem(at: over.1) }
        #expect(try await over.0.liveStreamIsOver(page: YTDLPResolverTests.page, headers: [:]) == true)

        let silent = Self.liveJSON.replacingOccurrences(of: #""is_live": true,"#, with: "")
        let unknown = try scriptResolver(liveHistory: true, answer: silent) { _ in
            .init(status: 404, headers: [:], data: Data())
        }
        defer { try? FileManager.default.removeItem(at: unknown.1) }
        await #expect(throws: MediaResolutionError.self) {
            _ = try await unknown.0.liveStreamIsOver(page: YTDLPResolverTests.page, headers: [:])
        }
    }

    @Test("A live page with history wanted plays from the window; the HLS playlist when the server can't tell it")
    func resolvesLivePage() async throws {
        let server = Server(head: 4000, oldest: 100)
        let (resolver, directory) = try scriptResolver(liveHistory: true) { server.answer($0) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = try #require(try await resolver.resolve(YTDLPResolverTests.page, headers: [:]))
        #expect(MediaURL.isInlineDASHManifest(resolved.path))
        #expect(resolved.historyKey == "youtube:umLWFz4izTM")
        // The demuxer is told where the stream's head is and who to ask for its segments: the manifest names only keys.
        let history = try #require(resolved.liveHistory)
        #expect(history.headNumber == 4000)
        let source = try #require(history.source as? YouTubeLiveSource)
        let original = "https://rr1.googlevideo.example/videoplayback?id=live&itag=134&source=yt_live_broadcast"
        #expect(source.url(for: "134", number: 4001)?.absoluteString == original + "&sq=4001")
        #expect(!MediaURL.loggable(resolved.path).contains("googlevideo"))
        // Refused, the source asks yt-dlp for the page again and takes the addresses it gives.
        let renewed = await onThread { source.renewSignature(shouldAbort: { false }) }
        #expect(renewed)
        #expect(source.url(for: "134", number: 4001)?.absoluteString == original + "&sig=fresh&sq=4001")

        var quiet = server
        quiet.tellsHead = false
        let silent = quiet
        let (fallback, directory2) = try scriptResolver(liveHistory: true) { silent.answer($0) }
        defer { try? FileManager.default.removeItem(at: directory2) }
        let hls = try #require(try await fallback.resolve(YTDLPResolverTests.page, headers: [:]))
        #expect(hls.path == "https://manifest.example/hls/master.m3u8")

        // Not wanted: the formats yt-dlp chose are played as they are, and the server is not asked.
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let (plain, directory3) = try scriptResolver(liveHistory: false) { request in
            asked.withLock { $0 += 1 }
            return server.answer(request)
        }
        defer { try? FileManager.default.removeItem(at: directory3) }
        _ = try await plain.resolve(YTDLPResolverTests.page, headers: [:])
        #expect(asked.withLock { $0 } == 0)
    }

    @Test("A premiere on the air plays from the window, and its signature is renewed like a live stream's")
    func resolvesPremierePage() async throws {
        let premiere = Self.liveJSON.replacingOccurrences(of: "yt_live_broadcast", with: "yt_premiere_broadcast")
        let server = Server(head: 4000, oldest: 100)
        let (resolver, directory) = try scriptResolver(liveHistory: true, answer: premiere) { server.answer($0) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = try #require(try await resolver.resolve(YTDLPResolverTests.page, headers: [:]))
        let history = try #require(resolved.liveHistory)
        let source = try #require(history.source as? YouTubeLiveSource)
        // The renewal takes the addresses of a premiere's formats too (`liveSegmentURLs`), not only a live stream's.
        let renewed = await onThread { source.renewSignature(shouldAbort: { false }) }
        #expect(renewed)
        let address = source.url(for: "134", number: 4001)?.absoluteString
        #expect(address?.hasSuffix("source=yt_premiere_broadcast&sig=fresh&sq=4001") == true)
    }
}
