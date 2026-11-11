import Foundation
import Testing

@testable import NitsCore

/// Measurement (skipped unless asked for, see README.md): where the opening of a real HLS stream goes, and of a run
/// opened by a seek. Each run opens the stream anew, decodes its first picture, seeks into it and decodes the picture
/// there; it prints the totals and the client's own lines (`HLSOpeningMeasure`) of each phase. `NITS_MEASURE_OPEN_URL`
/// (one or more addresses, comma-separated), `NITS_MEASURE_OPEN_N` (runs after a warm-up, default 5).
@Suite("HLS opening measurement")
struct HLSOpeningMeasurement {
    @Test(
        "Opening split into its steps", .timeLimit(.minutes(20)),
        .enabled(if: ProcessInfo.processInfo.environment["NITS_MEASURE_OPEN_URL"] != nil))
    func measure() throws {
        let environment = ProcessInfo.processInfo.environment
        let urls = try #require(environment["NITS_MEASURE_OPEN_URL"]).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let runs = Int(environment["NITS_MEASURE_OPEN_N"] ?? "") ?? 5
        let label = environment["NITS_MEASURE_LABEL"] ?? "-"
        for url in urls {
            // Run 0 warms the server's cache (and the link's): reported, left out of the analysis.
            for run in 0...runs {
                try measureOnce(url: url, run: run, label: label)
            }
        }
    }

    private func measureOnce(url: String, run: Int, label: String) throws {
        let rtt = URL(string: url)?.host().flatMap(Self.roundTrip(to:)) ?? "-"
        let openStart = Date()
        let clock = ContinuousClock.now
        let demuxer = try #require(MediaDemuxer(url: url))
        let open = ContinuousClock.now - clock
        let decoder = try #require(VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer))
        let frameQueue = FrameQueue()
        demuxer.startReadAhead(limits: .init())
        defer { demuxer.stopReadAhead() }
        let first = SeekPreview.decode(
            demuxer: demuxer, decoder: decoder, frameQueue: frameQueue, seconds: demuxer.videoStartTime, exact: false,
            isCurrent: { true })
        let firstPicture = ContinuousClock.now - clock
        let variant = demuxer.selectedVariantId.flatMap { id in demuxer.variants.first { $0.id == id } }

        // A seek into the middle of a finished stream, past what the read-ahead holds: a run opened at its target.
        var seekReport = "seek=-"
        let seekStart = Date()
        if demuxer.durationSeconds > 30 {
            let target = (demuxer.durationSeconds * 0.4).rounded()
            decoder.flush()
            frameQueue.clear(resetDroppedFrames: true)
            let seekClock = ContinuousClock.now
            let outcome = demuxer.seekReportingCache(to: target, exact: true, forward: false)
            let seek = ContinuousClock.now - seekClock
            let frame = SeekPreview.decode(
                demuxer: demuxer, decoder: decoder, frameQueue: frameQueue, seconds: target, exact: true,
                isCurrent: { true })
            let seekPicture = ContinuousClock.now - seekClock
            seekReport =
                "seekTo=\(Int(target))s seek=\(HLSOpeningMeasure.ms(seek)) seekPicture=\(HLSOpeningMeasure.ms(seekPicture)) "
                + "fromCache=\(outcome.fromCache) seekFrame=\(frame.map { String(format: "%.2f", $0.pts) } ?? "none")"
        }
        let ended = Date()

        print(
            "MEASURE-OPEN label=\(label) url=\(url) run=\(run)\(run == 0 ? "(warm-up)" : "") rtt=\(rtt) "
                + "open=\(HLSOpeningMeasure.ms(open)) firstPicture=\(HLSOpeningMeasure.ms(firstPicture)) "
                + "firstFrame=\(first.map { String(format: "%.2f", $0.pts) } ?? "none") "
                + "variants=\(demuxer.variants.count) start=\(variant.map { "\($0.width)p@\($0.bandwidth / 1000)k" } ?? "-") "
                + seekReport)
        for entry in LogStore.shared.snapshot() where entry.timestamp >= openStart && entry.timestamp <= ended {
            // "HLS client:" tells the opening's link rate, which chooses the start on a slow link (`openingLinkRate`).
            let prefixes = [HLSOpeningMeasure.opening, HLSOpeningMeasure.run, "HLS client:"]
            guard prefixes.contains(where: entry.message.hasPrefix) else { continue }
            print("MEASURE-OPEN   [\(entry.timestamp < seekStart ? "open" : "seek")] \(entry.message)")
        }
    }

    /// The average round trip to `host` by `ping` (three), as the series logs next to each run.
    private static func roundTrip(to host: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "3", "-q", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // "round-trip min/avg/max/stddev = 31.2/33.4/35.0/1.5 ms"
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last(where: { $0.contains("=") }),
            let values = line.split(separator: "=").last?.split(separator: "/"), values.count >= 2
        else { return nil }
        return "\(values[1].trimmingCharacters(in: .whitespaces))ms"
    }
}
