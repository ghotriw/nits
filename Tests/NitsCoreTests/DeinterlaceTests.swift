import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import NitsCore

@Suite("Deinterlacing (MetalDeinterlacer via FFmpegVideoDecoder)")
struct DeinterlaceTests {

    /// 8-bit luma of one decoded frame, tightly packed.
    struct LumaPlane: Sendable {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        subscript(x: Int, y: Int) -> Int { Int(bytes[y * width + x]) }

        /// Mean over the image of how far each sample sticks out past both vertical neighbours, the
        /// signature of combing: max(0, (c - up) * (c - down)), in squared 8-bit levels.
        var combEnergy: Double {
            var total = 0
            for y in 1..<(height - 1) {
                for x in 0..<width {
                    total += max(0, (self[x, y] - self[x, y - 1]) * (self[x, y] - self[x, y + 1]))
                }
            }
            return Double(total) / Double(width * (height - 2))
        }
    }

    /// Luma of the first `frameCount` frames, keyed by PTS.
    private static func decodeLuma(
        _ preset: SyntheticTestMediaFactory.Preset, deinterlace: Bool, frameCount: Int = 12
    ) throws -> [Double: LumaPlane]? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return nil }
        let demuxer = try #require(MediaDemuxer(url: path))
        let params = try #require(demuxer.getVideoCodecParameters())
        let decoder = try #require(
            FFmpegVideoDecoder(
                codecParameters: params, timebase: demuxer.timebase, formatDescription: demuxer.formatDescription,
                deinterlace: deinterlace))

        let planes = LockIsolated<[Double: LumaPlane]>([:])
        decoder.setOutputHandler { frame in
            let buffer = frame.pixelBuffer
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            var bytes = [UInt8](repeating: 0, count: width * height)
            for row in 0..<height {
                bytes.withUnsafeMutableBytes { dst in
                    dst.baseAddress!.advanced(by: row * width).copyMemory(
                        from: base.advanced(by: row * stride), byteCount: width)
                }
            }
            let plane = LumaPlane(width: width, height: height, bytes: bytes)
            planes.withValue { $0[frame.pts.seconds] = plane }
        }
        for _ in 0..<frameCount {
            guard let sample = demuxer.nextVideoSample() else { break }
            decoder.decode(sampleBuffer: sample)
        }
        decoder.drain()
        return planes.value
    }

    @Test(
        "Combing from motion between the fields is removed and the first field is kept exactly",
        arguments: [SyntheticTestMediaFactory.Preset.mpeg2InterlacedTS, .h264InterlacedTS])
    func removesCombingAndKeepsFirstField(_ preset: SyntheticTestMediaFactory.Preset) throws {
        guard let woven = try Self.decodeLuma(preset, deinterlace: false),
            let progressive = try Self.decodeLuma(preset, deinterlace: true)
        else { return }
        #expect(!woven.isEmpty)
        #expect(Set(woven.keys) == Set(progressive.keys))

        let wovenComb = woven.values.map(\.combEnergy).reduce(0, +) / Double(woven.count)
        let progressiveComb = progressive.values.map(\.combEnergy).reduce(0, +) / Double(progressive.count)
        // The source must comb visibly, or the comparison proves nothing.
        #expect(wovenComb > 20, "Source isn't combed enough to test: \(wovenComb)")
        #expect(progressiveComb < wovenComb * 0.25, "Combing \(wovenComb) only reduced to \(progressiveComb)")

        // Top field first: even rows are the kept field and pass through untouched.
        for (pts, plane) in progressive {
            let source = try #require(woven[pts])
            let keptRowsMatch = stride(from: 0, to: plane.height, by: 2).allSatisfy { row in
                plane.bytes[(row * plane.width)..<((row + 1) * plane.width)]
                    == source.bytes[(row * source.width)..<((row + 1) * source.width)]
            }
            #expect(keptRowsMatch, "Kept field changed in frame at \(pts)s")
        }
    }

    /// DV marks every frame interlaced; this one comes from progressive video, so its fields don't differ in time.
    @Test("Interlaced-flagged frames without motion between the fields stay as they are")
    func leavesStaticFieldsWoven() throws {
        guard let woven = try Self.decodeLuma(.dvNTSC, deinterlace: false),
            let progressive = try Self.decodeLuma(.dvNTSC, deinterlace: true)
        else { return }
        #expect(!woven.isEmpty)
        for (pts, plane) in progressive {
            let source = try #require(woven[pts])
            let meanDifference =
                Double(zip(plane.bytes, source.bytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) })
                / Double(plane.bytes.count)
            #expect(meanDifference < 1.0, "Static frame at \(pts)s altered by \(meanDifference) levels on average")
        }
    }
}

@Suite("MPEG-TS / MPEG-PS start")
struct UnindexedStreamStartTests {
    /// After probing parameter sets the demuxer rewinds; a timestamp seek in TS / PS used to land past the
    /// first packet and drop the opening keyframe, so H.264 lost its whole first GOP.
    @Test(
        "Decoding starts at the first frame",
        arguments: [SyntheticTestMediaFactory.Preset.h264InterlacedTS, .mpeg2InterlacedTS, .mpeg2DVDVOB])
    func decodesFromFirstFrame(_ preset: SyntheticTestMediaFactory.Preset) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let decoder = try #require(VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer))
        let firstPts = LockIsolated<Double?>(nil)
        decoder.setOutputHandler { frame in
            firstPts.withValue { $0 = min($0 ?? .infinity, frame.pts.seconds) }
        }
        for _ in 0..<20 {
            guard let sample = demuxer.nextVideoSample() else { break }
            decoder.decode(sampleBuffer: sample)
        }
        decoder.waitForPendingFrames()
        decoder.drain()
        let first = try #require(firstPts.value)
        #expect(first < demuxer.nominalFrameDuration * 1.5, "First decoded frame at \(first)s")
    }
}
