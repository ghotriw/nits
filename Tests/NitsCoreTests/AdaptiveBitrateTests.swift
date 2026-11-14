import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// Adaptive bitrate against `TestHTTPServer` throttled: the demuxer reads ahead as for any network source, and a
/// stand-in for playback takes pictures in real time.
@Suite("Adaptive bitrate over HTTP", .serialized, .hostDependent, .networkServer, .timeLimit(.minutes(2)))
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
            /// Presentation times (seconds) of the audio packets taken, in order.
            var audio: [Double] = []
            var stalled = 0.0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let task: Task<Void, Never>

        /// `audioAhead`: seconds of sound taken ahead of the last picture shown, as a renderer's queue holds; all that is
        /// queued when nil.
        init(_ demuxer: MediaDemuxer, startAhead: Double = 2, audioAhead: Double? = nil) {
            let state = self.state
            // On a queue of its own, off the cooperative pool, as a renderer's clock is: with the HTTP suites together on a
            // pool of one thread its clock fell a second behind, and what a test timed against it came too early.
            let executor = QueueTaskExecutor(queue: DispatchQueue(label: "RealtimeConsumer"))
            task = Task.detached(executorPreference: executor) {
                while demuxer.readAheadSeconds < startAhead, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                var clock: (start: ContinuousClock.Instant, pts: Double)?
                // Whether the next queued sound is within `audioAhead` of the picture shown.
                let isAudioDue = { () -> Bool in
                    guard let audioAhead else { return true }
                    let limit = (state.withLock { $0.pictures.last?.pts } ?? 0) + audioAhead
                    demuxer.queueLock.lock()
                    defer { demuxer.queueLock.unlock() }
                    guard let next = demuxer.audioQueue.peek(), demuxer.audioTimebase.den > 0 else { return false }
                    let pts = next.pts != Int64.min ? next.pts : next.dts
                    let base = demuxer.audioTimebase
                    return pts == Int64.min || Double(pts) * Double(base.num) / Double(base.den) <= limit
                }
                while !Task.isCancelled {
                    while isAudioDue(), let packet = demuxer.nextAudioPacket() {
                        let base = demuxer.audioTimebase
                        let pts = packet.pts != Int64.min ? packet.pts : packet.dts
                        if pts != Int64.min, base.den > 0 {
                            state.withLock { $0.audio.append(Double(pts) * Double(base.num) / Double(base.den)) }
                        }
                    }
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
        var audio: [Double] { state.withLock { $0.audio } }
        /// Seconds playback waited for data after it started.
        var stalled: Double { state.withLock { $0.stalled } }
        var playedWidth: Int32? { pictures.last?.width }

        func stop() { task.cancel() }
    }

    static func config(readAhead: Double = 9) -> AdaptiveBitrateLogic.Config {
        var config = AdaptiveBitrateLogic.Config.scaled(toReadAhead: readAhead)
        config.upSwitchInterval = 3
        config.downSwitchInterval = 1
        config.halfLives = (fast: 1, slow: 2)
        config.estimateLifetime = 5
        config.failedProbeWindow = 15
        return config
    }

    static func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// What a slow link at the start does since the download of the top variant (640) is given up for the lowest (320),
    /// which a buffer of a second or two leaves (`MediaDemuxer.requestAbandon`), and back up to what the link carries
    /// (`AdaptiveBitrateLogic.Detour`): playback does not stall, never goes below `carried` once it plays it, nor back
    /// to 640 while the link is slow, and gives up at most twice (no seesaw). Measured on 1.5 Mbit/s: 640, 320 from 2 s,
    /// 480 from 8 s (18 s with a read-ahead of 30), one give-up, no stall (1.4 to 2.3 s before giving up existed).
    /// With giving up off (`NITS_ABR_ABANDON=0`), what held before it: a step down from 640 straight to `carried`, never
    /// below, and a stall of a segment's late arrival (under 4 s).
    static func expectCameDownWithoutStalling(
        _ consumer: RealtimeConsumer, to carried: Int32, demuxer: MediaDemuxer, since: Date,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let pictures = consumer.pictures
        guard demuxer.abandonsDownloads else {
            #expect(
                consumer.stalled < 4, "Stalled \(consumer.stalled) s on the slow link", sourceLocation: sourceLocation)
            #expect(
                !pictures.contains { $0.width < carried }, "Went below the variant the link carries",
                sourceLocation: sourceLocation)
            return
        }
        #expect(consumer.stalled < 1, "Stalled \(consumer.stalled) s on the slow link", sourceLocation: sourceLocation)
        if let first = pictures.firstIndex(where: { $0.width == carried }) {
            let after = pictures[first...]
            #expect(
                !after.contains { $0.width < carried }, "Went below the variant the link carries after playing it",
                sourceLocation: sourceLocation)
        }
        if let lowest = pictures.firstIndex(where: { $0.width < carried }) {
            #expect(
                !pictures[lowest...].contains { $0.width > carried }, "Back above what the link carries",
                sourceLocation: sourceLocation)
        }
        // This demuxer's lines alone (`streamingName`): the suites running meanwhile give downloads up too.
        let name = demuxer.streamingName + ":"
        let givenUp = LogStore.shared.snapshot().filter {
            $0.timestamp >= since && $0.message.hasPrefix("ABR abandon:") && $0.message.contains(name)
        }
        #expect(
            givenUp.count <= 2, "Gave up \(givenUp.count) downloads: \(givenUp.map(\.message))",
            sourceLocation: sourceLocation)
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
        let since = Date()
        server.setLinkRate(1_500_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        // The link slows as playback starts, with two seconds buffered: the top variant's second segment (its first was
        // read while the demuxer opened) takes ~3.7 s at 1.5 Mbit/s and is given up for the lowest, then 480 follows.
        #expect(
            await Self.waitUntil(timeout: .seconds(16)) { consumer.playedWidth == 480 },
            "Playing \(String(describing: consumer.playedWidth))")
        let stalledSlow = consumer.stalled
        Self.expectCameDownWithoutStalling(consumer, to: 480, demuxer: demuxer, since: since)

        server.setLinkRate(8_000_000 / 8)
        // Chosen at the read position: it plays once the read-ahead before it has (9 s).
        #expect(
            await Self.waitUntil(timeout: .seconds(25)) { consumer.playedWidth == 640 },
            "Playing \(String(describing: consumer.playedWidth))")
        #expect(consumer.stalled - stalledSlow < 0.5, "Stalled \(consumer.stalled - stalledSlow) s on the fast network")
        #expect(demuxer.isAdaptiveBitrateEnabled)
    }

    @Test(
        "A low variant's small segments, slow to be answered, don't hold it there, on connections new or kept",
        arguments: [true, false])
    func latencyIsNoTransfer(closesConnection: Bool) async throws {
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
        // reads a second in 0.33 s of transfer and 0.3 s of latency, within `safety`. A connection kept open answers
        // without `io_open`: there the read that asked counts as latency.
        server.setLinkRate(8_000_000 / 8)
        server.setBehavior(
            .init(delay: .milliseconds(600), closesConnection: closesConnection), forPaths: { $0.hasSuffix(".ts") })
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        // The first pictures are of the variant opened, before the splice to the low one.
        try #require(await Self.waitUntil(timeout: .seconds(10)) { consumer.playedWidth == 320 })
        #expect(
            await Self.waitUntil(timeout: .seconds(20)) { consumer.playedWidth == 640 },
            "Playing \(String(describing: consumer.playedWidth))")
        let estimate = try #require(demuxer.readingDescription { $0.adaptiveBitrate.logic.estimate })
        #expect(estimate > 6_000_000, "Measured \(Int(estimate / 1000)) kbit/s of 8000")
    }

    /// At a switch the old variant's segment is still read while the new one's comes: two transfers share the link and
    /// each ran at about half of it. Taken as the link's rate, the estimate fell below the variant switched to
    /// (0.95 of 1.05 Mbit/s < 1.08) and playback went on down to the lowest.
    @Test("The two transfers of a switch share the link: the estimate stays the link's, the variant it carries stays")
    func switchOverlapIsNoCollapse() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        #expect(demuxer.variants.map(\.width) == [640, 480, 320])
        // The defaults (`MediaDemuxer.startReadAhead`), not the test's quick ones.
        let since = Date()
        server.setLinkRate(1_500_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 30))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        // The start's give-up takes the lowest; the step back up to 480 plays once the read-ahead before it has (~18 s).
        #expect(
            await Self.waitUntil(timeout: .seconds(26)) { consumer.playedWidth == 480 },
            "Playing \(String(describing: consumer.playedWidth))")
        // Past the switch, long enough for the estimate to have fallen if it was going to.
        try await Task.sleep(for: .seconds(8))
        Self.expectCameDownWithoutStalling(consumer, to: 480, demuxer: demuxer, since: since)
        #expect(consumer.playedWidth == 480, "Playing \(String(describing: consumer.playedWidth))")
    }

    @Test("A link the opening's prefetch proves slow starts on the variant it carries, not the best")
    func slowLinkStartsLower() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        // 1.5 Mbit/s carries the 0.97 Mbit/s variant (480), not the 2.66 one (640) the ladder's best is.
        server.setLinkRate(1_500_000 / 8)
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        let selected = try #require(demuxer.variants.first { $0.id == demuxer.selectedVariantId })
        #expect(selected.width == 480, "Started on \(selected.width)")
        #expect(demuxer.variants.first?.width == 640)
    }

    @Test("A fast link measures from the low variant's small segments, and steps up to what it carries at once")
    func fastLinkMeasuresSmallSegments() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()
        let low = try #require(demuxer.variants.last)
        demuxer.selectVariant(id: low.id)
        demuxer.setAdaptiveBitrate(true)

        // 50 Mbit/s: the 320 variant's 75 KB segments take 12 ms each. Samples of half a second of transfer took
        // 40 of them, more than the file has; without an estimate the variant probes up one step at a time.
        server.setLinkRate(50_000_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        try #require(await Self.waitUntil(timeout: .seconds(10)) { consumer.playedWidth == 320 })
        #expect(
            await Self.waitUntil(timeout: .seconds(20)) { consumer.playedWidth == 640 },
            "Playing \(String(describing: consumer.playedWidth))")
        #expect(!consumer.pictures.contains { $0.width == 480 }, "Stepped up through 480")
        #expect(demuxer.readingDescription { $0.adaptiveBitrate.logic.estimate } != nil)
    }

    @Test("The latency share counts from the first segment read, and doesn't leap at the start")
    func latencyShareFromTheStart() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()
        demuxer.setAdaptiveBitrate(false)

        // Half a second before each answer, on a connection of its own, 2-second segments: a quarter of a second per
        // second of media. Reading starts by opening the first segment, with no media read yet, and reads it whole:
        // probing's input closed with the rewind after it.
        server.setBehavior(
            .init(delay: .milliseconds(500), closesConnection: true), forPaths: { $0.hasSuffix(".ts") })
        demuxer.startReadAhead(limits: .init(seconds: 9))
        defer { demuxer.cancel() }
        var shares: [Double] = []
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if let share = demuxer.readingDescription({ $0.adaptiveBitrate.logic.latencyShare }) {
                shares.append(share)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let highest = try #require(shares.max())
        let last = try #require(shares.last)
        #expect(highest < 0.5, "The share reached \(highest)")
        #expect(last > 0.2 && last < 0.4, "The share is \(last)")
    }

    @Test(
        "A server slower to answer than its segments last brings the variant down, however fast the link",
        arguments: [false, true])
    func slowAnswersComeDown(closesConnection: Bool) async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()

        // 1.5 s before each answer of a 2-second segment: the 2.66 Mbit/s variant's take 2.2 s at 8 Mbit/s, over
        // `safety`; the 0.97 Mbit/s one's 1.75 s, within it, and the lowest's 1.6 s. The latency counts as its share,
        // the request asked over a connection new or kept.
        server.setLinkRate(8_000_000 / 8)
        server.setBehavior(
            .init(delay: .milliseconds(1500), closesConnection: closesConnection), forPaths: { $0.hasSuffix(".ts") })
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        #expect(
            await Self.waitUntil(timeout: .seconds(20)) { (consumer.playedWidth ?? 640) < 640 },
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

        // Behind the edge, reads transfer all the time: the estimate is the link's. 2 Mbit/s: 0.7 of it (`upSafety`) is
        // above 480's 1082k and below 640's 2838k, with room both ways. At 1.5 Mbit/s 480 took 72 % of the link, more
        // than the step up allows: the test passed only on an estimate the body's first deliveries raised (1610 kbit/s).
        let since = Date()
        server.setLinkRate(2_000_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        #expect(
            await Self.waitUntil(timeout: .seconds(16)) { consumer.playedWidth == 480 },
            "Playing \(String(describing: consumer.playedWidth))")
        Self.expectCameDownWithoutStalling(consumer, to: 480, demuxer: demuxer, since: since)
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
        #expect(demuxer.readingDescription { $0.adaptiveBitrate.liveEdgeReachedAt } == nil)
    }

    /// At the edge the read-ahead is raised to `highBuffer` (`adaptBitrateIfDue`) while a few seconds are buffered: the
    /// step up on the estimate may take it, a probe past the estimate's reach may not (`isReadAheadReal`).
    @Test("At a live stream's edge, the raised read-ahead is no full one to probe a step up from")
    func liveEdgeDoesNotProbe() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        Self.serveLive(server)
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.adaptiveBitrateConfig = Self.config()
        let mid = try #require(demuxer.variants.first { $0.width == 480 })
        let top = try #require(demuxer.variants.first { $0.width == 640 })
        demuxer.selectVariant(id: mid.id)
        demuxer.setAdaptiveBitrate(true)

        // 4 Mbit/s, measured ~8 % lower (3.66–3.69): 640's 2838k is over 0.7 of that (`upSafety`) and within 0.85
        // (`probeSafety`) less the latency share. At 3.7 Mbit/s the estimate (3385k) stood at the band's lower edge. 480
        // reads up to the edge and waits there; a probe on the raised read-ahead would step up to 640.
        server.setLinkRate(4_000_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        try #require(await Self.waitUntil(timeout: .seconds(10)) { consumer.playedWidth == 480 })
        try await Task.sleep(for: .seconds(12))

        // The case the test is for: the edge reached recently, an estimate of the link in the probe's band.
        let (edge, now, estimate, share) = demuxer.readingDescription {
            (
                $0.adaptiveBitrate.liveEdgeReachedAt, $0.adaptiveTime, $0.adaptiveBitrate.logic.estimate,
                $0.adaptiveBitrate.logic.latencyShare ?? 0
            )
        }
        let reached = try #require(edge, "Never waited at the live edge")
        #expect(now - reached <= MediaDemuxer.liveEdgeMemory)
        let rate = try #require(estimate)
        let bandwidth = Double(top.bandwidth)
        #expect(
            bandwidth > rate * (0.7 - share) && bandwidth <= rate * (0.85 - share),
            "Estimate \(Int(rate / 1000)) kbit/s, latency \(Int(share * 1000)) ms/s: 640 is out of the probe's band")

        let first = try #require(consumer.pictures.firstIndex { $0.width == 480 })
        #expect(!consumer.pictures[first...].contains { $0.width == 640 }, "Probed up to 640 at the live edge")
        #expect(demuxer.selectedVariantId == mid.id)
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
