import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// Measurement (skipped unless asked for, see README.md): how adaptive bitrate starts on a slow link, on the synthetic ladder behind `TestHTTPServer`
/// at a rate. `NITS_MEASURE_START=1`, `NITS_LINK_KBPS` (default "1500,600").
@Suite("ABR start measurement", .serialized, .networkServer)
struct ABRStartMeasurement {
    @Test(
        "Start on a slow link", .timeLimit(.minutes(10)),
        .enabled(if: ProcessInfo.processInfo.environment["NITS_MEASURE_START"] != nil))
    func measure() async throws {
        let master = try #require(SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder))
        let rates = (ProcessInfo.processInfo.environment["NITS_LINK_KBPS"] ?? "1500,600").split(separator: ",")
            .compactMap { Int($0) }
        for kbps in rates {
            let server = try TestHTTPServer(root: URL(fileURLWithPath: master).deletingLastPathComponent())
            defer { server.stop() }
            server.setLinkRate(kbps * 1000 / 8)
            let openStart = ContinuousClock.now
            let demuxer = try #require(MediaDemuxer(url: server.url("master.m3u8")))
            let openSeconds = (ContinuousClock.now - openStart) / .seconds(1)
            let prefetch = LogStore.shared.snapshot().last { $0.message.hasPrefix("HLS client") }?.message ?? "none"
            let bandwidths = demuxer.variants.map { "\($0.width)p@\($0.bandwidth / 1000)k" }.joined(separator: " ")
            let duration = Int(ProcessInfo.processInfo.environment["NITS_MEASURE_START_SECONDS"] ?? "") ?? 60
            demuxer.startReadAhead(limits: .init(seconds: 30))
            let consumerStart = ContinuousClock.now
            let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
            var timeline: [(at: Double, width: Int32)] = []
            var firstPicture: Double?
            while (ContinuousClock.now - consumerStart) < .seconds(duration) {
                try await Task.sleep(for: .milliseconds(100))
                let now = (ContinuousClock.now - consumerStart) / .seconds(1)
                if let last = consumer.pictures.last {
                    if firstPicture == nil { firstPicture = now }
                    if timeline.last?.width != last.width { timeline.append((now, last.width)) }
                }
            }
            consumer.stop()
            demuxer.stopReadAhead()
            print(
                "MEASURE-START link=\(kbps) kbit/s prefetch=[\(prefetch)] open=\(String(format: "%.1f", openSeconds)) s ladder=[\(bandwidths)] "
                    + "firstPicture=\(firstPicture.map { String(format: "%.1f", $0) } ?? "none") s "
                    + "stalled=\(String(format: "%.1f", consumer.stalled)) s "
                    + "pictures=\(consumer.pictures.count) widths=\(timeline.map { "\($0.width)@\(String(format: "%.0f", $0.at))s" })"
            )
        }
    }
}

/// Measurement (skipped unless asked for, see README.md): the opening's prefetch rate against the estimate playback reaches, on a real stream.
/// `NITS_MEASURE_START_URL`, `NITS_MEASURE_START_SECONDS` (default 25).
@Suite("ABR start measurement, real stream", .serialized, .networkServer)
struct ABRStartRealMeasurement {
    private static func latencyShare(of demuxer: MediaDemuxer) -> Double? {
        demuxer.queueLock.lock()
        defer { demuxer.queueLock.unlock() }
        return demuxer.adaptiveBitrate.logic.latencyShare
    }

    private static func estimate(of demuxer: MediaDemuxer) -> Double? {
        demuxer.queueLock.lock()
        defer { demuxer.queueLock.unlock() }
        return demuxer.adaptiveBitrate.logic.estimate
    }

    @Test(
        "Prefetch rate against the estimate", .timeLimit(.minutes(5)),
        .enabled(if: ProcessInfo.processInfo.environment["NITS_MEASURE_START_URL"] != nil))
    func measure() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["NITS_MEASURE_START_URL"])
        let seconds = Int(ProcessInfo.processInfo.environment["NITS_MEASURE_START_SECONDS"] ?? "") ?? 25
        let openStart = ContinuousClock.now
        let demuxer = try #require(MediaDemuxer(url: url))
        let open = (ContinuousClock.now - openStart) / .seconds(1)
        let prefetch = LogStore.shared.snapshot().last { $0.message.hasPrefix("HLS client") }?.message ?? "none"
        // NITS_MEASURE_START_KBPS: start on the switchable variant nearest that bandwidth (adaptive bitrate stays on),
        // to tell what a better start would be worth.
        if let kbps = Int(ProcessInfo.processInfo.environment["NITS_MEASURE_START_KBPS"] ?? ""),
            let target = demuxer.variants.filter(\.isSwitchable).min(by: {
                abs($0.bandwidth / 1000 - kbps) < abs($1.bandwidth / 1000 - kbps)
            })
        {
            demuxer.selectVariant(id: target.id)
            demuxer.seek(to: demuxer.videoStartTime)
            demuxer.setAdaptiveBitrate(true)
        }
        let first = demuxer.selectedVariantId.flatMap { id in demuxer.variants.first { $0.id == id } }
        demuxer.startReadAhead(limits: .init())
        let readStart = ContinuousClock.now
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer)
        var firstPicture: Double?
        var estimates: [Int] = []
        var latencies: [Int] = []
        var decided: [String] = []
        var shown: [String] = []
        var lastDecided: Int?
        var lastShownWidth: Int32?
        var tick = 0
        while (ContinuousClock.now - readStart) < .seconds(seconds) {
            try await Task.sleep(for: .milliseconds(100))
            tick += 1
            let now = (ContinuousClock.now - readStart) / .seconds(1)
            if let picture = consumer.pictures.last {
                if firstPicture == nil { firstPicture = now }
                if picture.width != lastShownWidth {
                    lastShownWidth = picture.width
                    shown.append("\(picture.width)@\(String(format: "%.1f", now))s")
                }
            }
            // The reading position decides ahead of what is shown: the moment of each decision is told apart.
            if let id = demuxer.selectedVariantId, id != lastDecided {
                lastDecided = id
                if let variant = demuxer.variants.first(where: { $0.id == id }) {
                    decided.append("\(variant.width)p@\(variant.bandwidth / 1000)k@\(String(format: "%.1f", now))s")
                }
            }
            if tick % 10 == 0 {
                estimates.append(Int((Self.estimate(of: demuxer) ?? 0) / 1000))
                latencies.append(Int((Self.latencyShare(of: demuxer) ?? 0) * 1000))
            }
        }
        consumer.stop()
        demuxer.stopReadAhead()
        for entry in LogStore.shared.snapshot() where entry.message.hasPrefix("ABR abandon") {
            print("MEASURE-REAL   [abandon] \(entry.message)")
        }
        print(
            "MEASURE-REAL label=\(ProcessInfo.processInfo.environment["NITS_MEASURE_LABEL"] ?? "-") url=\(url) open=\(String(format: "%.1f", open)) s start=\(first.map { "\($0.width)p@\($0.bandwidth / 1000)k" } ?? "-") "
                + "firstPicture=\(firstPicture.map { String(format: "%.1f", $0) } ?? "none") s stalled=\(String(format: "%.1f", consumer.stalled)) s "
                + "prefetch=[\(prefetch)] estimate(kbit/s, per s)=\(estimates) latencyShare(ms/s)=\(latencies) decided=\(decided) shown=\(shown)"
        )
    }
}
