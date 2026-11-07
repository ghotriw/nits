import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// Whether the FFmpeg linked is the one built by `scripts/setup_dependencies.sh`, which carries our patch of the HLS
/// demuxer (`scripts/patches/ffmpeg-hls-live-seek.patch`). Another (Homebrew's fallback) tells no live window.
enum BundledFFmpeg {
    static let isLinked: Bool = {
        let version: @convention(c) () -> UInt32 = avformat_version
        var info = Dl_info()
        guard dladdr(unsafeBitCast(version, to: UnsafeRawPointer.self), &info) != 0, let name = info.dli_fname else {
            return false
        }
        return String(cString: name).contains("/.build/dependencies/")
    }()
}

private let needsBundledFFmpeg: ConditionTrait = .enabled(
    if: BundledFFmpeg.isLinked, "needs the bundled FFmpeg with the live HLS patch")

/// The window of a live stream: what `LiveStream` makes of it, and what the demuxer tells of a playlist that slides.
/// Serialized: the demuxer tests below block a thread of the cooperative pool each while FFmpeg reads from a test server,
/// and a run of the HTTP suites together has no thread left for the servers once enough of them do (every thread blocked
/// on a server that has none to answer on). Mine are one at a time.
@Suite("Live stream", .serialized, .networkServer)
struct LiveStreamTests {
    // MARK: LiveStream

    @MainActor
    @Test("A stream that is not live has no window: no edge, and a seek not before 0")
    func notLive() {
        let live = LiveStream()
        live.begin(isLive: false, window: nil)
        #expect(live.window() == nil)
        #expect(live.secondsBehindEdge(at: 5) == 0)
        #expect(!live.isAtEdge(5))
        #expect(live.edgeTarget() == nil)
        #expect(live.clamp(-3) == 0)
    }

    @MainActor
    @Test("The edge moves with the clock, the start stays while the playlist grows from the beginning")
    func growingPlaylist() throws {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        live.begin(isLive: true, window: LiveWindow(start: 0, end: 100))
        live.update(window: LiveWindow(start: 0, end: 100), at: t0 + .seconds(5))
        let later = try #require(live.window(at: t0 + .seconds(10)))
        #expect(later.start == 0)
        #expect(abs(later.end - 110) < 0.5, "\(later)")
    }

