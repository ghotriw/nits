import CoreMedia
import CoreVideo
import Foundation
import Testing
import os

@testable import NitsCore

/// Tests that the per-frame `CMVideoFormatDescription` cache in
/// `PlayerEngine.presentToDisplayLayer` actually HITS across consecutive decoded frames.
///
/// If sample creation rejected the cached descriptor frame-to-frame, the cache would be a no-op (recreating the
/// descriptor every tick) plus a failed creation per frame.
@Suite("Format Description Cache Hit Tests")
struct FormatDescriptionCacheTests {

    /// Decodes real frames through VTVideoDecoder (the decoder that feeds the system render path)
    /// and returns the decoded pixel buffers in decode order.
    /// `diagnostics` describes how VideoToolbox answered, for a failure message: CI once got 1–3 frames of 30.
    private func decodePixelBuffers(
        preset: SyntheticTestMediaFactory.Preset, maxFrames: Int
    ) -> (buffers: [CVPixelBuffer], diagnostics: String) {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset),
            let demuxer = MediaDemuxer(url: path)
        else {
            return ([], "media unavailable")
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
        var decodeErrors: [OSStatus: Int] = [:]
        while fed < maxFrames, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            if decoder.lastDecodeStatus != noErr { decodeErrors[decoder.lastDecodeStatus, default: 0] += 1 }
            fed += 1
        }
        decoder.drain()
        let diagnostics =
            "fed \(fed), session creation \(decoder.sessionStatus), decode errors \(decodeErrors), "
            + "last callback status \(decoder.lastCallbackStatus)"
        box.lock.lock()
        defer { box.lock.unlock() }
        return (box.buffers, diagnostics)
    }

    /// Runs frames through the caching in `presentToDisplayLayer` and counts how many reused the cached
    /// descriptor versus how many forced a recreate.
    private func measureCacheHits(_ buffers: [CVPixelBuffer]) -> (hits: Int, recreates: Int) {
        var cached: CMVideoFormatDescription?
        var hits = 0
        var recreates = 0
        for pb in buffers {
            let (sample, rebuilt) = PlayerEngine.makeDisplaySampleBuffer(for: pb, formatDescription: &cached)
            guard sample != nil else { continue }
            if rebuilt { recreates += 1 } else { hits += 1 }
        }
        return (hits, recreates)
    }

    @Test("A changed colour attachment replaces the cached descriptor instead of reusing it")
    func attachmentChangeRebuildsDescriptor() throws {
        var created: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(
            nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &created)
        let buffer = try #require(created)
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)

        var cached: CMVideoFormatDescription?
        #expect(PlayerEngine.makeDisplaySampleBuffer(for: buffer, formatDescription: &cached).rebuilt)
        let first = try #require(cached)
        #expect(PlayerEngine.makeDisplaySampleBuffer(for: buffer, formatDescription: &cached).rebuilt == false)

        // Mid-stream colour change: the stale descriptor must not be reused for the new frames.
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        let (sample, rebuilt) = PlayerEngine.makeDisplaySampleBuffer(for: buffer, formatDescription: &cached)
        #expect(rebuilt)
        #expect(sample != nil)
        let primaries = cached.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
        }
        #expect(primaries as? String == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        #expect(cached != first)
    }

    @Test("HDR HEVC: cache hits on every frame after the first")
    func hdrCacheHits() throws {
        let (buffers, diagnostics) = decodePixelBuffers(preset: .hevc10BitHDR, maxFrames: 30)
        try #require(buffers.count >= 5, "Need several decoded frames to measure cache behavior (\(diagnostics))")

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
        let (buffers, diagnostics) = decodePixelBuffers(preset: .multiTrackH264, maxFrames: 30)
        try #require(buffers.count >= 5, "Need several decoded frames to measure cache behavior (\(diagnostics))")

        let (hits, recreates) = measureCacheHits(buffers)
        print("[FmtCache][SDR] frames=\(buffers.count) hits=\(hits) recreates=\(recreates)")

        #expect(
            recreates == 1,
            "Expected a single descriptor creation; got \(recreates) recreates over \(buffers.count) frames")
        #expect(hits == buffers.count - 1)
    }
}
