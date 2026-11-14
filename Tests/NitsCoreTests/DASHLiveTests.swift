import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// A dynamic MPD told to the client as playlists that slide (`DASHLive.swift`): the window the clock gives, the numbers a
/// timeline keeps, the manifest fetched again when it says it changes, the server's clock from `UTCTiming`.
/// The manifests start at the epoch (`availabilityStartTime` 1970), so a clock reading of `t` seconds is `t` s of the period.
@Suite("DASH live", .serialized, .networkServer)
struct DASHLiveTests {
    static let url = URL(string: "https://cdn.example/live/manifest.mpd")!

    /// A dynamic manifest of `body` (the period's contents) with `attributes` on the MPD.
    static func mpd(_ body: String, attributes: String = "", start: String = "1970-01-01T00:00:00Z") -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic" availabilityStartTime="\(start)" \
            minBufferTime="PT2S" \(attributes)><Period start="PT0S">\(body)</Period></MPD>
            """.utf8)
    }

    static func video(_ id: String = "v", bandwidth: Int = 1_000_000, template: String) -> String {
        """
        <AdaptationSet contentType="video"><Representation id="\(id)" codecs="avc1.4d401f" width="640" height="360" \
        bandwidth="\(bandwidth)">\(template)</Representation></AdaptationSet>
        """
    }

    /// 2 s segments counted by the clock, from number 1.
    static let counted = #"<SegmentTemplate timescale="1" duration="2" startNumber="1" media="seg-$Number$.m4s"/>"#
    /// 2 s segments of a timeline that repeats to the edge.
    static let timeline = """
        <SegmentTemplate timescale="1000" startNumber="1" media="seg-$Time$.m4s">\
        <SegmentTimeline><S t="0" d="2000" r="-1"/></SegmentTimeline></SegmentTemplate>
        """

    static func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    static func parse(_ data: Data, at seconds: Double) throws -> DASHPresentation {
        try DASHPresentation.parse(data, url: url, now: at(seconds))
    }

    /// The only picture's segments at the clock `seconds`.
    static func segments(_ data: Data, at seconds: Double) throws -> [DASHPresentation.Segment] {
        try #require(try parse(data, at: seconds).representations.first).segments
    }

    // MARK: - The window

    @Test(
        "A template counted by its length lists the segments that have come whole, the last depth's worth, numbered by the clock"
    )
    func countedWindow() throws {
        let data = Self.mpd(Self.video(template: Self.counted), attributes: #"timeShiftBufferDepth="PT10S""#)
        let first = try Self.segments(data, at: 100)
        // Ends by 100: the last is 49 (98..100); 10 s back from 100: 45 (90..92) on.
        #expect(first.map(\.start) == [90, 92, 94, 96, 98])
        #expect(first.map(\.number) == [46, 47, 48, 49, 50])
        #expect(first.last?.url.lastPathComponent == "seg-50.m4s")
        // A second later nothing has come whole; the next one comes at 102.
        #expect(try Self.segments(data, at: 101).map(\.number) == [46, 47, 48, 49, 50])
        #expect(try Self.segments(data, at: 102).map(\.number) == [47, 48, 49, 50, 51])
    }

    @Test("availabilityTimeOffset makes a segment available that much before its end")
    func availabilityTimeOffset() throws {
        let template =
            #"<SegmentTemplate timescale="1" duration="2" startNumber="1" availabilityTimeOffset="1.5" media="s$Number$"/>"#
        let data = Self.mpd(Self.video(template: template), attributes: #"timeShiftBufferDepth="PT6S""#)
        // 98..100 is available from 98.5.
        #expect(try Self.segments(data, at: 98.4).map(\.number) == [47, 48, 49])
        #expect(try Self.segments(data, at: 98.5).map(\.number) == [48, 49, 50])
        #expect(
            Self.refusal(of: Self.mpd(Self.video(template: template.replacingOccurrences(of: "1.5", with: "INF"))))
                != nil)
    }

    @Test(
        "A timeline repeated to the edge lists whole segments only, trimmed to the depth, numbered after those dropped")
    func timelineWindow() throws {
        let data = Self.mpd(Self.video(template: Self.timeline), attributes: #"timeShiftBufferDepth="PT10S""#)
        let segments = try Self.segments(data, at: 21)
        // Whole by 21: ten (0..20); 10 s back from 20: those ending after 10.
        #expect(segments.map(\.start) == [10, 12, 14, 16, 18])
        #expect(segments.map(\.number) == [6, 7, 8, 9, 10])
        #expect(segments.first?.url.lastPathComponent == "seg-10000.m4s")
    }

    @Test("A timeline's own list is the window: listed segments are available, whatever the clock says")
    func listedTimeline() throws {
        let template = """
            <SegmentTemplate timescale="1000" startNumber="1" media="seg-$Time$.m4s">\
            <SegmentTimeline><S t="50000" d="2000" r="3"/></SegmentTimeline></SegmentTemplate>
            """
        let data = Self.mpd(Self.video(template: template))
        #expect(try Self.segments(data, at: 0).map(\.start) == [50, 52, 54, 56])
        #expect(try Self.segments(data, at: 1000).map(\.start) == [50, 52, 54, 56])
    }

    @Test("Without a depth the window is bounded by maxHistory")
    func boundedHistory() throws {
        let data = Self.mpd(Self.video(template: Self.counted))
        let now = 3 * 24 * 3600.0
        let segments = try Self.segments(data, at: now)
        #expect(segments.count == Int(DASHPresentation.maxHistory / 2))
        #expect(abs((segments.first?.start ?? 0) - (now - DASHPresentation.maxHistory)) <= 2)
    }

    static func refusal(of data: Data, at seconds: Double = 100) -> String? {
        do throws(DASHPresentationError) {
            _ = try DASHPresentation.parse(data, url: url, now: at(seconds))
            return nil
        } catch {
            if case .unsupported(let reason) = error { return reason }
            return "\(error)"
        }
    }

    @Test("A dynamic manifest needs its availabilityStartTime and a clock; several periods and one file are refused")
    func refusals() {
        let noStart = Data(
            #"<MPD type="dynamic"><Period>\#(Self.video(template: Self.counted))</Period></MPD>"#.utf8)
        #expect(Self.refusal(of: noStart)?.contains("availabilityStartTime") == true)
        #expect(throws: DASHPresentationError.unsupported("a dynamic manifest (live)")) {
            try DASHPresentation.parse(Self.mpd(Self.video(template: Self.counted)), url: Self.url)
        }
        let one = #"<SegmentBase indexRange="100-200"><Initialization range="0-99"/></SegmentBase>"#
        #expect(Self.refusal(of: Self.mpd(Self.video(template: one)))?.contains("SegmentBase") == true)
    }

    @Test("Numbers past what a count or a time holds are refused, not a crash")
    func hugeNumbers() {
        // Segments of a tick in the largest timescale: more by the clock than a count holds.
        let tiny = #"<SegmentTemplate timescale="9223372036854775807" duration="1" media="s$Number$"/>"#
        #expect(Self.refusal(of: Self.mpd(Self.video(template: tiny))) != nil)
        // Second-long segments in a timescale whose ticks by the clock are past what a time holds.
        let large =
            #"<SegmentTemplate timescale="9000000000000000000" duration="9000000000000000000" media="s$Number$"/>"#
        #expect(Self.refusal(of: Self.mpd(Self.video(template: large))) != nil)
    }

    @Test("A depth past what a time holds in the timescale reaches back past every segment: none is dropped")
    func depthPastTheTimescale() throws {
        let listed = """
            <SegmentTemplate timescale="9000000000000000000" media="s$Time$">\
            <SegmentTimeline><S t="0" d="1000" r="1"/></SegmentTimeline></SegmentTemplate>
            """
        let deep = Self.mpd(Self.video(template: listed), attributes: #"timeShiftBufferDepth="PT10S""#)
        #expect(try Self.segments(deep, at: 0.5).count == 2)
    }

    @Test("What the manifest tells of itself: update period, depth, delay, clock descriptors, location")
    func attributes() throws {
        let data = Self.mpd(
            Self.video(template: Self.counted),
            attributes: #"""
                minimumUpdatePeriod="PT2S" timeShiftBufferDepth="PT30S" suggestedPresentationDelay="PT6S"
                """#)
        let live = try #require(try Self.parse(data, at: 10).live)
        #expect(live.minimumUpdatePeriod == 2)
        #expect(live.depth == 30)
        #expect(live.suggestedPresentationDelay == 6)
        #expect(live.edge == 10)
    }

    // MARK: - Numbers

    /// The playlists of a source over `data` read at the clock `now` (seconds, changed by the test).
    static func source(_ data: Data, now: OSAllocatedUnfairLock<Double>) -> DASHPlaylists {
        DASHPlaylists(address: url, inline: data, clock: { at(now.withLock { $0 }) })
    }

    static func loader() -> HLSSegmentLoader {
        HLSSegmentLoader(transport: HTTPSessionTransport(source: url.absoluteString, headers: [:]) { false })
    }

    /// The media playlist of the source's first picture.
    static func media(_ source: DASHPlaylists, _ loader: HLSSegmentLoader) throws -> HLSMediaPlaylist {
        guard case .master(let master) = try source.playlist(at: source.masterURL, variables: [:], loader: loader),
            let variant = master.variants.first,
            case .media(let media) = try source.playlist(at: variant.url, variables: [:], loader: loader)
        else { throw HLSPlaylistError.mixedTypes }
        return media
    }

    @Test("A timeline that slides keeps its segments' numbers by time, however the manifest numbers them")
    func numbersAcrossReloads() throws {
        // The manifest's `$Time$` template says no number for a segment: its first entry is number 1 at every slide.
        let data = Self.mpd(Self.video(template: Self.timeline), attributes: #"timeShiftBufferDepth="PT10S""#)
        let now = OSAllocatedUnfairLock(initialState: 21.0)
        let source = Self.source(data, now: now)
        let loader = Self.loader()
        let first = try Self.media(source, loader)
        #expect(first.isLive)
        #expect(first.segments.map(\.sequence) == [6, 7, 8, 9, 10])
        now.withLock { $0 = 27 }
        let later = try Self.media(source, loader)
        // Whole by 27: 0..26, 13 segments; 10 s back from 26: from 16.
        #expect(later.segments.map(\.sequence) == [9, 10, 11, 12, 13])
        #expect(later.segments.map(\.url.lastPathComponent).first == "seg-16000.m4s")
        // The segments both listed are the same ones.
        #expect(first.segments.suffix(2).map(\.url) == later.segments.prefix(2).map(\.url))
        // A window that slid past everything the last one listed continues after the gap.
        now.withLock { $0 = 61 }
        let far = try Self.media(source, loader)
        #expect(far.segments.first?.sequence == 26)
        #expect(abs((far.segments.first?.programDateTime?.timeIntervalSince1970 ?? 0) - 50) < 0.001)
    }

    @Test("A live playlist carries the hold-back, the dates and a target duration; a manifest that turned static ends")
    func playlistFields() throws {
        let live = Self.mpd(
            Self.video(template: Self.counted),
            attributes: #"timeShiftBufferDepth="PT10S" suggestedPresentationDelay="PT6S""#)
        let now = OSAllocatedUnfairLock(initialState: 100.0)
        let source = Self.source(live, now: now)
        let loader = Self.loader()
        let playlist = try Self.media(source, loader)
        #expect(playlist.holdBack == 6)
        #expect(playlist.targetDuration == 2)
        #expect(playlist.hasEnded == false)
        #expect(playlist.programDateTime(of: 0) == Self.at(90))
    }

    // MARK: - Fetching

    @Test("A fetch that fails leaves the manifest held in use; the next ask that finds it due tries again")
    func keepsTheManifestWhenAFetchFails() throws {
        let server = try TestHTTPServer(root: FileManager.default.temporaryDirectory)
        defer { server.stop() }
        let text = Self.mpd(Self.video(template: Self.counted), attributes: #"minimumUpdatePeriod="PT2S""#)
        server.setResponder(forPath: "live.mpd") { text }
        let address = URL(string: server.url("live.mpd"))!
        let now = OSAllocatedUnfairLock(initialState: 100.0)
        let source = DASHPlaylists(address: address, clock: { Self.at(now.withLock { $0 }) })
        func fetches() -> Int { server.requests.filter { $0.path.hasSuffix("live.mpd") }.count }
        let loader = Self.loader(for: address)
        #expect(try Self.media(source, loader).segments.last?.sequence == 50)
        server.setBehavior(.init(failure: .status(503)), forPaths: { $0.hasSuffix("live.mpd") })
        now.withLock { $0 = 104 }
        // Due, and the fetch fails: the manifest held is read at the clock now.
        #expect(try Self.media(source, loader).segments.last?.sequence == 52)
        let failed = fetches()
        #expect(failed >= 2, "the due fetch was made: \(failed)")
        now.withLock { $0 = 105 }
        #expect(try Self.media(source, loader).segments.last?.sequence == 52)
        #expect(fetches() > failed, "asked again at the next ask")
        let failedTwice = fetches()
        // An answer that does not read is no better than one that failed.
        server.setBehavior(.init(), forPaths: { $0.hasSuffix("live.mpd") })
        server.setResponder(forPath: "live.mpd") { Data("<MPD".utf8) }
        #expect(try Self.media(source, loader).segments.last?.sequence == 52)
        #expect(fetches() > failedTwice)
        let unreadable = fetches()
        // The server answers again, with a manifest that numbers its segments from 11: due 2 s after the last answer.
        let renumbered = Self.mpd(
            Self.video(
                template: Self.counted.replacingOccurrences(of: #"startNumber="1""#, with: #"startNumber="11""#)),
            attributes: #"minimumUpdatePeriod="PT2S""#)
        server.setResponder(forPath: "live.mpd") { renumbered }
        now.withLock { $0 = 106 }
        #expect(try Self.media(source, loader).segments.last?.sequence == 53, "not due yet")
        now.withLock { $0 = 107 }
        #expect(try Self.media(source, loader).segments.last?.sequence == 63)
        #expect(fetches() > unreadable, "fetched again once the server answers")
    }

    @Test(
        "A live manifest that comes to list a period after the one played (an ad break) plays that one up to the next's start, then ends"
    )
    func playsThePeriodUpToTheNext() throws {
        let server = try TestHTTPServer(root: FileManager.default.temporaryDirectory)
        defer { server.stop() }
        let video = Self.video(template: Self.counted)
        server.setResponder(forPath: "live.mpd") {
            Self.mpd(video, attributes: #"minimumUpdatePeriod="PT2S""#)
        }
        let address = URL(string: server.url("live.mpd"))!
        let now = OSAllocatedUnfairLock(initialState: 100.0)
        let source = DASHPlaylists(address: address, clock: { Self.at(now.withLock { $0 }) })
        let loader = Self.loader(for: address)
        #expect(try Self.media(source, loader).segments.last?.sequence == 50)
        func breakAt(_ start: Int) -> Data {
            Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic" availabilityStartTime="1970-01-01T00:00:00Z" \
                minBufferTime="PT2S" minimumUpdatePeriod="PT2S"><Period id="0" start="PT0S">\(video)</Period>\
                <Period id="1" start="PT\(start)S">\(video)</Period></MPD>
                """.utf8)
        }
        // Told before it comes: the period played goes on to it.
        let announced = breakAt(200)
        server.setResponder(forPath: "live.mpd") { announced }
        now.withLock { $0 = 104 }
        let before = try Self.media(source, loader)
        #expect(before.hasEnded == false)
        #expect(before.segments.last?.sequence == 52)
        now.withLock { $0 = 201 }
        let ended = try Self.media(source, loader)
        #expect(ended.hasEnded)
        #expect(ended.segments.last?.sequence == 100, "the last segment ends at the break (198..200), none after it")
    }

    @Test(
        "A break told after it came ends the period played at its start: the segments up to it are listed, the last cut"
    )
    func breakAlreadyPast() throws {
        let video = Self.video(template: Self.counted)
        let now = OSAllocatedUnfairLock(initialState: 100.0)
        let source = Self.source(Self.mpd(video), now: now)
        #expect(try Self.media(source, Self.loader()).segments.last?.sequence == 50)
        let data = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic" availabilityStartTime="1970-01-01T00:00:00Z" \
            minBufferTime="PT2S"><Period id="0" start="PT0S">\(video)</Period>\
            <Period id="1" start="PT103S">\(video)</Period></MPD>
            """.utf8)
        let presentation = try DASHPresentation.parse(data, url: Self.url, now: Self.at(104), livePeriodStart: 0)
        let segments = try #require(presentation.representations.first).segments
        #expect(presentation.periodDuration == 103)
        #expect(segments.last?.start == 102)
        #expect(segments.last?.duration == 1)
        // Without the period played (the opening) several periods are refused; one no longer listed is refused too.
        #expect(Self.refusal(of: data)?.contains("2 periods") == true)
        #expect(throws: DASHPresentationError.unsupported("the period played is no longer in the manifest")) {
            try DASHPresentation.parse(data, url: Self.url, now: Self.at(104), livePeriodStart: 50)
        }
    }

    @Test("A delay of 0 is no nearer the edge than a segment")
    func zeroDelay() throws {
        let data = Self.mpd(Self.video(template: Self.counted), attributes: #"suggestedPresentationDelay="PT0S""#)
        let source = Self.source(data, now: OSAllocatedUnfairLock(initialState: 100.0))
        #expect(try Self.media(source, Self.loader()).holdBack == 2)
    }

    @Test("The manifest is fetched again once its update period has passed, once for the asks that come together")
    func refetches() throws {
        let server = try TestHTTPServer(root: FileManager.default.temporaryDirectory)
        defer { server.stop() }
        let generation = OSAllocatedUnfairLock(initialState: 0)
        // Each fetch tells one more segment in its timeline: the manifest's own list.
        server.setResponder(forPath: "live.mpd") {
            let count = 3 + generation.withLock { $0 }
            let template = """
                <SegmentTemplate timescale="1" startNumber="1" media="seg-$Number$.m4s">\
                <SegmentTimeline><S t="0" d="2" r="\(count - 1)"/></SegmentTimeline></SegmentTemplate>
                """
            return Self.mpd(Self.video(template: template), attributes: #"minimumUpdatePeriod="PT2S""#)
        }
        func fetches() -> Int { server.requests.filter { $0.path.hasSuffix("live.mpd") }.count }
        let address = URL(string: server.url("live.mpd"))!
        let now = OSAllocatedUnfairLock(initialState: 10.0)
        let source = DASHPlaylists(address: address, clock: { Self.at(now.withLock { $0 }) })
        let loader = Self.loader(for: address)
        #expect(try Self.media(source, loader).segments.count == 3)
        #expect(try Self.media(source, loader).segments.count == 3)
        #expect(fetches() == 1)
        generation.withLock { $0 = 1 }
        now.withLock { $0 = 11 }
        #expect(try Self.media(source, loader).segments.count == 3, "not due yet")
        #expect(fetches() == 1)
        now.withLock { $0 = 12.5 }
        #expect(try Self.media(source, loader).segments.count == 4)
        #expect(try Self.media(source, loader).segments.count == 4)
        #expect(fetches() == 2)
    }

    static func loader(for address: URL) -> HLSSegmentLoader {
        HLSSegmentLoader(transport: HTTPSessionTransport(source: address.absoluteString, headers: [:]) { false })
    }

    @Test(
        "The server's clock from UTCTiming (direct, http-iso, http-head) moves the edge; one that fails is passed over")
    func clockOffset() throws {
        let server = try TestHTTPServer(root: FileManager.default.temporaryDirectory)
        defer { server.stop() }
        server.setResponder(forPath: "time") { Data("1970-01-01T00:01:40Z".utf8) }
        let template = Self.video(template: Self.counted)
        func edge(_ timing: String) throws -> Int? {
            let data = Self.mpd(template, attributes: "").withTiming(timing)
            let source = DASHPlaylists(
                address: URL(string: server.url("live.mpd"))!, inline: data, clock: { Self.at(0) })
            let loader = Self.loader(for: URL(string: server.url("live.mpd"))!)
            return try Self.media(source, loader).segments.last?.sequence
        }
        // Host clock 0, server clock 100: the last segment that has come is the 50th.
        #expect(
            try edge(#"<UTCTiming schemeIdUri="urn:mpeg:dash:utc:direct:2014" value="1970-01-01T00:01:40Z"/>"#) == 50)
        let iso = #"<UTCTiming schemeIdUri="urn:mpeg:dash:utc:http-iso:2014" value="\#(server.url("time"))"/>"#
        #expect(try edge(iso) == 50)
        let missing = #"<UTCTiming schemeIdUri="urn:mpeg:dash:utc:http-iso:2014" value="\#(server.url("none"))"/>"#
        #expect(
            try edge(
                missing + #"<UTCTiming schemeIdUri="urn:mpeg:dash:utc:direct:2014" value="1970-01-01T00:01:40Z"/>"#)
                == 50)
        // None that answers: the host's clock, and no segment has come whole at 0.
        #expect(try edge(#"<UTCTiming schemeIdUri="urn:mpeg:dash:utc:ntp:2014" value="x"/>"#) == nil)
    }
}

extension HLSMediaPlaylist {
    /// The date of the segment at `index`.
    fileprivate func programDateTime(of index: Int) -> Date? { segments[index].programDateTime }
}

extension Data {
    /// A manifest with `timing` as its first child.
    fileprivate func withTiming(_ timing: String) -> Data {
        let text = String(decoding: self, as: UTF8.self)
        return Data(text.replacingOccurrences(of: "<Period", with: timing + "<Period").utf8)
    }
}

/// The client playing a live manifest of the `dashLadder` preset's segments (twelve of 1 s, `video0/<n>`…, n from 0), the
/// clock held at one reading.
@Suite("DASH live playback", .serialized, .networkServer)
struct DASHLivePlaybackTests {
    /// A live manifest of the ladder, its segments counted by the clock from number 0.
    static func manifest(_ server: TestHTTPServer, attributes: String = "") -> Data {
        var sets = SyntheticTestMediaFactory.dashLadderRungs.enumerated().map { index, rung in
            """
            <AdaptationSet contentType="video" segmentAlignment="true"><Representation id="v\(index)" \
            codecs="avc1.64001e" width="\(rung.width)" height="\(rung.height)" bandwidth="\(rung.bitrate)">\
            <SegmentTemplate timescale="1" duration="1" startNumber="0" media="\(server.url("video\(index)"))/$Number$"/>\
            </Representation></AdaptationSet>
            """
        }
        sets.append(
            """
            <AdaptationSet contentType="audio"><Representation id="a" codecs="mp4a.40.2" bandwidth="64000">\
            <SegmentTemplate timescale="1" duration="1" startNumber="0" media="\(server.url("audio"))/$Number$"/>\
            </Representation></AdaptationSet>
            """)
        return DASHLiveTests.mpd(sets.joined(), attributes: attributes)
    }

    @Test("A live manifest opens as a live ladder with its window and plays its segments in order")
    func playsFromTheEdge() throws {
        guard let server = try DASHClientTests.server() else { return }
        defer { server.stop() }
        let data = Self.manifest(server, attributes: #"suggestedPresentationDelay="PT3S""#)
        // 8.5 s: segments 0..7 have come whole.
        let source = DASHPlaylists(
            address: URL(string: server.url("live.mpd"))!, inline: data, clock: { DASHLiveTests.at(8.5) })
        let demuxer = try #require(DASHClientTests.demuxer(source))
        #expect(demuxer.isLive)
        #expect(demuxer.variants.count == SyntheticTestMediaFactory.dashLadderRungs.count)
        #expect(demuxer.hasAudio)
        let window = try #require(demuxer.liveWindow)
        #expect(window.start == 0 && window.end == 8, "\(window)")
        #expect(window.holdBack == 3)
        // A demuxer read as it is starts at the window's start: the engine seeks to the edge (`LiveStream.edgeTarget`).
        var times: [Double] = []
        while times.count < 50, let sample = demuxer.nextVideoSample() {
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        #expect(times.count == 50)
        #expect(abs(times.min() ?? -1) < 0.1, "from \(times.sorted().prefix(3))")
        let steps = zip(times.sorted().dropFirst(), times.sorted()).map { $0 - $1 }
        #expect(steps.allSatisfy { abs($0 - 0.04) < 0.002 }, "irregular steps")
    }
}

@Suite("DASH live playback in real time", .serialized, .networkServer, .realtimePlayback, .backstopTimeLimit)
struct DASHLiveRealtimeTests {
    @Test("The window moves with the clock: segments that come while playing follow one another without a gap")
    func followsTheEdge() throws {
        guard let server = try DASHClientTests.server() else { return }
        defer { server.stop() }
        let data = DASHLivePlaybackTests.manifest(server, attributes: #"minimumUpdatePeriod="PT1S""#)
        // 4.2 s at the opening: segments 0..3; the next ones come at 5, 6 s of the clock (0.8 s, 1.8 s later).
        let begin = ContinuousClock.now
        let source = DASHPlaylists(
            address: URL(string: server.url("live.mpd"))!, inline: data,
            clock: { DASHLiveTests.at(4.2 + (ContinuousClock.now - begin) / .seconds(1)) })
        let demuxer = try #require(DASHClientTests.demuxer(source))
        #expect(demuxer.isLive)
        demuxer.startReadAhead()
        var times: [Double] = []
        while times.count < 150, let sample = demuxer.nextVideoSample() {
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        #expect(times.count == 150, "\(times.count) pictures")
        let steps = zip(times.sorted().dropFirst(), times.sorted()).map { $0 - $1 }
        #expect(
            steps.allSatisfy { abs($0 - 0.04) < 0.002 },
            "a gap or a repeat in \(steps.filter { abs($0 - 0.04) >= 0.002 })")
        let window = try #require(demuxer.liveWindow)
        #expect(window.end >= 6, "\(window)")
    }
}