    @MainActor
    @Test("A live stream's history opens where it was left in the stream's time, if the window still holds that")
    func resumesWhereItWasLeft() {
        // A window of 24 h from the stream's time 1 000 000 s (zero of the engine's), the edge six seconds before its end.
        let live = LiveStream()
        let t0 = ContinuousClock.now
        live.begin(isLive: true, window: LiveWindow(start: 0, end: 86_400, hasSlid: true), at: t0)
        let origin = 1_000_000.0

        // Left three hours in: there.
        #expect(live.resumeTarget(streamTime: origin + 10_800, wasAtEdge: false, origin: origin, now: t0) == 10_800)
        // Left at the edge: at the edge, whatever time has passed.
        #expect(live.resumeTarget(streamTime: origin + 86_000, wasAtEdge: true, origin: origin, now: t0) == nil)
        // Before the window (the day it held moved on since) and in its first seconds, whose segments expire: the edge.
        #expect(live.resumeTarget(streamTime: origin - 3_600, wasAtEdge: false, origin: origin, now: t0) == nil)
        #expect(live.resumeTarget(streamTime: origin + 5, wasAtEdge: false, origin: origin, now: t0) == nil)
        #expect(
            live.resumeTarget(
                streamTime: origin + LiveStream.startMargin + 1, wasAtEdge: false, origin: origin, now: t0)
                == LiveStream.startMargin + 1)
        // At or past the edge, however it was saved: the edge.
        #expect(live.resumeTarget(streamTime: origin + 86_399, wasAtEdge: false, origin: origin, now: t0) == nil)
        #expect(live.resumeTarget(streamTime: origin + 90_000, wasAtEdge: false, origin: origin, now: t0) == nil)
        // The window slides: a second later it starts a second on, and 5 + 10 s in is held no more at a minute's end.
        #expect(
            live.resumeTarget(streamTime: origin + 30, wasAtEdge: false, origin: origin, now: t0 + .seconds(60)) == nil)
    }

    @MainActor
    @Test("The window the gate finds more of keeps the start it had slid to: the slide is not taken back to the load")
    func theStartKeepsSlidingWhenTheGateFindsTheHead() throws {
        let t0 = ContinuousClock.now
        let first = LiveReport(window: LiveWindow(start: 0, end: 10_000, hasSlid: true), loadedAt: t0)
        // Five minutes on, the head is found further.
        let found = LiveSegmentGate.Change.headAdvanced(LiveHead(number: 7, startTime: 12_000))
        let next = MediaDemuxer.applying(found, to: first, origin: 0, now: t0 + .seconds(300))
        #expect(abs(next.window.start - 300) < 0.001, "\(next.window)")
        #expect(next.window.end == 12_005)
        #expect(next.loadedAt == t0 + .seconds(300))

        // What the engine makes of it: the start goes on from 300, not from 0 again.
        let live = LiveStream()
        live.begin(isLive: true, window: first.window, at: t0)
        live.update(window: next.window, at: next.loadedAt)
        let start = try #require(live.window(at: t0 + .seconds(310))).start
        #expect(abs(start - 310) < 0.5, "\(start)")

        // The end of the stream: its end, and the start it had reached, and no more sliding.
        let ended = MediaDemuxer.applying(
            .ended(lastNumber: 9, endTime: 11_000), to: next, origin: 0, now: t0 + .seconds(400))
        #expect(ended.window.hasEnded)
        #expect(abs(ended.window.start - 400) < 0.001)
        #expect(ended.window.end == 12_005, "an end never goes back")
        // A window that does not slide keeps its start; one never past its end.
        let still = MediaDemuxer.applying(
            found, to: LiveReport(window: LiveWindow(start: 5, end: 100), loadedAt: t0), origin: 0,
            now: t0 + .seconds(60))
        #expect(still.window.start == 5)
        let late = MediaDemuxer.applying(
            .headAdvanced(LiveHead(number: 1, startTime: 0)),
            to: LiveReport(window: LiveWindow(start: 0, end: 50, hasSlid: true), loadedAt: t0), origin: 0,
            now: t0 + .seconds(500))
        #expect(late.window.start <= late.window.end)
    }

    @MainActor
    @Test("A stream that ended, or is not live, has no edge to resume before")
    func resumesNothingWithoutAnEdge() {
        let live = LiveStream()
        live.begin(isLive: true, window: LiveWindow(start: 0, end: 1000, hasEnded: true))
        #expect(live.resumeTarget(streamTime: 500, wasAtEdge: false, origin: 0) == nil)
        let notLive = LiveStream()
        notLive.begin(isLive: false, window: nil)
        #expect(notLive.resumeTarget(streamTime: 500, wasAtEdge: false, origin: 0) == nil)
    }

    @MainActor
    @Test("A start that moves between two loads slides with the clock")
    func slidingPlaylist() throws {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        live.begin(isLive: true, window: LiveWindow(start: 100, end: 160))
        live.update(window: LiveWindow(start: 105, end: 165), at: t0 + .seconds(5))
        let later = try #require(live.window(at: t0 + .seconds(15)))
        #expect(abs(later.start - 115) < 0.5, "\(later)")
        #expect(abs(later.end - 175) < 0.5, "\(later)")
    }

    @MainActor
    @Test("Loads that land between segments do not make the edge jump: it only ever moves on")
    func edgeDoesNotJump() throws {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        // A playlist that grows by a segment of 5 s, loaded now long after the segment was published, now right after:
        // the edge is where the freshest load puts it, and the distance behind it stays put as playback goes on.
        live.begin(isLive: true, window: LiveWindow(start: 0, end: 1000))
        var previous = try #require(live.window(at: t0)).end
        for (second, end) in [(3.0, 1000.0), (6.0, 1005.0), (9.0, 1005.0), (12.0, 1010.0), (15.0, 1010.0)] {
            live.update(window: LiveWindow(start: 0, end: end), at: t0 + .seconds(second))
            let edge = try #require(live.window(at: t0 + .seconds(second))).end
            #expect(edge >= previous, "the edge went back from \(previous) to \(edge) at \(second) s")
            previous = edge
        }
        // Playing at 1x behind it: the distance at two moments 10 s apart is the same.
        let distance = { (second: Double, position: Double) in
            try #require(live.window(at: t0 + .seconds(second))).end - position
        }
        #expect(abs(try distance(16, 500) - distance(26, 510)) < 0.001)
    }

    @MainActor
    @Test("Behind the edge, at it, and where go live and seeks land")
    func edgeAndClamp() {
        let live = LiveStream()
        live.begin(isLive: true, window: LiveWindow(start: 100, end: 160, hasSlid: true))
        let now = ContinuousClock.now
        // `begin` anchored the window a moment ago: the queries below take its ends as they were told, within a second.
        #expect(abs(live.secondsBehindEdge(at: 130, now: now) - 30) < 1)
        #expect(live.isAtEdge(158, now: now))
        #expect(!live.isAtEdge(120, now: now))
        #expect(abs((live.edgeTarget(now: now) ?? 0) - (160 - LiveStream.edgeMargin)) < 1)
        #expect(abs(live.clamp(1000, now: now) - (160 - LiveStream.edgeMargin)) < 1)
        #expect(abs(live.clamp(0, now: now) - (100 + LiveStream.startMargin)) < 1)
    }

    @MainActor
    @Test("A new media and a reset leave nothing of the last window")
    func resets() {
        let live = LiveStream()
        live.begin(isLive: true, window: LiveWindow(start: 1, end: 20))
        live.begin(isLive: false, window: nil)
        #expect(!live.isLive)
        #expect(live.window() == nil)
        live.begin(isLive: true, window: LiveWindow(start: 1, end: 20))
        live.reset()
        #expect(!live.isLive)
        #expect(live.reportedWindow == nil)
    }

    // MARK: Demuxer

    /// A live playlist made of the segments of a VOD ladder: `windowCount` segments from the first, one more for each
    /// `secondsPerSegment` the server has run, without an end.
    private static func liveServer(
        windowCount: Int = 5, secondsPerSegment: Double = 1
    ) throws -> TestHTTPServer? {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return nil }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        let started = ContinuousClock.now
        server.setResponder(forPath: "live.m3u8") {
            let elapsed = (ContinuousClock.now - started) / .seconds(1)
            let first = min(Int(elapsed / secondsPerSegment), 20 - windowCount)
            var lines = [
                "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:\(first)",
            ]
            for index in first..<(first + windowCount) {
                lines += ["#EXTINF:2.000000,", String(format: "v0_%03d.ts", index)]
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        return server
    }

    @Test(
        "A playlist that slides is live: no duration, a window as long as its segments", .hostDependent,
        needsBundledFFmpeg)
    func demuxerTellsTheWindow() throws {
        guard let server = try Self.liveServer() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        #expect(demuxer.isLive)
        #expect(demuxer.durationSeconds == 0)
        let window = try #require(demuxer.liveWindow)
        #expect(abs(window.length - 10) < 0.5, "\(window)")
    }

    @Test("A playlist that ends is not live", .hostDependent)
    func endedPlaylistIsNotLive() throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("v0.m3u8")))
        #expect(!demuxer.isLive)
        #expect(demuxer.liveWindow == nil)
        #expect(demuxer.durationSeconds > 30)
    }

    @Test("The window moves as the playlist does, and a seek in it lands there", .hostDependent, needsBundledFFmpeg)
    func windowSlidesAndSeeks() throws {
        guard let server = try Self.liveServer(secondsPerSegment: 0.5) else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        let first = try #require(demuxer.liveWindow)
        demuxer.startReadAhead()

        // Reading on reloads the playlist, which has slid by then.
        var pictures = 0
        var moved: LiveWindow?
        while pictures < 400, demuxer.nextVideoSample() != nil {
            pictures += 1
            if let window = demuxer.liveWindow, window.start > first.start + 1 {
                moved = window
                break
            }
        }
        let window = try #require(moved, "window stayed at \(first)")
        #expect(window.start > first.start)

        // A seek to the middle of the window lands within a segment of it.
        let target = window.start + window.length / 2
        _ = demuxer.seek(to: target, exact: false)
        let sample = try #require(demuxer.nextVideoSample())
        let landed = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        #expect(abs(landed - target) <= 2.5, "asked \(target), landed \(landed) in \(window)")
    }
}

