import Foundation
import Testing

@testable import NitsCore

@Suite("Media Duration Probe & Cache Tests")
struct MediaDurationTests {

    /// Polls `condition` every 20 ms until it holds or `timeout` passes.
    private static func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NitsMediaDurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Probe

    @Test(
        "Probe reads durations from container headers",
        arguments: [
            (SyntheticTestMediaFactory.Preset.multiTrackH264, 30.0),  // Matroska segment duration
            (.wideGOPH264, 60.0),  // MP4: per-track durations only
            (.audioOnlyFLAC, 15.0),
        ])
    func probeReadsHeaderDuration(preset: SyntheticTestMediaFactory.Preset, expected: Double) async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
        let duration = await MediaDurationProbe.duration(of: URL(fileURLWithPath: path))
        #expect(duration.map { abs($0 - expected) < 0.5 } == true, "probed \(String(describing: duration))")
    }

    @Test("Time a probe waits for the busy utility queue does not count against its timeout")
    func probeTimeoutStartsWhenWorkStarts() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        // Keep every utility worker computing for longer than the probe's timeout, as playback decoding can.
        // (Blocked workers would not do: GCD starts more threads for them.)
        let busy = DispatchGroup()
        for _ in 0..<(ProcessInfo.processInfo.activeProcessorCount * 2) {
            DispatchQueue.global(qos: .utility).async(group: busy) {
                let end = ContinuousClock.now + .milliseconds(600)
                while ContinuousClock.now < end {}
            }
        }
        let duration = await MediaDurationProbe.duration(of: URL(fileURLWithPath: path), timeout: .milliseconds(300))
        await withCheckedContinuation { done in busy.notify(queue: .global()) { done.resume() } }
        #expect(duration.map { abs($0 - 30) < 0.5 } == true, "probed \(String(describing: duration))")
    }

    @Test("Probe returns nil for missing and non-media files")
    func probeRejectsUnreadableFiles() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.mkv")
        #expect(await MediaDurationProbe.duration(of: missing) == nil)

        let text = directory.appendingPathComponent("notes.mkv")
        try Data("not a media file".utf8).write(to: text)
        #expect(await MediaDurationProbe.duration(of: text) == nil)
    }

    // MARK: - Cache

    @Test("Cache keys local files by size and modification date")
    func cacheInvalidatesChangedFiles() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("clip.mkv")
        try Data(count: 16).write(to: file)

        let cache = MediaDurationCache(fileURL: nil)
        cache.store(42, for: file)
        #expect(cache.duration(for: file) == 42)

        try Data(count: 32).write(to: file)
        #expect(cache.duration(for: file) == nil)
    }

    @Test("Cache ignores query and fragment of network URLs")
    func cacheNormalizesNetworkURLs() throws {
        let cache = MediaDurationCache(fileURL: nil)
        let signed = try #require(URL(string: "http://192.168.1.10/movies/clip.mkv?token=abc#t=10"))
        let plain = try #require(URL(string: "http://192.168.1.10/movies/clip.mkv"))
        cache.store(90, for: signed)
        #expect(cache.duration(for: plain) == 90)
    }

    @Test("Cache persists to disk and reloads")
    func cachePersists() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Durations.json")
        let media = directory.appendingPathComponent("clip.mkv")
        try Data(count: 16).write(to: media)

        MediaDurationCache(fileURL: storeURL, saveDelay: .zero).store(12.5, for: media)
        #expect(await Self.waitUntil { FileManager.default.fileExists(atPath: storeURL.path) })

        #expect(MediaDurationCache(fileURL: storeURL).duration(for: media) == 12.5)
    }

    // MARK: - Playlist

    @Test("Playlist fills in durations of unplayed items in the background")
    @MainActor
    func playlistResolvesDurations() async throws {
        guard let mkv = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264),
            let mp4 = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264)
        else { return }
        let missing = URL(fileURLWithPath: "/nonexistent/NitsMediaDurationTests/missing.mkv")

        let manager = PlaylistManager(durationCache: MediaDurationCache(fileURL: nil))
        manager.append(urls: [URL(fileURLWithPath: mkv), missing, URL(fileURLWithPath: mp4)])

        #expect(await Self.waitUntil { manager.items[0].duration != nil && manager.items[2].duration != nil })
        #expect(abs((manager.items[0].duration ?? 0) - 30) < 0.5)
        #expect(abs((manager.items[2].duration ?? 0) - 60) < 0.5)
        #expect(manager.items[1].duration == nil)
    }

    @Test("Playlist without a cache leaves durations to playback")
    @MainActor
    func playlistWithoutCacheDoesNotProbe() {
        let manager = PlaylistManager()
        manager.append(urls: [URL(fileURLWithPath: "/tmp/video1.mkv")])
        #expect(manager.items[0].duration == nil)
    }

    @Test("Durations learned during playback are cached")
    @MainActor
    func playbackDurationIsCached() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("clip.mkv")
        try Data(count: 16).write(to: media)

        let cache = MediaDurationCache(fileURL: nil)
        let manager = PlaylistManager(durationCache: cache)
        manager.append(urls: [media])
        manager.updateCurrentItemDuration(77)

        #expect(await Self.waitUntil { cache.duration(for: media) == 77 })
    }
}
