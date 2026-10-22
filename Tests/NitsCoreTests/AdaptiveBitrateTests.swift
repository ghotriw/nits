import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// Adaptive bitrate against `TestHTTPServer` throttled: the demuxer reads ahead as for any network source, and a
/// stand-in for playback takes pictures in real time.
@Suite("Adaptive bitrate over HTTP", .serialized, .hostDependent, .timeLimit(.minutes(2)))
struct AdaptiveBitrateTests {
    /// Takes pictures as playback does: from when the read-ahead holds `startAhead` seconds, each at its time,
    /// pausing (and counting the pause as a stall) when the next isn't read yet. Audio is taken as it comes.
    final class RealtimeConsumer: Sendable {
        struct Picture: Sendable {
            let pts: Double
            let width: Int32
        }

        private struct State {
            var pictures: [Picture] = []
            var stalled = 0.0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let task: Task<Void, Never>

        init(_ demuxer: MediaDemuxer, startAhead: Double = 2) {
            let state = self.state
            task = Task.detached {
                while demuxer.readAheadSeconds < startAhead, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                var clock: (start: ContinuousClock.Instant, pts: Double)?
                while !Task.isCancelled {
                    while demuxer.nextAudioPacket() != nil {}
                    guard let sample = demuxer.nextVideoSample(waitingForReadAhead: false) else {
                        if demuxer.isEOF { return }
                        let wait = ContinuousClock.now
                        try? await Task.sleep(for: .milliseconds(10))
                        // Playback holds while it waits for data: so does the clock.
                        if let started = clock {
                            clock = (started.start + (ContinuousClock.now - wait), started.pts)
                            state.withLock { $0.stalled += (ContinuousClock.now - wait) / .seconds(1) }
                        }
                        continue
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    let width =
                        CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?
                        .width ?? 0
                    let started = clock ?? (ContinuousClock.now, pts)
                    clock = started
                    let due = started.start + .seconds(max(pts - started.pts, 0))
                    if due > .now { try? await Task.sleep(until: due) }
                    state.withLock { $0.pictures.append(Picture(pts: pts, width: width)) }
                }
            }
        }

        deinit { task.cancel() }

        var pictures: [Picture] { state.withLock { $0.pictures } }
        /// Seconds playback waited for data after it started.
        var stalled: Double { state.withLock { $0.stalled } }
        var playedWidth: Int32? { pictures.last?.width }

        func stop() { task.cancel() }
    }

    private static func config() -> AdaptiveBitrateLogic.Config {
        var config = AdaptiveBitrateLogic.Config.scaled(toReadAhead: 9)
        config.upSwitchInterval = 3
        config.downSwitchInterval = 1
        config.halfLives = (fast: 1, slow: 2)
        config.estimateLifetime = 5
        config.failedProbeWindow = 15
        return config
    }

    private static func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test("A slow network brings the variant down to one it carries, and a fast one back up, without stalling")
    func followsTheNetwork() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        #expect(demuxer.variants.map(\.width) == [640, 480, 320])
        demuxer.adaptiveBitrateConfig = Self.config()

        // 1.5 Mbit/s carries the 0.97 Mbit/s variant (80 % of it is 1.2), not the 2.66 one it starts on.
        server.setLinkRate(1_500_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        #expect(
            await Self.waitUntil(timeout: .seconds(12)) { consumer.playedWidth == 480 },
            "Playing \(String(describing: consumer.playedWidth))")
        let stalledSlow = consumer.stalled
        #expect(stalledSlow < 1.5, "Stalled \(stalledSlow) s on the slow network")
        #expect(!consumer.pictures.contains { $0.width == 320 }, "Went below the variant the network carries")

        server.setLinkRate(8_000_000 / 8)
        // Chosen at the read position: it plays once the read-ahead before it has (9 s).
        #expect(
            await Self.waitUntil(timeout: .seconds(25)) { consumer.playedWidth == 640 },
            "Playing \(String(describing: consumer.playedWidth))")
        #expect(consumer.stalled - stalledSlow < 0.5, "Stalled \(consumer.stalled - stalledSlow) s on the fast network")
        #expect(demuxer.isAdaptiveBitrateEnabled)
    }

