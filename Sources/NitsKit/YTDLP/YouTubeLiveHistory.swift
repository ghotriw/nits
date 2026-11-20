import Foundation
import NitsCore
import os

/// A YouTube live stream played from its history, not from the HLS playlist's last hour (or seconds: its length is the
/// broadcaster's setting, `playlist_duration/30` for a stream without a DVR).
///
/// The adaptive formats yt-dlp lists for a live stream (`formats=incomplete`) are numbered segments of one URL
/// (`…&sq=N`), each with its own initialization data, which the server keeps for days (a week for a 24/7 stream). The
/// window is built as a DASH manifest of them (`SegmentedDASHManifest`; every format the page lists, in the sets of an
/// ordinary video's manifest: `YouTubeFormatGrouping`) from the first the server still has to the newest, on the
/// stream's own timeline: the times of segments are read from the segments of an MP4 stream (`FragmentStartTime`;
/// `reference(of:)`: the segments of one number start together in every format), as their lengths are not one, a few at
/// an hour's distance (`SegmentedDASHManifest.window(through:…)`).
///
/// The server's answers carry the head: a request without `sq` gets the newest segment, and every answer, a 404
/// included, tells its number (`X-Sequence-Num`, `X-Head-Seqnum`) and time (`X-Head-Time-Millis`).
enum YouTubeLiveHistory {
    /// One request's answer: its status, the headers (names in lower case) and the body, which may be cut off (the
    /// request asks for a range).
    struct Answer: Sendable {
        var status: Int
        var headers: [String: String]
        var data: Data

        init(status: Int, headers: [String: String], data: Data) {
            self.status = status
            self.headers = headers
            self.data = data
        }

        /// What a response says, the names of its headers in lower case.
        init(_ response: HTTPURLResponse, data: Data) {
            self.init(
                status: response.statusCode,
                headers: response.allHeaderFields.reduce(into: [:]) { headers, field in
                    if let name = field.key as? String, let value = field.value as? String {
                        headers[name.lowercased()] = value
                    }
                }, data: data)
        }
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> Answer

    struct Window: Sendable {
        var manifest: SegmentedDASHManifest
        var firstNumber: Int
        var lastNumber: Int
        /// Seconds from the start of the stream (the manifest's timeline) to the first and the last segment.
        var startTime: Double
        var lastStartTime: Double
        /// How long this stream's segments last, the median of the stretches between anchors (`segmentDuration(through:)`):
        /// the length of the last segment and of those past the head, which no anchor measures.
        var segmentDuration = YouTubeLiveHistory.nominalSegmentDuration
        /// The signed address of each stream by its key (the format's id): the manifest names them by their keys.
        var signedURLs: [String: String] = [:]
        /// What the manifest's segments are asked for through, once the resolver made it (`YouTubeLiveSource`).
        var source: YouTubeLiveSource?
        /// Where the time went, for the log: a slow load explains itself.
        var timings = Timings()
    }

    /// How long each part of making the window took and how many requests it made, and which way the first segment was
    /// found: a day back in one request, or the edge of the server's history looked for, which can take tens of seconds
    /// (its answers past the edge are 404, 500 and 503 for seconds each).
    struct Timings: Sendable, CustomStringConvertible {
        var head: Duration = .zero
        var first: Duration = .zero
        var anchors: Duration = .zero
        var firstFoundBy = "a day back"
        var requests = (head: 0, first: 0, anchors: 0)

        var description: String {
            "head \(head) (\(requests.head) request(s)), first segment by \(firstFoundBy) \(first) "
                + "(\(requests.first)), times of segments \(anchors) (\(requests.anchors))"
        }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case noHead
        case unreadable(Int)
        case invalidAddress

        var description: String {
            switch self {
            case .noHead: "the server didn't tell where the stream's head is"
            case .invalidAddress: "the stream's address is not a URL"
            case .unreadable(let number): "segment \(number) has no readable start time"
            }
        }
    }

