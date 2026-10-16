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

    /// Luma of the frames decoded from the first `frameCount` packets, keyed by PTS.
    private static func decodeLuma(
        _ preset: SyntheticTestMediaFactory.Preset, deinterlace: Bool, fieldRate: Bool = false,
        frameCount: Int = 12
    ) throws -> [Double: LumaPlane]? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return nil }
        let demuxer = try #require(MediaDemuxer(url: path))
        let params = try #require(demuxer.getVideoCodecParameters())
        let decoder = try #require(
            FFmpegVideoDecoder(
                codecParameters: params, timebase: demuxer.timebase, formatDescription: demuxer.formatDescription,
                deinterlace: deinterlace, fieldRate: fieldRate))

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

    @Test(
        "Field rate: a progressive frame per field, a field apart, each keeping its own field",
        arguments: [SyntheticTestMediaFactory.Preset.mpeg2InterlacedTS, .h264InterlacedTS])
    func emitsFramePerField(_ preset: SyntheticTestMediaFactory.Preset) throws {
        guard let woven = try Self.decodeLuma(preset, deinterlace: false),
            let fields = try Self.decodeLuma(preset, deinterlace: true, fieldRate: true)
        else { return }
        #expect(!woven.isEmpty)
        #expect(fields.count == woven.count * 2, "\(fields.count) field frames from \(woven.count) frames")

        func rows(_ plane: LumaPlane, parity: Int) -> [ArraySlice<UInt8>] {
            stride(from: parity, to: plane.height, by: 2).map {
                plane.bytes[($0 * plane.width)..<(($0 + 1) * plane.width)]
            }
        }
        // 25i: fields 20 ms apart. Top field first, so the first frame keeps the even rows, the second the odd ones.
        for (pts, source) in woven {
            let first = try #require(fields[pts], "No first-field frame at \(pts)s")
            let secondKey = try #require(
                fields.keys.first { abs($0 - (pts + 0.020)) < 0.0005 }, "No second-field frame after \(pts)s")
            let second = try #require(fields[secondKey])
            #expect(rows(first, parity: 0) == rows(source, parity: 0), "First field changed at \(pts)s")
            #expect(rows(second, parity: 1) == rows(source, parity: 1), "Second field changed at \(pts)s")
            // The fields show different moments, so the two frames differ where the picture moves.
            #expect(first.bytes != second.bytes, "Second-field frame at \(secondKey)s repeats the first")
        }

        let wovenComb = woven.values.map(\.combEnergy).reduce(0, +) / Double(woven.count)
        let fieldComb = fields.values.map(\.combEnergy).reduce(0, +) / Double(fields.count)
        #expect(wovenComb > 20, "Source isn't combed enough to test: \(wovenComb)")
        #expect(fieldComb < wovenComb * 0.25, "Combing \(wovenComb) only reduced to \(fieldComb)")
    }

    @Test("Field-rate decoders come from the factory for interlaced streams only")
    func factoryEnablesFieldRateForInterlacedStreams() throws {
        for (preset, interlaced) in [
            (SyntheticTestMediaFactory.Preset.h264InterlacedTS, true), (.mpeg2InterlacedTS, true), (.dvNTSC, true),
            (.mpeg1MPG, false),
        ] {
            guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
            let demuxer = try #require(MediaDemuxer(url: path))
            #expect(demuxer.isInterlaced == interlaced, "\(preset)")
            let decoder = try #require(VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer))
            #expect(decoder.outputsFieldRate == interlaced, "\(preset)")
        }
    }

    @Test("DV without a usable average frame rate falls back to its base rate")
    func dvNominalFrameRate() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .dvNTSC) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        #expect(abs(demuxer.nominalFrameDuration - 1001.0 / 30000.0) < 0.0001, "\(demuxer.nominalFrameDuration)")
    }

    @Test("The engine paces interlaced video at the field rate")
    @MainActor
    func enginePacesAtFieldRate() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .h264InterlacedTS) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: path)
        #expect(engine.isLoaded)
        #expect(abs(engine.nominalFrameDuration - 0.020) < 0.0001, "\(engine.nominalFrameDuration)")
    }

    @Test("Exact seeks land on the field at the target and frame steps move a field at a time")
    @MainActor
    func seeksAndStepsByField() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .h264InterlacedTS) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: path)
        #expect(engine.isLoaded)
        #expect(await engine.waitUntil { engine.isPlaying })
        engine.pause()

        // 25i: fields every 20 ms (the rebased timeline needn't start on a whole field). An exact seek lands on the
        // field shown at the target; 5 ms past the next two fields lands on them, one of which is a second field.
        engine.seek(to: 1.0, exact: true)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { !engine.isSeeking && engine.pendingSeekTime == nil })
        let landing = engine.currentFramePTS
        #expect(landing > 0.98 && landing <= 1.0, "Exact seek to 1.0s landed at \(landing)s")
        for field in [0.020, 0.040] {
            engine.seek(to: landing + field + 0.005, exact: true)
            #expect(
                await engine.waitUntil(timeout: .seconds(5)) { !engine.isSeeking && engine.pendingSeekTime == nil })
            #expect(
                abs(engine.currentFramePTS - (landing + field)) < 0.002,
                "Exact seek to \(landing + field + 0.005)s landed at \(engine.currentFramePTS)s")
        }

        for _ in 0..<3 {
            let before = engine.currentFramePTS
            engine.stepFrameForward()
            #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.currentFramePTS > before + 0.001 })
            let step = engine.currentFramePTS - before
            #expect(abs(step - 0.020) < 0.005, "Stepped \(step)s from \(before)s")
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

@Suite("Field timing")
struct FieldTimingTests {
    private func durations(_ seconds: Double, repeated: Int = 0) -> (first: Double, second: Double)? {
        FieldTiming.durations(ofFrame: CMTime(seconds: seconds, preferredTimescale: 90000), repeatedFields: repeated)
            .map { ($0.first.seconds, $0.second.seconds) }
    }

    @Test("A frame splits into its fields")
    func splitsFrames() throws {
        let pal = try #require(durations(0.040))
        #expect(abs(pal.first - 0.020) < 1e-6 && abs(pal.second - 0.020) < 1e-6)
        let ntsc = try #require(durations(1001.0 / 30000.0))
        #expect(abs(ntsc.first - 1001.0 / 60000.0) < 1e-4 && abs(ntsc.second - 1001.0 / 60000.0) < 1e-4)
    }

    @Test("A repeated field (soft telecine) extends the second frame")
    func repeatedField() throws {
        let telecined = try #require(durations(1.5 * 1001.0 / 30000.0, repeated: 1))
        #expect(abs(telecined.first - 1001.0 / 60000.0) < 1e-4)
        #expect(abs(telecined.second - 2 * 1001.0 / 60000.0) < 1e-4)
    }

    @Test("Field-timestamped streams already report a field's duration")
    func fieldDurations() throws {
        let paff = try #require(durations(0.020))
        #expect(abs(paff.first - 0.020) < 1e-6 && abs(paff.second - 0.020) < 1e-6)
        #expect(FieldTiming.fieldDuration(ofFrameDuration: 0.040) == 0.020)
        #expect(FieldTiming.fieldDuration(ofFrameDuration: 0.020) == 0.020)
    }

    @Test("No duration, no field timing")
    func invalidDuration() {
        #expect(FieldTiming.durations(ofFrame: .invalid, repeatedFields: 0) == nil)
        #expect(FieldTiming.durations(ofFrame: .zero, repeatedFields: 0) == nil)
    }
}
