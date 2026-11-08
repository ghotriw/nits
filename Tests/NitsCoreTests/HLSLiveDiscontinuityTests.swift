import CFFmpeg
import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// A live HLS stream with breaks (advertisement splices): the window slides, and `ffmpeg-hls-timeline.patch` has to put
/// the segments on one timeline while `ffmpeg-hls-live-seek.patch` moves the window. Serialized for the same reason as
/// `LiveStreamTests`.
@Suite(
    "Live HLS with discontinuities", .serialized, .hostDependent, .networkServer,
    .enabled(if: hasHLSTimelinePatch, "needs the bundled FFmpeg's patches"))
struct HLSLiveDiscontinuityTests {
    /// What the segments of the stream are.
    enum Kind: CaseIterable, CustomTestStringConvertible {
        /// Two segments of 4 s whose timestamps start at 0 (`hlsDiscontinuityTiming`), a break before each.
        case restart
        /// Server-side ad insertion (`hlsLiveAds`): content on a running timeline (1000 s and on, so a segment's number
        /// tells its timestamps), two segments of advertisement from 0 after every three of content, a break where the
        /// kind changes. The content after the advertisement is already on the time of the stream, as Mux's is.
        case ssai

        var testDescription: String { self == .restart ? "timestamps restart" : "content on a running timeline" }

        var preset: SyntheticTestMediaFactory.Preset { self == .restart ? .hlsDiscontinuityTiming : .hlsLiveAds }

        /// The segment of number `sequence`, and whether its timestamps restart (an advertisement does).
        func segment(_ sequence: Int) -> (name: String, isRestart: Bool) {
            switch self {
            case .restart: return ("seg\(sequence % 2)", true)
            case .ssai:
                let position = sequence % 5
                return position >= 3 ? ("ad\(position - 3)", true) : ("c\(sequence)", false)
            }
        }
    }

    /// A stream and the number of the first segment its playlist lists when it is opened. FFmpeg opens a live playlist
    /// at three segments before its end (number `firstAtOpen + 7` for a window of ten: the timestamp it probes there is
    /// the origin), and the demuxer then rewinds to the first segment listed, so what a plain read goes through is the
    /// window as it was at the open (`firstAtOpen` to `firstAtOpen + 9`), without waiting for the playlist to slide.
    struct Setup: CustomTestStringConvertible, Sendable {
        var kind: Kind
        var firstAtOpen: Int
        var testDescription: String { "\(kind.testDescription), opened at \(firstAtOpen)" }

        /// The origin is negative (the probe lands in a segment that restarts its timestamps) or positive (content).
        static let all = [
            // Every segment restarts: the origin is negative.
            Setup(kind: .restart, firstAtOpen: 3),
            // The probe lands at number 9, the second segment of advertisement (9 % 5 = 4): the origin is negative.
            Setup(kind: .ssai, firstAtOpen: 2),
            // The probe lands at number 10, content on 1012 s: the origin is positive; the read goes from the
            // advertisement of number 3.
            Setup(kind: .ssai, firstAtOpen: 3),
        ]
    }

    /// Pictures a read takes: 15 s at 30 fps.
    private static let pictures = 450