    /// A segment lasts about this long (YouTube's usual, 5 s) when the anchors cannot tell. Not for every stream: a
    /// low-latency one has segments of 1 s, which the head moves by five a poll; listed past the head at 5 s each, the
    /// window's end ran away from the picture by 20 s a poll (the time behind the edge growing in jumps).
    static let nominalSegmentDuration = LiveHistory.nominalSegmentDuration

    /// The length of the stream's segments, as the stretches between anchors tell: their median, so that one stretch a
    /// gap in the stream's time skews (an encoder that came back after an hour) does not move what the segments past the
    /// last anchor, which no time was read for, are taken to last. `nominalSegmentDuration` with fewer than two anchors.
    static func segmentDuration(through anchors: [SegmentTimeSearch.Point]) -> Double {
        let sorted = anchors.sorted { $0.number < $1.number }
        let lengths = zip(sorted, sorted.dropFirst())
            .filter { $1.number > $0.number }
            .map { ($1.time - $0.time) / Double($1.number - $0.number) }
            .filter { $0 > 0.05 }
            .sorted()
        guard !lengths.isEmpty else { return nominalSegmentDuration }
        let middle = lengths.count / 2
        return lengths.count.isMultiple(of: 2) ? (lengths[middle - 1] + lengths[middle]) / 2 : lengths[middle]
    }
    /// Segments between two segments whose times are read: an hour. A stretch of shorter segments (4.933 s instead
    /// of 5) is not seen but by an anchor, so the timeline is off by that much between two: seconds.
    static let anchorSpacing = 720
    /// How far past the head the manifest goes: a day. The segments to come are listed as the head moves (`DASHHistory`); with the
    /// signature renewed meanwhile (`YouTubeLiveSource`), the manifest need not be made again while the stream is watched.
    static let futureSegments = 17280
    /// How far back the window reaches at most: a day of segments. Deliberate, not for want of more: the server keeps a
    /// week for a 24/7 stream, but its edge answers 404, 500 and 503 for 3–7 s a request and not steadily, so finding it
    /// cost 41 s of start on NASA's stream (12 s one request at a time on Sky News's); a day is one request, and as deep
    /// as the web player's own DVR.
    static let maxHistory = 17280
    /// Where the server's edge is looked for when the day is not there (a stream with a short DVR), how closely, and
    /// how far inside it the window starts: the edge answers 404, 500 and 503 for seconds each, and moves on as the
    /// stream goes.
    static let edgeTolerance = 360
    static let edgeMargin = 720
    /// How many requests are in flight at once.
    static let fanOut = 8