/// The engine with a live stream loaded: where it starts, what it seeks to. In the suite of the playlists tests, not a suite
/// of its own: it is `async`, and with a pool of one thread (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) it waits for the
/// thread behind the tests of those that sleep, its clock going on: only a suite that is serialized does not overlap them.
extension LiveStreamPlaylistTests {
    @Test("A live stream starts at its edge, and seeks stay within its window", .hostDependent, needsBundledFFmpeg)
    @MainActor
    func startsAtEdgeAndSeeksInWindow() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let started = ContinuousClock.now
        server.setResponder(forPath: "live.m3u8") {
            // A playlist that grows from the beginning as the clock does, a segment of 2 s every 2 s (the edge the engine
            // reckons moves with the clock too): ten to start with, up to the twenty the server has.
            let count = min(10 + Int((ContinuousClock.now - started) / .seconds(2)), 20)
            var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:0"]
            for index in 0..<count {
                lines += ["#EXTINF:2.000000,", String(format: "v0_%03d.ts", index)]
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }

        let engine = PlayerEngine.makeForTesting()
        await engine.loadAsync(MediaLoadRequest(path: server.url("live.m3u8")))
        #expect(engine.isLoaded)
        #expect(engine.media.isLive)
        #expect(engine.media.duration == 0)
        #expect(engine.live.isLive)

        let window = try #require(engine.live.window())
        // Starts behind the edge by the margin (a segment's size, as FFmpeg reads from).
        let edge = try #require(engine.live.edgeTarget())
        #expect(abs(engine.currentTime - edge) < 2.5, "started at \(engine.currentTime), edge \(edge) in \(window)")
        #expect(engine.live.isAtEdge(engine.currentTime))

        // Before the window and past it both land in it.
        engine.seek(to: window.start - 500)
        #expect(await engine.waitUntil { !engine.isSeeking && engine.chase == nil })
        let current = try #require(engine.live.window())
        #expect(engine.currentTime >= current.start - 0.5, "\(engine.currentTime) before \(current)")
        engine.seek(to: window.end + 500)
        #expect(await engine.waitUntil { !engine.isSeeking && engine.chase == nil })
        #expect(engine.currentTime <= (engine.live.window()?.end ?? 0) + 0.5)

        // Into the middle, then back to the edge.
        engine.seek(to: window.start + window.length / 2)
        #expect(await engine.waitUntil { !engine.isSeeking && engine.chase == nil })
        #expect(!engine.live.isAtEdge(engine.currentTime))
        engine.seekToLiveEdge()
        #expect(await engine.waitUntil { !engine.isSeeking && engine.chase == nil })
        #expect(engine.live.isAtEdge(engine.currentTime))
    }
}