    /// The playlist lists `windowCount` segments from number `firstAtOpen` (a window that had slid when it was opened)
    /// and slides by one every `secondsPerSegment`, from the first request for it. `slides` gets how far it had slid at
    /// its last answer.
    private static func liveServer(
        _ kind: Kind, windowCount: Int, secondsPerSegment: Double, firstAtOpen: Int,
        slides: OSAllocatedUnfairLock<Int>? = nil
    ) throws -> TestHTTPServer? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: kind.preset) else { return nil }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: path).deletingLastPathComponent())
        let started = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        server.setResponder(forPath: "live.m3u8") {
            let start = started.withLock { started in
                if started == nil { started = .now }
                return started!
            }
            let slid = Int((ContinuousClock.now - start) / .seconds(secondsPerSegment))
            slides?.withLock { $0 = slid }
            let first = firstAtOpen + slid
            var lines = [
                "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:4", "#EXT-X-MEDIA-SEQUENCE:\(first)",
                "#EXT-X-DISCONTINUITY-SEQUENCE:\(first)",
            ]
            for index in first..<(first + windowCount) {
                let segment = kind.segment(index)
                // A break before and after a segment that restarts its timestamps (the second advertisement segment
                // restarts too), none between two of content.
                if index > first, segment.isRestart || kind.segment(index - 1).isRestart {
                    lines.append("#EXT-X-DISCONTINUITY")
                }
                lines += ["#EXTINF:4.000000,", segment.name + ".ts"]
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        return server
    }

    /// Watches until the clock reaches `time` or `limit` has passed, and tells how far the picture was from the clock at
    /// worst and where (the clock's time then). A sample taken before a picture is on the display is skipped:
    /// `currentFramePTS` is -1 until one is, which is no lag (it failed a test once as 35 s).
    @MainActor
    private static func watchLag(
        _ engine: PlayerEngine, until time: Double, within limit: Duration
    ) async throws -> (worst: Double, at: Double, sawPicture: Bool) {
        let deadline = ContinuousClock.now + limit
        var result = (worst: 0.0, at: 0.0, sawPicture: false)
        while engine.currentTime < time, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            guard engine.currentFramePTS >= 0 else { continue }
            result.sawPicture = true
            let lag = abs(engine.currentTime - engine.currentFramePTS)
            if lag > result.worst { (result.worst, result.at) = (lag, engine.currentTime) }
        }
        return result
    }

    private static func seconds(_ sample: CMSampleBuffer) -> Double {
        CMSampleBufferGetPresentationTimeStamp(sample).seconds
    }

    @Test(
        "A window that had slid when opened starts at 0, and picture and sound go on through its breaks",
        arguments: Setup.all)
    func windowStartsAtZero(_ setup: Setup) throws {
        // Ten segments listed: reading begins near the edge (see `Setup`), so the segments before it lie earlier
        // than the timestamp it starts at. The engine counts on times from 0.
        let slides = OSAllocatedUnfairLock(initialState: 0)
        guard
            let server = try Self.liveServer(
                setup.kind, windowCount: 10, secondsPerSegment: 1, firstAtOpen: setup.firstAtOpen, slides: slides)
        else {
            return
        }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        let window = try #require(demuxer.liveWindow)
        #expect(demuxer.isLive)
        // At 0, unless the open took a segment's length (4 s, in a full run): FFmpeg loads the playlist again before the
        // next segment then, and the window has slid by the server's slides of 4 s since (16 s, twice).
        let slid = slides.withLock { $0 }
        #expect(abs(window.start - Double(slid) * 4) < 0.5, "opened with \(window) after \(slid) slide(s)")
        #expect(window.length > 30, "\(window)")
        demuxer.startReadAhead()

        var times: [Double] = []
        var audio: [(start: Double, end: Double)] = []
        let audioTimebase = demuxer.audioTimebase
        while times.count < Self.pictures, let sample = demuxer.nextVideoSample() {
            times.append(Self.seconds(sample))
            while let packet = demuxer.nextAudioPacket() {
                let start = Double(packet.pts) * Double(audioTimebase.num) / Double(audioTimebase.den)
                let length = Double(packet.duration) * Double(audioTimebase.num) / Double(audioTimebase.den)
                audio.append((start, start + length))
                if start > (times.last ?? 0) + 0.5 { break }
            }
        }
        #expect(times.count == Self.pictures, "\(times.count) pictures")
        #expect((times.min() ?? -1) >= -0.1, "A picture at \(times.min() ?? 0) s")
        let step = zip(times, times.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(step < 0.2, "A step of \(step) s between pictures: the breaks are not one timeline")

        #expect(audio.count > Self.pictures / 30 * 40, "\(audio.count) audio packets of \(Self.pictures / 30) s")
        #expect((audio.map(\.start).min() ?? -1) >= -0.2, "A sound at \(audio.map(\.start).min() ?? 0) s")
        let worstGap = zip(audio, audio.dropFirst()).map { abs($1.start - $0.end) }.max() ?? 0
        #expect(worstGap < 0.15, "A gap or overlap of \(worstGap) s in the sound")
    }

    @Test("Read from content near the edge through an advertisement and back to content, the timeline goes on")
    func edgeThroughAnAdvertisement() throws {
        // Where the engine reads a live stream from: content (number 10, on 1012 s), then the advertisement (13, 14, from
        // 0 s), then content again (15 on) whose timestamps are already 8 s on, on the time of the stream: the offset the
        // advertisement took is dropped there (a difference of 0 against the playlist). The playlist slides while this is
        // read, a segment a second: the content is made up to number 29, and the playlist of a test must not reach past it.
        guard let server = try Self.liveServer(.ssai, windowCount: 10, secondsPerSegment: 1, firstAtOpen: 3) else {
            return
        }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        let window = try #require(demuxer.liveWindow)
        demuxer.startReadAhead()
        let edge = window.start + 28
        _ = demuxer.seek(to: edge, exact: false)

        var times: [Double] = []
        var audio: [(start: Double, end: Double)] = []
        let audioTimebase = demuxer.audioTimebase
        // 28 s: number 10 to 16.
        while times.count < 840, let sample = demuxer.nextVideoSample() {
            times.append(Self.seconds(sample))
            while let packet = demuxer.nextAudioPacket() {
                let start = Double(packet.pts) * Double(audioTimebase.num) / Double(audioTimebase.den)
                let length = Double(packet.duration) * Double(audioTimebase.num) / Double(audioTimebase.den)
                audio.append((start, start + length))
                if start > (times.last ?? 0) + 0.5 { break }
            }
        }
        // That the read went through the advertisement and on to content again (the picture times alone cannot tell):
        // the segments asked for. The playlist slides a segment a second, so a read that took longer than about 13 s from
        // the open would find number 16 gone from it.
        let asked = Set(server.requests.map(\.path))
        #expect(asked.isSuperset(of: ["c15.ts", "c16.ts"]), "Segments asked for: \(asked.sorted())")
        #expect(times.count == 840, "\(times.count) pictures")
        let first = try #require(times.first)
        #expect(abs(first - edge) < 4.5, "A seek to \(edge) s landed at \(first) s")
        let step = zip(times, times.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(step < 0.2, "A step of \(step) s between pictures, from \(first) s to \(times.last ?? 0) s")
        #expect((times.last ?? 0) > first + 26, "The pictures end at \(times.last ?? 0) s from \(first) s")
        let worstGap = zip(audio, audio.dropFirst()).map { abs($1.start - $0.end) }.max() ?? 0
        #expect(worstGap < 0.15, "A gap or overlap of \(worstGap) s in the sound")
    }

    @Test(
        "A keyframe seek in the window lands within a segment of its target, across the breaks",
        arguments: Setup.all)
    func seekInTheWindow(_ setup: Setup) throws {
        guard
            let server = try Self.liveServer(
                setup.kind, windowCount: 10, secondsPerSegment: 1, firstAtOpen: setup.firstAtOpen)
        else {
            return
        }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        demuxer.startReadAhead()
        _ = demuxer.nextVideoSample()
        let window = try #require(demuxer.liveWindow)
        for fraction in [0.15, 0.4, 0.65, 0.9] {
            let target = window.start + window.length * fraction
            _ = demuxer.seek(to: target, exact: false)
            let sample = try #require(demuxer.nextVideoSample(), "A seek to \(target) s")
            let landed = Self.seconds(sample)
            #expect(landed <= target + 0.1 && landed > target - 4.5, "A seek to \(target) s landed at \(landed) s")
        }
    }

    @Test(
        "The picture follows the clock through the breaks, and a seek to the oldest place allowed plays on",
        .realtimePlayback)
    @MainActor
    func enginePlaysAndSeeksThroughBreaks() async throws {
        // 40 s listed, sliding at the pace of the clock; the seeks keep a margin from both ends of such a window.
        guard
            let server = try Self.liveServer(
                .restart, windowCount: 10, secondsPerSegment: 4, firstAtOpen: 3)
        else {
            return
        }
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        await engine.loadAsync(MediaLoadRequest(path: server.url("live.m3u8")))
        #expect(engine.isLoaded)
        #expect(engine.live.isLive)
        #expect((engine.live.window()?.start ?? -1) >= -0.5, "\(String(describing: engine.live.window()))")
        engine.play()

        // Five seconds on: a break has passed (each segment of this stream restarts its timestamps).
        let startedAt = engine.currentTime
        let lag = try await Self.watchLag(engine, until: startedAt + 5, within: .seconds(15))
        #expect(lag.sawPicture, "No picture came in 5 s")
        #expect(engine.currentTime >= startedAt + 5, "Playback reached \(engine.currentTime) s from \(startedAt)")
        // Failed twice on this check, in the first run after a build each time. The second said 35 s at 0 s from the
        // start: a first sample before the first picture (currentFramePTS is -1), which the loop skips now. The first
        // failure's message was not kept, so it may have been that or something else; a lag elsewhere would show in the time.
        #expect(
            lag.worst < 0.6, "The picture was \(lag.worst) s from the clock, \(lag.at - startedAt) s after the start")

        // To the oldest place a seek is allowed: the window's start plus the margin.
        let window = try #require(engine.live.window())
        let target = window.start + LiveStream.startMargin
        engine.seek(to: target, exact: true)
        #expect(await engine.waitForSeekToSettle())
        let landed = engine.currentTime
        #expect(abs(landed - target) < 2, "Asked \(target) s, the clock is at \(landed) s")
        try await Task.sleep(for: .seconds(2))
        #expect(engine.currentTime > landed + 1.5, "The clock stood at \(landed) s, then \(engine.currentTime) s")
        #expect(abs(engine.currentTime - engine.currentFramePTS) < 0.6, "pts \(engine.currentFramePTS) s")
        #expect(engine.droppedFramesCount < 20, "\(engine.droppedFramesCount) pictures dropped")
    }
}