    static let urlSession: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return Answer(status: 0, headers: [:], data: data) }
        return Answer(http, data: data)
    }

    /// The stream whose segments are read for times: an MP4 (a `moof` has the time; a WebM's clusters are not read), a
    /// picture's before a sound's. The segments of one number start at the same time in every format and container (the
    /// sound a few milliseconds later), so what this one tells serves them all.
    static func reference(of streams: [SegmentedDASHManifest.Stream]) -> SegmentedDASHManifest.Stream? {
        let readable = streams.filter { $0.container == "mp4" }
        return readable.first { $0.kind == .video } ?? readable.first
    }

    /// The window of the stream `streams` are the segments of (`reference(of:)` is read for times; the others share them).
    static func window(
        of streams: [SegmentedDASHManifest.Stream], headers: [String: String], fetch: @escaping Fetch = urlSession
    ) async throws -> Window {
        guard let reference = reference(of: streams) else { throw Failure.noHead }
        // Requests made so far, and when each part began: the log of a slow load says which part it was.
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let counting: Fetch = { request in
            asked.withLock { $0 += 1 }
            return try await fetch(request)
        }
        var timings = Timings()
        var lap = ContinuousClock.now
        var counted = 0
        func closeLap(_ duration: inout Duration, _ requests: inout Int) {
            duration = ContinuousClock.now - lap
            let total = asked.withLock { $0 }
            requests = total - counted
            counted = total
            lap = .now
        }

        // The address comes from yt-dlp: one that is not a URL fails the window, not the app.
        @Sendable func request(number: Int?, range: String) throws -> URLRequest {
            let url = number.map { LiveHistory.segmentURL(reference.url, number: $0) } ?? URL(string: reference.url)
            guard let url else { throw Failure.invalidAddress }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
            return request
        }
        @Sendable func isAvailable(_ number: Int) async throws -> Bool {
            let answer = try await counting(request(number: number, range: "0-0"))
            return answer.status == 200 || answer.status == 206
        }
        @Sendable func start(of number: Int) async throws -> Double {
            let answer = try await counting(request(number: number, range: "0-2047"))
            guard let time = FragmentStartTime.seconds(in: answer.data) else { throw Failure.unreadable(number) }
            return time
        }

        // The head: the newest segment, which a request without a number gets.
        let newestAnswer = try await counting(request(number: nil, range: "0-2047"))
        guard
            let newest = (newestAnswer.headers["x-sequence-num"] ?? newestAnswer.headers["x-head-seqnum"]).flatMap(
                Int.init)
        else { throw Failure.noHead }
        var newestTime = FragmentStartTime.seconds(in: newestAnswer.data)
        if newestTime == nil { newestTime = try await start(of: newest) }
        let newestStart = newestTime ?? 0
        let head = SegmentTimeSearch.Point(number: newest, time: newestStart)
        closeLap(&timings.head, &timings.requests.head)

        // The first segment of the window: the stream's own first, or a day back, if the server still has it (one
        // request; the web player's DVR is no longer, and a 24/7 stream keeps a week, whose edge is slow to find).
        // Else the edge is looked for, coarsely, and the window starts a margin inside it.
        let candidate = max(0, newest - maxHistory)
        let first: Int
        if try await isAvailable(candidate) {
            first = candidate
        } else {
            let edge = try await SegmentTimeSearch.oldestAvailable(
                upTo: newest, tolerance: edgeTolerance, isAvailable: isAvailable)
            first = min(edge + edgeMargin, newest - (newest - edge) / 2)
            timings.firstFoundBy = "looking for the edge of the history"
        }
        closeLap(&timings.first, &timings.requests.first)

        // Times at an hour's distance, a few requests at once.
        var numbers = Array(stride(from: first, to: newest, by: anchorSpacing))
        numbers.append(newest)
        var anchors: [SegmentTimeSearch.Point] = [head]
        var index = 0
        while index < numbers.count {
            let batch = numbers[index..<min(index + fanOut, numbers.count)].filter { $0 != newest }
            index += fanOut
            let found = try await withThrowingTaskGroup(of: SegmentTimeSearch.Point.self) { group in
                for number in batch {
                    group.addTask { .init(number: number, time: try await start(of: number)) }
                }
                var points: [SegmentTimeSearch.Point] = []
                for try await point in group { points.append(point) }
                return points
            }
            anchors += found
        }

        closeLap(&timings.anchors, &timings.requests.anchors)
        let segmentDuration = segmentDuration(through: anchors)
        guard
            let window = SegmentedDASHManifest.window(
                through: anchors, lastNumber: newest, lastDuration: segmentDuration)
        else { throw Failure.noHead }
        // The manifest names a stream by its key, not by its signed address, which expires (`DASHPlaylists.address(of:)`).
        let keyed = streams.map { stream -> SegmentedDASHManifest.Stream in
            var stream = stream
            stream.url = LiveHistory.streamAddress(stream.id)
            return stream
        }
        var manifest = SegmentedDASHManifest(
            streams: keyed, segmentDuration: segmentDuration,
            segmentCount: newest - first + 1 + futureSegments)
        manifest.firstNumber = window.firstNumber
        manifest.startTime = window.startTime
        manifest.runs = window.runs + [.init(duration: segmentDuration, count: futureSegments)]
        return Window(
            manifest: manifest, firstNumber: first, lastNumber: newest, startTime: window.startTime,
            lastStartTime: newestStart, segmentDuration: segmentDuration,
            signedURLs: Dictionary(streams.map { ($0.id, $0.url) }) { first, _ in first },
            timings: timings)
    }
}
