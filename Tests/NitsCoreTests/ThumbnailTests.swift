import CoreGraphics
import Foundation
import Testing
import os

@testable import NitsCore

@Suite("Thumbnail System Tests")
struct ThumbnailTests {

    @Test("ThumbnailDiskCache computes stable keys and stores/loads thumbnails")
    func testThumbnailDiskCache() throws {
        let tempCacheDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let cache = ThumbnailDiskCache(customCacheDirectory: tempCacheDir)
        defer { try? FileManager.default.removeItem(at: tempCacheDir) }

        let fakePath = "/tmp/test_video_non_existent.mkv"
        let key = cache.cacheKey(for: fakePath)
        // Since file doesn't exist on disk, returns nil
        #expect(key == nil)

        // For network or URL, returns sha256 hash
        let netKey = cache.cacheKey(for: "http://example.com/video.mp4")
        #expect(netKey != nil)
        #expect(netKey?.count == 64)

        // Create a temporary real file
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_thumb_target.mp4")
        try Data("dummy mp4 content bytes for testing".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let resolvedPath = tempURL.standardizedFileURL.path
        let fileKey = cache.cacheKey(for: resolvedPath)
        #expect(fileKey != nil)

        // Create a simple dummy CGImage (16x16 RGB)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var rawBytes = [UInt8](repeating: 200, count: 16 * 16 * 4)
        let context = CGContext(
            data: &rawBytes,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let cgImage = context.makeImage()!

        let item = ThumbnailItem(time: 2.5, image: cgImage, width: 16, height: 16)
        cache.saveThumbnails([item], for: fileKey!)

        let loaded = cache.loadThumbnails(for: fileKey!)
        #expect(loaded != nil)
        #expect(loaded?.count == 1)
        #expect(loaded?.first?.time == 2.5)
        #expect(loaded?.first?.width == 16)
        #expect(loaded?.first?.height == 16)
    }

    @Test("ThumbnailManager binary search finds closest timestamp")
    @MainActor
    func testThumbnailManagerBinarySearch() async throws {
        let tempCacheDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let diskCache = ThumbnailDiskCache(customCacheDirectory: tempCacheDir)
        defer { try? FileManager.default.removeItem(at: tempCacheDir) }

        let manager = ThumbnailManager(diskCache: diskCache)
        #expect(manager.thumbnail(at: 10) == nil)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var rawBytes = [UInt8](repeating: 128, count: 8 * 8 * 4)
        let context = CGContext(
            data: &rawBytes,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let dummyImage = context.makeImage()!

        let t0 = ThumbnailItem(time: 0.0, image: dummyImage, width: 8, height: 8)
        let t1 = ThumbnailItem(time: 10.0, image: dummyImage, width: 8, height: 8)
        let t2 = ThumbnailItem(time: 20.0, image: dummyImage, width: 8, height: 8)
        let t3 = ThumbnailItem(time: 30.0, image: dummyImage, width: 8, height: 8)

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_thumb_lookup.mp4")
        try Data("lookup content bytes".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let resolvedPath = tempURL.standardizedFileURL.path
        let key = diskCache.cacheKey(for: resolvedPath)!
        diskCache.saveThumbnails([t0, t1, t2, t3], for: key)

        await manager.prepareThumbnailsAsync(for: resolvedPath, duration: 30.0)

        #expect(manager.thumbnails.count == 4)
        #expect(manager.thumbnail(at: 0.0)?.time == 0.0)
        #expect(manager.thumbnail(at: 4.0)?.time == 0.0)
        #expect(manager.thumbnail(at: 6.0)?.time == 10.0)
        #expect(manager.thumbnail(at: 14.9)?.time == 10.0)
        #expect(manager.thumbnail(at: 15.1)?.time == 20.0)
        #expect(manager.thumbnail(at: 50.0)?.time == 30.0)
    }

    @Test("ThumbnailGenerator runs on synthetic video without crash")
    func testThumbnailGeneratorSynthetic() async throws {
        guard let mediaPath = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else {
            // If ffmpeg is missing in test environment, skip gracefully per Test Media Policy
            return
        }

        let generator = ThumbnailGenerator(path: mediaPath)
        let progressCalls = os.OSAllocatedUnfairLock(initialState: 0)
        let thumbnails = await generator.generateThumbnails { items in
            progressCalls.withLock { $0 += 1 }
            #expect(!items.isEmpty)
        }

        #expect(!thumbnails.isEmpty)
        #expect(thumbnails.first?.width == Int(ThumbnailGenerator.targetThumbnailWidth))
        #expect(thumbnails.first?.image != nil)
    }

    @Test("ThumbnailGenerator runs on MP4 HEVC synthetic video and applies HDR tone mapping")
    func testThumbnailGeneratorHEVC() async throws {
        guard let mediaPath = SyntheticTestMediaFactory.ensureMedia(preset: .hevc10BitHDR) else {
            return
        }

        let generator = ThumbnailGenerator(path: mediaPath)
        let thumbnails = await generator.generateThumbnails { _ in }
        #expect(!thumbnails.isEmpty)
        guard let first = thumbnails.first else { return }
        #expect(first.image.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test("ThumbnailGenerator runs on wide GOP MP4 video")
    func testThumbnailGeneratorWideGOP() async throws {
        guard let mediaPath = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else {
            return
        }

        let generator = ThumbnailGenerator(path: mediaPath)
        let thumbnails = await generator.generateThumbnails { _ in }
        #expect(!thumbnails.isEmpty)
    }

    @Test("PlayerEngine prepareThumbnails populates thumbnails on load")
    @MainActor
    func testPlayerEngineThumbnailsOnLoad() async throws {
        guard let mediaPath = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else {
            return
        }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: mediaPath)

        for _ in 0..<50 {
            if !engine.thumbnailManager.thumbnails.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(!engine.thumbnailManager.thumbnails.isEmpty)
        #expect(engine.thumbnailManager.thumbnail(at: 1.0) != nil)
    }

    @Test("MediaDemuxer.isLocalNetworkURL detects LAN IPs and hostnames correctly")
    func testIsLocalNetworkURL() {
        // LAN IPv4
        #expect(MediaDemuxer.isLocalNetworkURL("http://192.168.1.83:8096/stream"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://10.0.0.1/video.mkv"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://172.16.0.10:8000/media.mp4"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://172.31.255.254/media.mp4"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://169.254.1.2/video.mp4"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://127.0.0.1:8080/stream"))

        // LAN hostnames / Bonjour
        #expect(MediaDemuxer.isLocalNetworkURL("http://localhost:3000/video.mp4"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://media-server.local/stream.mkv"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://nas.lan/video.mp4"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://emby.home:8096/stream"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://server.internal/video.mp4"))

        // LAN IPv6 (including bracketed URL literals)
        #expect(MediaDemuxer.isLocalNetworkURL("http://[::1]:8080/stream"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://[fe80::1]:8080/stream"))
        #expect(MediaDemuxer.isLocalNetworkURL("http://[fd12:3456:789a::1]:8080/stream"))

        // WAN / External IPs and domains
        #expect(!MediaDemuxer.isLocalNetworkURL("http://8.8.8.8/video.mp4"))
        #expect(!MediaDemuxer.isLocalNetworkURL("https://example.com/stream.m3u8"))
        #expect(!MediaDemuxer.isLocalNetworkURL("http://172.32.0.1/video.mp4"))
        #expect(!MediaDemuxer.isLocalNetworkURL("http://1.1.1.1:8080/stream"))
        #expect(!MediaDemuxer.isLocalNetworkURL("https://cdn.movies.org/video.mp4"))
        #expect(!MediaDemuxer.isLocalNetworkURL("http://[2001:4860:4860::8888]/video.mp4"))

        // Local non-network file
        #expect(!MediaDemuxer.isLocalNetworkURL("/Users/test/video.mp4"))
    }

    @Test("MediaDemuxer.ffmpegErrorDescription provides readable error strings")
    func testFFmpegErrorDescription() {
        let eofDesc = MediaDemuxer.ffmpegErrorDescription(-541_478_725)  // AVERROR_EOF
        #expect(!eofDesc.isEmpty)
        #expect(eofDesc.lowercased().contains("end of file"))
    }

    @Test("PlayerConfiguration networkThumbnailPolicy persistence and CLI flags")
    func testNetworkThumbnailPolicyConfiguration() {
        let defaultConfig = PlayerConfiguration()
        #expect(defaultConfig.networkThumbnailPolicy == .localNetworkOnly)

        // CLI parsing
        let (parsedAlways, _) = PlayerConfiguration.parse(arguments: ["app", "--network-thumbnails=always"])
        #expect(parsedAlways.networkThumbnailPolicy == .always)

        let (parsedNever, _) = PlayerConfiguration.parse(arguments: ["app", "--no-network-thumbnails"])
        #expect(parsedNever.networkThumbnailPolicy == .never)

        let (parsedLAN, _) = PlayerConfiguration.parse(arguments: ["app", "--network-thumbnails=lan"])
        #expect(parsedLAN.networkThumbnailPolicy == .localNetworkOnly)

        // UserDefaults save and load
        let suite = UserDefaults(suiteName: "TestThumbnailPolicySuite_\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }

        var config = PlayerConfiguration()
        config.networkThumbnailPolicy = .always
        config.saveToUserDefaults(userDefaults: suite)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: suite)
        #expect(loaded.networkThumbnailPolicy == .always)
    }

    @Test("ThumbnailManager skips WAN streams with default localNetworkOnly policy")
    @MainActor
    func testThumbnailManagerPolicyFiltering() async {
        let manager = ThumbnailManager()
        // WAN stream with .localNetworkOnly policy should skip immediately
        let items = await manager.prepareThumbnailsAsync(
            for: "http://example.com/video.mp4",
            duration: 100.0,
            networkPolicy: .localNetworkOnly
        )
        #expect(items.isEmpty)
        #expect(!manager.isGenerating)
    }
}