extension HLSLiveDiscontinuityTests {
    @Test("An EVENT playlist whose segments restart their timestamps starts at 0 and goes on through its breaks")
    func eventPlaylistStartsAtZero() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsDiscontinuityTiming) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: path).deletingLastPathComponent())
        defer { server.stop() }
        server.setResponder(forPath: "event.m3u8") {
            var lines = [
                "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:4", "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-PLAYLIST-TYPE:EVENT",
            ]
            for index in 0..<10 {
                if index > 0 { lines.append("#EXT-X-DISCONTINUITY") }
                lines += ["#EXTINF:4.000000,", "seg\(index % 2).ts"]
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        // FFmpeg reads an unfinished EVENT playlist from three segments before its end, so the segments before that lie
        // earlier than the timestamp it starts at: the first picture used to come at -2.5 s.
        let demuxer = try #require(MediaDemuxer(url: server.url("event.m3u8")))
        demuxer.startReadAhead()
        var times: [Double] = []
        while times.count < 300, let sample = demuxer.nextVideoSample() { times.append(Self.seconds(sample)) }
        #expect(times.count == 300, "\(times.count) pictures")
        #expect((times.first ?? -1) >= -0.1, "The first picture at \(times.first ?? 0) s")
        let step = zip(times, times.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(step < 0.2, "A step of \(step) s between pictures")

        // A seek lands on the timeline from 0 too (it went to a negative target before).
        for target in [2.0, 12.0, 25.0] {
            _ = demuxer.seek(to: target, exact: false)
            let sample = try #require(demuxer.nextVideoSample(), "A seek to \(target) s")
            let landed = Self.seconds(sample)
            #expect(landed <= target + 0.1 && landed > target - 4.5, "A seek to \(target) s landed at \(landed) s")
        }
    }
}

extension HLSLiveDiscontinuityTests {
    @Test(
        "The engine plays into an advertisement and back to content, the picture with the clock",
        .realtimePlayback)
    @MainActor
    func engineCrossesAnAdvertisement() async throws {
        // On the timeline of the window as opened (number 3 at 0 s, a segment every 4 s): the advertisement is number 8
        // and 9, at 20 and 24 s, content is on again at 28 s. The engine starts near the edge (34 s), so each border is
        // reached by a seek to just short of it: into the advertisement from 18 s, and out of it, where the offset the
        // advertisement took is dropped, from 26 s. Both stay within the seeks' margin (10 s from the window's start, which
        // moves a second a second) for the few seconds the test takes.
        guard let server = try Self.liveServer(.ssai, windowCount: 10, secondsPerSegment: 4, firstAtOpen: 3) else {
            return
        }
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        await engine.loadAsync(MediaLoadRequest(path: server.url("live.m3u8")))
        #expect(engine.live.isLive)
        engine.play()

        for (from, border) in [(18.0, 20.0), (26.0, 28.0)] {
            engine.seek(to: from, exact: true)
            #expect(await engine.waitForSeekToSettle())
            #expect(abs(engine.currentTime - from) < 2, "Asked \(from) s, the clock is at \(engine.currentTime) s")

            let lag = try await Self.watchLag(engine, until: border + 1.5, within: .seconds(8))
            #expect(lag.sawPicture, "No picture came, border \(border) s")
            #expect(
                engine.currentTime >= border + 1.5, "The clock stood at \(engine.currentTime) s, border \(border) s")
            #expect(
                engine.currentFramePTS > border + 0.3,
                "The picture is at \(engine.currentFramePTS) s, border \(border) s")
            #expect(
                lag.worst < 0.6, "The picture was \(lag.worst) s from the clock, at \(lag.at) s, border \(border) s")
        }
        #expect(engine.droppedFramesCount < 20, "\(engine.droppedFramesCount) pictures dropped")
    }
}
