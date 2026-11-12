// Measurement (skipped unless asked for, see README.md): a real stream played through the engine, then seeks.
import Foundation
import NitsCore
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("Real stream playback measurement", .serialized)
struct RealStreamMeasurement {
    @MainActor
    private func play(_ engine: PlayerEngine, _ label: String, seconds: Double) async -> String {
        let start = ContinuousClock.now
        let from = engine.currentTime
        var buffering = 0.0
        var lastTick = ContinuousClock.now
        var variants: [String] = []
        var lastVariant: Int?
        while (ContinuousClock.now - start) < .seconds(seconds) {
            try? await Task.sleep(for: .milliseconds(100))
            let now = ContinuousClock.now
            if engine.isBuffering || !engine.isPlaying { buffering += (now - lastTick) / .seconds(1) }
            lastTick = now
            if let id = engine.selectedVariantId, id != lastVariant {
                lastVariant = id
                let v = engine.variants.first { $0.id == id }
                variants.append(
                    "\(v.map { "\($0.height)p/\($0.bandwidth / 1000)k" } ?? "?")@"
                        + String(format: "%.1f", (now - start) / .seconds(1)))
            }
        }
        let wall = (ContinuousClock.now - start) / .seconds(1)
        let advanced = engine.currentTime - from
        return String(
            format:
                "%@: %.2f -> %.2f (advanced %.2f in %.2f s wall), not playing/buffering %.2f s, dropped %d, variants %@",
            label, from, engine.currentTime, advanced, wall, buffering, engine.droppedFramesCount,
            variants.joined(separator: " "))
    }

    @MainActor
    private func seekAndPlay(_ engine: PlayerEngine, to target: Double, _ label: String) async -> String {
        let start = ContinuousClock.now
        engine.seek(to: target)
        let settled = await engine.waitUntil(timeout: .seconds(30)) {
            !engine.isSeeking && engine.pendingSeekTime == nil && engine.isPlaying && !engine.isBuffering
        }
        let took = (ContinuousClock.now - start) / .seconds(1)
        let line = String(
            format: "seek %@ to %.2f: settled=%@ in %.2f s, at %.2f", label, target, "\(settled)", took,
            engine.currentTime)
        return line + "\nMEASURE     " + (await play(engine, "after seek " + label, seconds: 5))
    }

    @Test(
        "Play a real stream", .timeLimit(.minutes(5)),
        .enabled(if: ProcessInfo.processInfo.environment["NITS_MEASURE_PLAY_URL"] != nil))
    @MainActor
    func probe() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["NITS_MEASURE_PLAY_URL"])
        let seconds = Double(ProcessInfo.processInfo.environment["NITS_MEASURE_PLAY_SECONDS"] ?? "") ?? 15
        let logStart = Date()
        let engine = PlayerEngine.makeForTesting(
            configuration: PlayerConfiguration(resumePlayback: false), synchronousLocalLoads: false)
        defer { engine.stop() }
        var report: [String] = []
        let openStart = ContinuousClock.now
        engine.load(MediaLoadRequest(path: url))
        let opened = await engine.waitUntil(timeout: .seconds(60)) { engine.isPlaying || engine.loadError != nil }
        let open = (ContinuousClock.now - openStart) / .seconds(1)
        let media = engine.media
        report.append(
            String(
                format: "open: %@ in %.2f s, error %@; duration %.1f, live %@, video %dx%d %@ %@, variants %d",
                "\(opened)", open, engine.loadError ?? "none", media.duration, "\(media.isLive)", media.video.width,
                media.video.height, media.video.codecName, media.video.transferFunction, engine.variants.count))
        report.append(
            "audio tracks: \(engine.audioTracks.map { "\($0.id):\($0.language ?? "-")" }), subtitles: \(engine.subtitles.tracks.map { "\($0.id):\($0.language ?? "-")/\($0.format)" })"
        )
        if engine.loadError == nil && opened {
            report.append(await play(engine, "play", seconds: seconds))
            if media.isLive {
                if let window = engine.live.window() {
                    report.append(String(format: "window %.1f..%.1f", window.start, window.end))
                    report.append(
                        await seekAndPlay(engine, to: max(window.start + 5, engine.currentTime - 30), "back 30"))
                    if let edge = engine.live.edgeTarget() {
                        report.append(await seekAndPlay(engine, to: edge, "edge"))
                    }
                }
            } else if media.duration > 0 {
                report.append(await seekAndPlay(engine, to: media.duration * 0.4, "40%"))
                report.append(await seekAndPlay(engine, to: media.duration * 0.1, "10%"))
            }
        }
        print("MEASURE \(url)\n" + report.map { "MEASURE   " + $0 }.joined(separator: "\n"))
        let notable = LogStore.shared.snapshot().filter { $0.timestamp >= logStart && $0.level >= .warning }
        print("MEASURE log (\(notable.count) warnings/errors):")
        for entry in notable.prefix(60) { print("MEASURE   " + entry.plainTextFormatted) }
    }
}
