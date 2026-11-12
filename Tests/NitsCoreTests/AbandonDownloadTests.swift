import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// A segment download given up for a lower variant's of the same segment (`MediaDemuxer.requestAbandon`), against
/// `TestHTTPServer` throttled. Only the mechanics of 5b-2: the old variant's bytes stop, the demuxer takes the interrupt as
/// none, the new variant reads the segment from its start, and playback goes on. The cut that makes the switch invisible is
/// not made yet: the splice is the ordinary one.
@Suite("Giving a download up", .serialized, .hostDependent, .networkServer, .timeLimit(.minutes(2)))
struct AbandonDownloadTests {
    /// The first log message after the `after`th that `matches`, waited for.
    private func waitForMessage(timeout: Duration, after: Int, _ matches: @Sendable (String) -> Bool) async -> String? {
        var found: String?
        _ = await AdaptiveBitrateTests.waitUntil(timeout: timeout) {
            found = LogStore.shared.snapshot().dropFirst(after).map(\.message).first(where: matches)
            return found != nil
        }
        return found
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
        demuxer.adaptiveBitrateConfig = AdaptiveBitrateTests.config()
        let before = LogStore.shared.snapshot().count

        server.setLinkRate(700_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
        defer { consumer.stop() }

        let acted = await AdaptiveBitrateTests.waitUntil(timeout: .seconds(20)) {
            LogStore.shared.snapshot().dropFirst(before).contains {
                $0.message.hasPrefix("ABR abandon:") && !$0.message.contains("not acted on")
            }
        }
        #expect(acted, "No download was given up: \(messages(containing: "ABR abandon").suffix(3))")
        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(25)) {
                consumer.playedWidth.map { $0 < 640 } ?? false
            }, "Playing \(String(describing: consumer.playedWidth))")
        // The interrupt of the old download was no end of the input, nor an error.
        let stopped = LogStore.shared.snapshot().dropFirst(before).filter { $0.message.contains("Read-ahead stopped") }
        #expect(stopped.isEmpty, "\(stopped.map(\.message))")
        let played = consumer.pictures.count
        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(10)) { consumer.pictures.count > played + 20 },
            "Playback stopped after \(played) pictures")
        // The new variant read the segment from its start: a request of a lower variant's segment that the top one's was
        // given up for.
        let given = LogStore.shared.snapshot().dropFirst(before).first {
            $0.message.contains("given up") && $0.message.contains("read from its start")
        }
        #expect(given != nil, "The switch did not say it read the segment from its start")
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
        demuxer.adaptiveBitrateConfig = AdaptiveBitrateTests.config()
        let before = LogStore.shared.snapshot().count
        // A fast link: the read-ahead fills and playback runs on the top variant, then the link slows with segments ahead.
        demuxer.startReadAhead(limits: .init(seconds: 6))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(20)) { (consumer.pictures.last?.pts ?? 0) > 5 },
            "Playback did not reach 5 s")
        server.setLinkRate(500_000 / 8)

        let message = await waitForMessage(timeout: .seconds(25), after: before) {
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
        let others = segments.filter { !$0.path.hasPrefix(topPrefix + "_") }
        let first = try #require(others.first, "No other variant's segment was asked for")
        #expect(numbers(first.path) == String(format: "%03d", sequence), "Read \(first.path), not segment \(sequence)")
    }

    @Test("Nothing is given up unless asked for")
    func isOffByDefault() async throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
        #expect(!demuxer.abandonsDownloads)
        demuxer.adaptiveBitrateConfig = AdaptiveBitrateTests.config()
        let before = LogStore.shared.snapshot().count
        server.setLinkRate(700_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 9))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
        defer { consumer.stop() }
        _ = await AdaptiveBitrateTests.waitUntil(timeout: .seconds(8)) { false }
        let acted = LogStore.shared.snapshot().dropFirst(before).filter {
            $0.message.hasPrefix("ABR abandon:") && !$0.message.contains("not acted on")
        }
        #expect(acted.isEmpty)
    }
}