/// What a live stream does that a single sliding playlist does not show: a master playlist whose active variant is not
/// the first, and a playlist that ends.
/// Serialized, as `LiveStreamTests`.
@Suite("Live stream playlists", .serialized, .networkServer)
struct LiveStreamPlaylistTests {
    private static let segmentCount = 20

    /// A live master playlist over the ladder's variants 1 and 2 (the first listed is the lower, the one not played), each
    /// listing `windowCount` of its segments, from the first to start with, then one more each `secondsPerSegment`.
    /// `endsAfter` seconds on the playlists end (`EXT-X-ENDLIST`) with what they list.
    private static func server(
        windowCount: Int = 5, secondsPerSegment: Double = 0.5, endsAfter: Double? = nil, firstVariantBase: Int = 0,
        secondVariantBase: Int = 0
    ) throws -> TestHTTPServer? {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return nil }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        let started = ContinuousClock.now
        server.setResponder(forPath: "live.m3u8") {
            let lines = [
                "#EXTM3U", "#EXT-X-VERSION:3",
                "#EXT-X-STREAM-INF:BANDWIDTH=1082880,RESOLUTION=480x270,CODECS=\"avc1.42c015,mp4a.40.2\"", "live1.m3u8",
                "#EXT-X-STREAM-INF:BANDWIDTH=2858352,RESOLUTION=640x360,CODECS=\"avc1.42c01e,mp4a.40.2\"", "live2.m3u8",
            ]
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        for variant in [1, 2] {
            server.setResponder(forPath: "live\(variant).m3u8") {
                let elapsed = (ContinuousClock.now - started) / .seconds(1)
                let ended = endsAfter.map { elapsed >= $0 } ?? false
                let first = min(Int(elapsed / secondsPerSegment), segmentCount - windowCount)
                var lines = [
                    "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2",
                    "#EXT-X-MEDIA-SEQUENCE:\(first + (variant == 2 ? secondVariantBase : firstVariantBase))",
                ]
                for index in first..<(first + windowCount) {
                    lines += ["#EXTINF:2.000000,", String(format: "v\(variant)_%03d.ts", index)]
                }
                if ended { lines.append("#EXT-X-ENDLIST") }
                return Data((lines.joined(separator: "\n") + "\n").utf8)
            }
        }
        return server
    }

