import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// A segment download given up for a lower variant's of the same segment (`MediaDemuxer.requestAbandon`), against
/// `TestHTTPServer` throttled. Only the mechanics of 5b-2: the old variant's bytes stop, the demuxer takes the interrupt as
/// none, the new variant reads the segment from its start, and playback goes on. The cut that makes the switch invisible is
/// not made yet: the splice is the ordinary one.
@Suite("Giving a download up", .serialized, .hostDependent, .networkServer, .realtimePlayback, .backstopTimeLimit)
struct AbandonDownloadTests {
    /// The pictures and the sound taken run on without a hole or a repeat: each picture a frame after the one before (30 fps),
    /// the sound's packets in order with no gap of more than a tenth of a second.
    private func expectContinuous(
        _ consumer: AdaptiveBitrateTests.RealtimeConsumer, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let pictures = consumer.pictures.map(\.pts)
        for (before, after) in zip(pictures, pictures.dropFirst()) {
            #expect(
                after > before, "A picture repeated or out of order: \(before) then \(after)",
                sourceLocation: sourceLocation)
            #expect(
                after - before < 0.1, "A hole of \(after - before) s in the pictures after \(before)",
                sourceLocation: sourceLocation)
        }
        let audio = consumer.audio
        for (before, after) in zip(audio, audio.dropFirst()) {
            #expect(after >= before, "Sound out of order: \(before) then \(after)", sourceLocation: sourceLocation)
            #expect(
                after - before < 0.1, "A hole of \(after - before) s in the sound after \(before)",
                sourceLocation: sourceLocation)
        }
    }

    /// Gives up the switch under way when it is one that took a download over and has not spliced; false when it is not.
    private func cancelPendingSwitch(of demuxer: MediaDemuxer) -> Bool {
        // The read thread waits for the lower variant's late answer holding the lock: ask it to step aside, as a seek does.
        demuxer.lockIO(yielding: true)
        demuxer.queueLock.lock()
        defer {
            demuxer.queueLock.unlock()
            demuxer.lock.unlock()
        }
        guard demuxer.variantSwitch?.spliceTime == nil, demuxer.variantSwitch?.isPreviousAbandoned == true else {
            return false
        }
        demuxer.cancelVariantSwitch(reporting: false)
        return true
    }

    /// The first log message after the `after`th that `matches`, waited for.
    private func waitForMessage(timeout: Duration, since: Date, _ matches: @Sendable (String) -> Bool) async -> String?
    {
        var found: String?
        _ = await AdaptiveBitrateTests.waitUntil(timeout: timeout) {
            found = logs(since: since).map(\.message).first(where: matches)
            return found != nil
        }
        return found
    }

    /// `choose` stays out of the way: it never steps down (a read-ahead is never below `highBuffer`), so what happens is the
    /// check of the download's doing.
    private static func config() -> AdaptiveBitrateLogic.Config {
        var config = AdaptiveBitrateTests.config()
        config.highBuffer = 0.01
        return config
    }

    /// The log entries since `since`. By time, not by how many there were: the store keeps the last 2000, and in a long run
    /// it is full, so a count taken before the test would hide everything after it.
    private func logs(since: Date) -> [LogEntry] {
        LogStore.shared.snapshot().filter { $0.timestamp >= since }
    }

    private func messages(containing text: String) -> [String] {
        LogStore.shared.snapshot().map(\.message).filter { $0.contains(text) }
    }

    @Test("A top variant's segment on a link that cannot carry it is given up for a lower one's, and playback goes on")
    func givesUpAHeavySegment() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        // Opened on a fast link: it starts on the top variant (640 wide).
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        #expect(demuxer.variants.map(\.width) == [640, 480, 320])
        demuxer.abandonsDownloads = true
        demuxer.adaptiveBitrateConfig = Self.config()
        let since = Date()

        server.setLinkRate(700_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        let acted = await AdaptiveBitrateTests.waitUntil(timeout: .seconds(20)) {
            logs(since: since).contains {
                $0.message.hasPrefix("ABR abandon:") && !$0.message.contains("not acted on")
            }
        }
        #expect(acted, "No download was given up: \(messages(containing: "ABR abandon").suffix(3))")
        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(25)) {
                consumer.playedWidth.map { $0 < 640 } ?? false
            }, "Playing \(String(describing: consumer.playedWidth))")
        // The interrupt of the old download was no end of the input, nor an error.
        let stopped = logs(since: since).filter { $0.message.contains("Read-ahead stopped") }
        #expect(stopped.isEmpty, "\(stopped.map(\.message))")
        let played = consumer.pictures.count
        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(10)) { consumer.pictures.count > played + 20 },
            "Playback stopped after \(played) pictures")
        // The new variant read the segment from its start: a request of a lower variant's segment that the top one's was
        // given up for.
        let given = logs(since: since).first {
            $0.message.contains("given up") && $0.message.contains("read from its start")
        }
        #expect(given != nil, "The switch did not say it read the segment from its start")
        expectContinuous(consumer)
        // On the server: a segment asked for of two variants (the top one's given up, a lower one's whole from its start).
        let segments = server.requests.filter { $0.path.hasSuffix(".ts") }
        let byNumber = Dictionary(grouping: segments) { $0.path.split(separator: "_").last.map(String.init) ?? "" }
        let twice = byNumber.values.first { Set($0.map { $0.path.split(separator: "_")[0] }).count == 2 }
        let second = try #require(twice?.last, "No segment was asked for of two variants: \(segments.map(\.path))")
        #expect(
            second.range == nil || second.range?.hasPrefix("bytes=0-") == true, "\(String(describing: second.range))")
    }

    @Test("With the read-ahead full the lower variant reads the segment given up, not the one before it")
    func joinsAtTheSegmentWithAFullBuffer() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.abandonsDownloads = true
        demuxer.adaptiveBitrateConfig = Self.config()
        let since = Date()
        // A fast link: the read-ahead fills and playback runs on the top variant, then the link slows with segments ahead.
        demuxer.startReadAhead(limits: .init(seconds: 6))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(20)) { (consumer.pictures.last?.pts ?? 0) > 5 },
            "Playback did not reach 5 s")
        server.setLinkRate(500_000 / 8)

        let message = await waitForMessage(timeout: .seconds(25), since: since) {
            $0.hasPrefix("ABR abandon:") && !$0.contains("not acted on")
        }
        let line = try #require(message, "No download was given up")
        // "... variant 3 (2500 kbit/s) segment 4 [8.00..10.00 s] ...": a segment past the first, ahead of the position.
        let sequence = try #require(
            line.range(of: #"segment (\d+)"#, options: .regularExpression).flatMap {
                Int(line[$0].dropFirst("segment ".count))
            })
        #expect(sequence > 2, "The segment given up was \(sequence)")
        // The variant it was replaced by read that segment from its start: the first segment of another variant asked for.
        let numbers = { (name: String) in name.split(separator: "_").last.map { String($0.prefix(3)) } }
        let segments = server.requests.filter { $0.path.hasSuffix(".ts") }
        let topPrefix = try #require(
            segments.first { numbers($0.path) == String(format: "%03d", sequence) }?.path.split(separator: "_").first)
        // The switch is made at the next read: the other variant's request comes a moment after the log line.
        let isAsked = { () -> Bool in
            server.requests.contains { $0.path.hasSuffix(".ts") && !$0.path.hasPrefix(topPrefix + "_") }
        }
        _ = await AdaptiveBitrateTests.waitUntil(timeout: .seconds(8), isAsked)
        let others = server.requests.filter { $0.path.hasSuffix(".ts") && !$0.path.hasPrefix(topPrefix + "_") }
        let first = try #require(others.first, "No other variant's segment was asked for")
        #expect(numbers(first.path) == String(format: "%03d", sequence), "Read \(first.path), not segment \(sequence)")
        let cut = await waitForMessage(timeout: .seconds(20), since: since) { $0.contains("given up was cut at") }
        #expect(cut != nil, "The old variant's queued tail was not cut")
        // The switch is cut, not joined with a hole: playback runs on from the segment given up.
        // Playback has to get past the cut to say so: the segment given up is ahead of it.
        let cutAt = try #require(
            cut?.range(of: #"cut at (\d+\.\d+)"#, options: .regularExpression).flatMap {
                Double(cut![$0].dropFirst("cut at ".count))
            })
        let past = await AdaptiveBitrateTests.waitUntil(timeout: .seconds(40)) {
            (consumer.pictures.last?.pts ?? 0) > cutAt + 1.5
        }
        #expect(
            past, "Playback did not get past the cut at \(cutAt) s: \(String(describing: consumer.pictures.last?.pts))")
        expectContinuous(consumer)
    }

    @Test("A switch that took a download over and is given up reads it again without repeating what it had queued")
    func restartsWhatTheCancelledSwitchTookOver() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        demuxer.abandonsDownloads = true
        demuxer.adaptiveBitrateConfig = Self.config()
        let since = Date()
        demuxer.startReadAhead(limits: .init(seconds: 6))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(20)) { (consumer.pictures.last?.pts ?? 0) > 5 },
            "Playback did not reach 5 s")
        // The lower variants answer late: the switch that takes the download over has no keyframe for a while.
        var late = TestHTTPServer.Behavior()
        late.delay = .seconds(4)
        server.setBehavior(late) { $0.hasPrefix("v0_") || $0.hasPrefix("v1_") }
        server.setLinkRate(500_000 / 8)
        let switching = await waitForMessage(timeout: .seconds(25), since: since) {
            $0.contains("read from its start")
        }
        let line = try #require(switching, "No download was taken over")
        // The new variant has not yet read its keyframe (it takes ~1.5 s at this rate): the switch is given up as the
        // check of its description would, when the variant read does not match.
        let isPending = cancelPendingSwitch(of: demuxer)
        try #require(isPending, "The switch had spliced before it was given up: \(line)")

        server.setLinkRate(nil)
        server.setBehavior(TestHTTPServer.Behavior()) { $0.hasPrefix("v0_") || $0.hasPrefix("v1_") }
        let sequence = try #require(
            line.range(of: #"segment (\d+) read"#, options: .regularExpression).flatMap {
                Int(line[$0].dropFirst("segment ".count).prefix { $0.isNumber })
            })
        // Playback gets past the segment: nothing queued of it twice.
        let past = await AdaptiveBitrateTests.waitUntil(timeout: .seconds(40)) {
            (consumer.pictures.last?.pts ?? 0) > Double(sequence * 2) + 3
        }
        #expect(
            past, "Playback did not get past segment \(sequence): \(String(describing: consumer.pictures.last?.pts))")
        expectContinuous(consumer)
        // What it read again was spliced into what it had queued at the first keyframe read again.
        #expect(
            logs(since: since).contains { $0.message.contains("a download given up is read again from") },
            "The segment read again was not spliced in")
        // And the top variant read the segment twice: the one given up, and again from its start.
        let number = String(format: "%03d", sequence)
        let again = server.requests.filter { $0.path.hasSuffix("_\(number).ts") }
        let prefixes = again.map { $0.path.split(separator: "_")[0] }
        #expect(prefixes.filter { $0 == prefixes.first }.count >= 2, "Asked for: \(again.map(\.path))")
    }

    @Test("Nothing is given up unless asked for")
    func isOffByDefault() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        #expect(!demuxer.abandonsDownloads)
        demuxer.adaptiveBitrateConfig = AdaptiveBitrateTests.config()
        let since = Date()
        server.setLinkRate(700_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        _ = await AdaptiveBitrateTests.waitUntil(timeout: .seconds(8)) { false }
        let acted = logs(since: since).filter {
            $0.message.hasPrefix("ABR abandon:") && !$0.message.contains("not acted on")
        }
        #expect(acted.isEmpty)
    }
}