    @Test("A low variant's small segments, slow to be answered, don't hold it there: the latency isn't transfer")
    func latencyIsNoTransfer() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()
        let low = try #require(demuxer.variants.last)
        demuxer.selectVariant(id: low.id)
        demuxer.setAdaptiveBitrate(true)

        // A CDN fetching from its origin: 0.6 s before each segment's answer, then 8 Mbit/s. Counted as transfer, the
        // 320 variant's 75 KB segments measured under 1 Mbit/s, and nothing above it fit. The 2.66 Mbit/s variant
        // reads a second in 0.33 s of transfer and 0.3 s of latency, within `safety`.
        server.setLinkRate(8_000_000 / 8)
        server.setBehavior(.init(delay: .milliseconds(600)), forPaths: { $0.hasSuffix(".ts") })
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        // The first pictures are of the variant opened, before the splice to the low one.
        try #require(await Self.waitUntil(timeout: .seconds(10)) { consumer.playedWidth == 320 })
        #expect(
            await Self.waitUntil(timeout: .seconds(20)) { consumer.playedWidth == 640 },
            "Playing \(String(describing: consumer.playedWidth))")
        let estimate = try #require(demuxer.readingDescription { $0.adaptiveBitrate.estimate })
        #expect(estimate > 6_000_000, "Measured \(Int(estimate / 1000)) kbit/s of 8000")
    }

    @Test("The latency share counts from the first segment read, and doesn't leap at the start")
    func latencyShareFromTheStart() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()
        demuxer.setAdaptiveBitrate(false)

        // Half a second before each answer, 2-second segments: a quarter of a second per second of media. Reading
        // starts by opening the first segment, with no media read yet, and reads it whole: probing's input closed
        // with the rewind after it.
        server.setBehavior(.init(delay: .milliseconds(500)), forPaths: { $0.hasSuffix(".ts") })
        demuxer.startReadAhead(limits: .init(seconds: 9))
        defer { demuxer.cancel() }
        var shares: [Double] = []
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if let share = demuxer.readingDescription({ $0.adaptiveBitrate.latencyShare }) { shares.append(share) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let highest = try #require(shares.max())
        let last = try #require(shares.last)
        #expect(highest < 0.5, "The share reached \(highest)")
        #expect(last > 0.2 && last < 0.4, "The share is \(last)")
    }

    @Test("A server slower to answer than its segments last brings the variant down, however fast the link")
    func slowAnswersComeDown() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()

        // 1.5 s before each answer of a 2-second segment: the 2.66 Mbit/s variant's take 2.2 s at 8 Mbit/s, the
        // lowest's 1.6 s.
        server.setLinkRate(8_000_000 / 8)
        server.setBehavior(.init(delay: .milliseconds(1500)), forPaths: { $0.hasSuffix(".ts") })
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        #expect(
            await Self.waitUntil(timeout: .seconds(20)) { consumer.playedWidth == 320 },
            "Playing \(String(describing: consumer.playedWidth))")
    }

    /// The ladder's media playlists as a live stream: a segment more every two seconds, a window of four.
    private static func serveLive(_ server: TestHTTPServer, segments: Int = 20) {
        let start = ContinuousClock.now
        for variant in 0..<3 {
            server.setResponder(forPath: "v\(variant).m3u8") {
                let available = min(3 + Int((ContinuousClock.now - start) / .seconds(2)), segments)
                let first = max(available - 4, 0)
                var lines = [
                    "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:\(first)",
                ]
                for segment in first..<available {
                    lines += ["#EXTINF:2.000000,", String(format: "v\(variant)_%03d.ts", segment)]
                }
                return Data((lines.joined(separator: "\n") + "\n").utf8)
            }
        }
    }

    @Test("At a live stream's edge, waiting for the next segment doesn't bring the variant down")
    func liveEdgeKeepsVariant() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        Self.serveLive(server)
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        #expect(demuxer.durationSeconds <= 0)
        demuxer.adaptiveBitrateConfig = Self.config()
        let top = try #require(demuxer.variants.first)
        #expect(demuxer.selectedVariantId == top.id)

        // A fast link: the read-ahead thread reaches the edge and waits there for every new segment.
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        try await Task.sleep(for: .seconds(12))
        #expect(consumer.pictures.count > 150, "Played \(consumer.pictures.count) pictures")
        #expect(consumer.pictures.allSatisfy { $0.width == 640 }, "Went down at the live edge")
        #expect(demuxer.selectedVariantId == top.id)
    }

    @Test("A live stream on a slow link still comes down to the variant the link carries")
    func liveSlowLinkComesDown() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        Self.serveLive(server)
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()

        // Behind the edge, reads transfer all the time: the estimate is the link's.
        server.setLinkRate(1_500_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        #expect(
            await Self.waitUntil(timeout: .seconds(12)) { consumer.playedWidth == 480 },
            "Playing \(String(describing: consumer.playedWidth))")
        #expect(!consumer.pictures.contains { $0.width == 320 }, "Went below the variant the link carries")
    }

    @Test("A live stream's server slow to answer isn't taken for waiting at its edge")
    func liveSlowAnswersComeDown() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        Self.serveLive(server)
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()

        // Behind the edge on a slow link, with 0.7 s before each segment's answer: a read that asks for a segment
        // waits that long without data, which isn't the edge's wait for a new one.
        server.setLinkRate(1_500_000 / 8)
        server.setBehavior(.init(delay: .milliseconds(700)), forPaths: { $0.hasSuffix(".ts") })
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        #expect(
            await Self.waitUntil(timeout: .seconds(15)) { (consumer.playedWidth ?? 640) < 640 },
            "Playing \(String(describing: consumer.playedWidth))")
    }

    @Test("A live stream's playlist slow to answer isn't taken for waiting at its edge")
    func liveSlowPlaylistIsNoEdge() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        Self.serveLive(server)
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()
        demuxer.setAdaptiveBitrate(false)

        // The top variant on a slow link stays behind the edge, with 0.7 s before each media playlist's answer: the
        // reload FFmpeg makes before a segment, once a segment's length passed, is a long wait for a few hundred
        // bytes, as at the edge.
        server.setLinkRate(1_500_000 / 8)
        server.setBehavior(
            .init(delay: .milliseconds(700)), forPaths: { $0.hasSuffix(".m3u8") && !$0.hasSuffix("master.m3u8") })
        demuxer.startReadAhead(limits: .init(seconds: 9))
        defer { demuxer.cancel() }
        try await Task.sleep(for: .seconds(10))
        #expect(demuxer.readingDescription { $0.liveEdgeReachedAt } == nil)
    }

    @Test("Only a long read of a live stream without data is a wait at its edge")
    func liveEdgeWaits() {
        #expect(MediaDemuxer.isLiveEdgeWait(bytes: 600, seconds: 1.9))
        #expect(!MediaDemuxer.isLiveEdgeWait(bytes: 600, seconds: 0.2))
        // 300 kbit/s, slow but data: a transfer.
        #expect(!MediaDemuxer.isLiveEdgeWait(bytes: 75_000, seconds: 2))
    }

    @Test("Choosing a variant turns adaptive bitrate off")
    func manualChoiceSticks() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()
        let low = try #require(demuxer.variants.last)
        demuxer.selectVariant(id: low.id)
        #expect(!demuxer.isAdaptiveBitrateEnabled)

        // Fast enough for the top variant, which adaptive bitrate would go up to.
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        try await Task.sleep(for: .seconds(8))
        #expect(consumer.playedWidth == 320)
        #expect(!consumer.pictures.dropFirst(60).contains { $0.width != 320 })
    }
}