    @Test(
        "A master playlist whose variant playing is not the first: the window slides and a seek lands in it",
        .hostDependent,
        needsBundledFFmpeg)
    func variantPlayingIsNotTheFirst() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        #expect(demuxer.isLive)
        #expect(demuxer.variants.count == 2)
        let first = try #require(demuxer.liveWindow)
        demuxer.startReadAhead()

        var moved: LiveWindow?
        var pictures = 0
        while pictures < 600, demuxer.nextVideoSample() != nil {
            pictures += 1
            if let window = demuxer.liveWindow, window.start > first.start + 1 {
                moved = window
                break
            }
        }
        let window = try #require(moved, "the window stayed at \(first)")
        #expect(window.hasSlid)

        let target = window.start + window.length / 2
        _ = demuxer.seek(to: target, exact: false)
        let sample = try #require(demuxer.nextVideoSample())
        let landed = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        #expect(abs(landed - target) <= 2.5, "asked \(target), landed \(landed) in \(window)")
    }

    @Test("A playlist that ends leaves its last window, marked ended", .hostDependent, needsBundledFFmpeg)
    func endedPlaylistKeepsItsWindow() throws {
        guard let server = try Self.server(secondsPerSegment: 0.2, endsAfter: 2) else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        #expect(try #require(demuxer.liveWindow).hasEnded == false)
        demuxer.startReadAhead()

        var window: LiveWindow?
        var pictures = 0
        while demuxer.nextVideoSample() != nil, pictures < 2000 {
            pictures += 1
            if let current = demuxer.liveWindow, current.hasEnded {
                window = current
                break
            }
        }
        let ended = try #require(window, "the window never ended")
        #expect(ended.length > 5)
        #expect(demuxer.durationSeconds == 0)
    }

    @MainActor
    @Test("A window that ends stands; a seek stays within it, and there is no edge to go to")
    func endedWindowStands() {
        let live = LiveStream()
        live.begin(isLive: true, window: LiveWindow(start: 100, end: 160))
        live.update(window: LiveWindow(start: 130, end: 190, hasEnded: true))
        #expect(live.isEnded)
        #expect(live.window(at: .now + .seconds(30)) == LiveWindow(start: 130, end: 190, hasEnded: true))
        #expect(live.edgeTarget() == nil)
        #expect(!live.isAtEdge(189))
        #expect(live.clamp(0) == 130)
        #expect(live.clamp(500) == 190)
        // Nothing after the end moves it.
        live.update(window: LiveWindow(start: 130, end: 400))
        #expect(live.window()?.end == 190)
    }

    @MainActor
    @Test("A playlist that had slid when opened slides from the first load: the window keeps its length")
    func slidingFromTheStart() throws {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        live.begin(isLive: true, window: LiveWindow(start: 500, end: 560, hasSlid: true))
        let later = try #require(live.window(at: t0 + .seconds(10)))
        #expect(abs(later.length - 60) < 0.5, "\(later)")
    }
}

