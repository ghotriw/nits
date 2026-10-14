import CoreMedia
import CoreVideo
import Foundation
import Testing
import os

@testable import NitsCore

/// Diagnostic tests validating that the per-frame `CMVideoFormatDescription` cache in
/// `PlayerEngine.presentToDisplayLayer` actually HITS across consecutive decoded frames.
///
/// If `CMVideoFormatDescriptionMatchesImageBuffer` returned false frame-to-frame, the cache would be
/// a no-op (recreating the descriptor every tick, exactly like before) PLUS the added match cost.
@Suite("Format Description Cache Hit Tests")
struct FormatDescriptionCacheTests {

    /// Decodes real frames through VTVideoDecoder (the decoder that feeds the system render path)
    /// and returns the decoded pixel buffers in decode order.
    private func decodePixelBuffers(preset: SyntheticTestMediaFactory.Preset, maxFrames: Int) -> [CVPixelBuffer] {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset),
            let demuxer = MediaDemuxer(url: path)
        else {
            return []
        }

        final class Box: @unchecked Sendable {
            let lock = OSAllocatedUnfairLock()
            var buffers: [CVPixelBuffer] = []
        }
        let box = Box()
        let decoder = VTVideoDecoder()
        decoder.setOutputHandler { frame in
            box.lock.lock()
            box.buffers.append(frame.pixelBuffer)
            box.lock.unlock()
        }

        var fed = 0
        while fed < maxFrames, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            fed += 1
        }
        decoder.drain()
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.buffers
    }

    /// Replicates the exact caching logic from `presentToDisplayLayer` and counts how many frames
    /// reused the cached descriptor versus how many forced a recreate.
    private func measureCacheHits(_ buffers: [CVPixelBuffer]) -> (hits: Int, recreates: Int) {
        var cached: CMVideoFormatDescription?
        var hits = 0
        var recreates = 0
        for pb in buffers {
            if let c = cached, CMVideoFormatDescriptionMatchesImageBuffer(c, imageBuffer: pb) {
                hits += 1
                continue
            }
            var newDesc: CMVideoFormatDescription?
            let err = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &newDesc)
            if err == noErr, let newDesc {
                cached = newDesc
                recreates += 1
            }
        }
        return (hits, recreates)
    }

    @Test("HDR HEVC: cache hits on every frame after the first")
    func hdrCacheHits() throws {
        let buffers = decodePixelBuffers(preset: .hevc10BitHDR, maxFrames: 30)
        try #require(buffers.count >= 5, "Need several decoded frames to measure cache behavior")

        let (hits, recreates) = measureCacheHits(buffers)
        print("[FmtCache][HDR] frames=\(buffers.count) hits=\(hits) recreates=\(recreates)")

        // The whole optimization relies on exactly ONE recreate (the first frame) and all others hitting.
        #expect(
            recreates == 1,
            "Expected a single descriptor creation; got \(recreates) recreates over \(buffers.count) frames")
        #expect(hits == buffers.count - 1)
    }

    @Test("SDR H.264: cache hits on every frame after the first")
    func sdrCacheHits() throws {
        let buffers = decodePixelBuffers(preset: .multiTrackH264, maxFrames: 30)
        try #require(buffers.count >= 5, "Need several decoded frames to measure cache behavior")

        let (hits, recreates) = measureCacheHits(buffers)
        print("[FmtCache][SDR] frames=\(buffers.count) hits=\(hits) recreates=\(recreates)")

        #expect(
            recreates == 1,
            "Expected a single descriptor creation; got \(recreates) recreates over \(buffers.count) frames")
        #expect(hits == buffers.count - 1)
    }
}