extension LiveStreamPlaylistTests {
    @Test(
        "A variant switch of a live stream leaves it without a duration, and its window moving", .hostDependent,
        needsBundledFFmpeg)
    func variantSwitchKeepsNoDuration() throws {
        guard let server = try Self.server(windowCount: 8, secondsPerSegment: 0.5) else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        let low = try #require(demuxer.variants.min { $0.bandwidth < $1.bandwidth })
        demuxer.startReadAhead()
        let before = try #require(demuxer.liveWindow)

        var pictures = 0
        var switched = false
        while pictures < 800, demuxer.nextVideoSample() != nil {
            pictures += 1
            if pictures == 20 { demuxer.selectVariant(id: low.id) }
            if demuxer.selectedVariantId == low.id, demuxer.variantSwitch == nil { switched = true }
            if switched, let window = demuxer.liveWindow, window.start > before.start + 1 { break }
        }
        #expect(demuxer.selectedVariantId == low.id)
        #expect(demuxer.isLive)
        #expect(demuxer.durationSeconds == 0)
        let after = try #require(demuxer.liveWindow)
        #expect(after.start > before.start, "the window stayed at \(before) -> \(after)")
    }
}

extension LiveStreamTests {
    @MainActor
    @Test("After a stall of the source the edge comes back: the badge is not grey for good")
    func edgeRecoversFromAStall() throws {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        live.begin(isLive: true, window: LiveWindow(start: 0, end: 1000))
        // The playlist grows for 20 s, stalls for 40 s (the clock goes on), then grows again from where it stood.
        for second in stride(from: 5.0, through: 20.0, by: 5.0) {
            live.update(window: LiveWindow(start: 0, end: 1000 + second), at: t0 + .seconds(second))
        }
        let during = try #require(live.window(at: t0 + .seconds(60))).end
        #expect(abs(during - 1060) < 1, "the edge goes on with the clock while the source stands: \(during)")
        for second in stride(from: 65.0, through: 130.0, by: 5.0) {
            live.update(window: LiveWindow(start: 0, end: 1020 + (second - 60)), at: t0 + .seconds(second))
        }
        // The stall's 40 s have left the samples of the last minute: the edge is the playlist's again.
        let after = try #require(live.window(at: t0 + .seconds(130))).end
        #expect(abs(after - 1090) < 6, "the edge stayed ahead of the playlist's: \(after)")
    }
}

extension LiveStreamTests {
    @MainActor
    @Test("A window told when it was loaded, long before it was read, is moved on from then")
    func windowIsMovedFromItsLoad() throws {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        // A paused picture: the demuxer loaded this window 280 s ago, the engine reads it at the first tick of resuming.
        live.begin(isLive: true, window: LiveWindow(start: 500, end: 560, hasSlid: true), at: t0)
        let now = try #require(live.window(at: t0 + .seconds(280)))
        #expect(abs(now.start - 780) < 0.5, "\(now)")
    }

    @MainActor
    @Test("A playlist that grows from the beginning keeps all of it to seek in; one that slides keeps a margin")
    func startMarginIsForSlidingPlaylists() throws {
        let growing = LiveStream()
        growing.begin(isLive: true, window: LiveWindow(start: 0, end: 600))
        #expect(growing.clamp(0) == 0)
        let sliding = LiveStream()
        sliding.begin(isLive: true, window: LiveWindow(start: 100, end: 700, hasSlid: true))
        #expect(abs(sliding.clamp(0) - (100 + LiveStream.startMargin)) < 1)
    }

    @MainActor
    @Test("Bringing back into the window is tried again only after a while, and not for a picture a keyframe short")
    func windowRecoveryIsSpaced() {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        live.begin(isLive: true, window: LiveWindow(start: 100, end: 160, hasSlid: true), at: t0)
        #expect(!live.shouldRecoverWindow(at: 99, now: t0))
        #expect(live.shouldRecoverWindow(at: 90, now: t0))
        #expect(!live.shouldRecoverWindow(at: 90, now: t0 + .seconds(5)))
        #expect(live.shouldRecoverWindow(at: 90, now: t0 + .seconds(20)))
    }

    @MainActor
    @Test("Reading again is tried for as long as it lasts, ever less often, and the count starts over once it goes on")
    func readingRecoveryBacksOff() {
        let live = LiveStream()
        let t0 = ContinuousClock.now
        live.begin(isLive: true, window: LiveWindow(start: 0, end: 600), at: t0)
        #expect(!live.shouldRecoverReading(isStopped: false, now: t0))
        #expect(live.shouldRecoverReading(isStopped: true, now: t0))
        #expect(!live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(4)))
        // 5 s after the first, 10 after the second, 20 after the third, then 30 apart for good.
        #expect(live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(5)))
        #expect(!live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(14)))
        #expect(live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(15)))
        #expect(!live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(34)))
        #expect(live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(35)))
        #expect(!live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(64)))
        #expect(live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(65)))
        #expect(live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(95)))
        // Once reading goes on the count starts over: the next stop is retried after the first interval.
        #expect(!live.shouldRecoverReading(isStopped: false, now: t0 + .seconds(100)))
        #expect(live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(101)))
        #expect(!live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(105)))
        #expect(live.shouldRecoverReading(isStopped: true, now: t0 + .seconds(106)))
    }

    @MainActor
    @Test("A seek is at an end of the window if it was cut to it, not if it is near it")
    func boundIsWhereASeekWasCut() {
        let live = LiveStream()
        live.begin(isLive: true, window: LiveWindow(start: 0, end: 600))
        let now = ContinuousClock.now
        let edge = 600 - LiveStream.edgeMargin
        // Past the edge, whatever how far: cut to it. The edge moves with the clock, a few seconds on, and a held key is
        // cut to it again.
        #expect(live.bound(of: edge + 50, now: now) == .end)
        #expect(live.bound(of: edge + 4, now: now + .seconds(3)) == .end)
        // A step that stops short of the edge (a skip forward from 9 s before it) is not a seek to the edge: the next
        // press, cut to it, is one to start, not the same seek.
        #expect(live.bound(of: edge - 9, now: now) == nil)
        #expect(live.bound(of: 300, now: now) == nil)
        #expect(live.bound(of: -5, now: now) == .start)
        #expect(live.bound(of: 0, now: now) == .start)
    }

    @MainActor
    @Test("The ends of a window that ended are its own, and a sliding one keeps its margin from the start")
    func boundsOfEndedAndSlidingWindows() {
        let ended = LiveStream()
        ended.begin(isLive: true, window: LiveWindow(start: 100, end: 160))
        ended.update(window: LiveWindow(start: 100, end: 160, hasEnded: true))
        #expect(ended.bound(of: 160) == .end)
        #expect(ended.bound(of: 155) == nil)
        #expect(ended.bound(of: 100) == .start)
        let sliding = LiveStream()
        sliding.begin(isLive: true, window: LiveWindow(start: 100, end: 700, hasSlid: true))
        #expect(sliding.bound(of: 100 + LiveStream.startMargin - 1) == .start)
        #expect(sliding.bound(of: 100 + LiveStream.startMargin + 5) == nil)
    }
}

extension LiveStreamPlaylistTests {
    @Test(
        "A seek does not wait for the read that waits at a stalled edge", .hostDependent,
        needsBundledFFmpeg)
    func seekDoesNotWaitAtAStalledEdge() throws {
        // A playlist that stands: the read-ahead reaches its end and waits there for a segment that never comes.
        guard let server = try Self.server(windowCount: 5, secondsPerSegment: 10_000) else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        let window = try #require(demuxer.liveWindow)
        demuxer.startReadAhead()
        let deadline = ContinuousClock.now + .seconds(15)
        while demuxer.readAheadSeconds < window.end - 1, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try #require(demuxer.readAheadSeconds >= window.end - 1, "never read to the edge")
        // In the wait now (the playlist is loaded every couple of seconds, with sleeps between).
        Thread.sleep(forTimeInterval: 0.5)

        // Without the seek yielding the input, it waits for the read at the edge: for as long as the stream stalls.
        let started = ContinuousClock.now
        _ = demuxer.seek(to: window.start + 4, exact: false)
        let took = (ContinuousClock.now - started) / .seconds(1)
        #expect(took < 2, "the seek waited \(took) s for the read at the edge")
        #expect(!demuxer.isEOF)
    }
}

extension LiveStreamPlaylistTests {
    @Test(
        "A pause longer than two windows leaves the window following the playlist, and seeks in it", .hostDependent,
        needsBundledFFmpeg)
    func windowFollowsThePlaylistAfterALongPause() throws {
        // Two segments of 2 s listed, one more every 2 s: the playlist moves as fast as the clock, as a live one does.
        guard let server = try Self.server(windowCount: 2, secondsPerSegment: 2) else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        let first = try #require(demuxer.liveWindow)
        // Nothing is read (held, as a read-ahead that is full is) for longer than two windows (8 s), as in a pause:
        // the playlist is 5 segments on, more than it and the one before it list (4).
        demuxer.startReadAhead(held: true)
        Thread.sleep(forTimeInterval: 10)
        demuxer.releaseReadAhead()
        // Reading on loads the playlist: its window is where the clock puts it.
        var window = first
        for _ in 0..<150 {
            guard demuxer.nextVideoSample() != nil else { break }
            if let current = demuxer.liveWindow, current.start > first.start + 6 {
                window = current
                break
            }
        }
        #expect(abs(window.start - (first.start + 10)) < 3, "the window stayed at \(first) -> \(window)")

        let target = window.start + 1
        _ = demuxer.seek(to: target, exact: false)
        let sample = try #require(demuxer.nextVideoSample())
        let landed = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        #expect(abs(landed - target) <= 2.5, "asked \(target), landed \(landed) in \(window)")
    }
}

extension LiveStreamPlaylistTests {
    @Test(
        "Variants numbered from different bases leave the window following the clock, not jumping by the difference",
        .hostDependent, needsBundledFFmpeg,
        arguments: [(first: 0, second: 500_000), (first: 500_000, second: 0)])
    func variantsOfDifferentBases(bases: (first: Int, second: Int)) throws {
        // One variant is numbered from 500000, the other from 0: whichever the first timestamp came from, the one played
        // is the other, or not. One segment of 2 s is added every 2 s (the clock's pace) to both.
        guard
            let server = try Self.server(
                windowCount: 5, secondsPerSegment: 2, firstVariantBase: bases.first, secondVariantBase: bases.second)
        else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("live.m3u8")))
        let first = try #require(demuxer.liveWindow)
        demuxer.startReadAhead()
        let started = ContinuousClock.now
        // The read-ahead reads on by itself, at the edge, loading the playlist as it moves (a segment every 2 s).
        let wait = { (seconds: Double) in
            while (ContinuousClock.now - started) / .seconds(1) < seconds { Thread.sleep(forTimeInterval: 0.25) }
        }
        wait(4)
        // Then the other variant plays: the playlist the first timestamp came from is not loaded again, and the one that is
        // is numbered from another base (the branch of `hls.c` for a gap longer than the time allows).
        let other = try #require(demuxer.variants.min { $0.bandwidth < $1.bandwidth })
        demuxer.selectVariant(id: other.id)
        // The window moves a segment (2 s) at a time, as the loads happen to come: wait for it to be where the clock puts
        // it (nine seconds on, six after the switch), up to a deadline, rather than look at one moment.
        while (ContinuousClock.now - started) / .seconds(1) < 20,
            (demuxer.liveWindow?.start ?? 0) < first.start + 9
        {
            Thread.sleep(forTimeInterval: 0.25)
        }
        #expect(demuxer.selectedVariantId == other.id)
        let window = try #require(demuxer.liveWindow)
        // Not by the difference of the bases, which would be hundreds of thousands of seconds, nor stood still after the
        // switch.
        #expect(window.start >= first.start + 9 && window.start < first.start + 30, "\(first) -> \(window)")
        #expect(abs(window.length - first.length) < 3, "\(first) -> \(window)")
    }
}
