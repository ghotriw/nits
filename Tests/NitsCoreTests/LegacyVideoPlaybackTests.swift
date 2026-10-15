import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("Legacy Software-Decoded Video (MPEG-1/2, MPEG-4 Part 2, MS-MPEG4, H.263)")
struct LegacyVideoPlaybackTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let preset: SyntheticTestMediaFactory.Preset
        let codec: VideoCodec
        let width: Int
        let height: Int
        var sampleAspectRatio: RationalAspectRatio = .square
        /// None of the presets signal colorimetry, so every one gets the BT.601 SD defaults.
        var primaries: String = kCVImageBufferColorPrimaries_SMPTE_C as String

        var testDescription: String { preset.rawValue }
    }

    static let cases: [Case] = [
        Case(preset: .mpeg4XvidAVI, codec: .mpeg4, width: 640, height: 360),
        Case(preset: .msmpeg4v3AVI, codec: .msmpeg4v3, width: 640, height: 360),
        Case(
            preset: .h263CIF3GP, codec: .h263, width: 352, height: 288,
            primaries: kCVImageBufferColorPrimaries_EBU_3213 as String),
        // H.263+ bitstream: containers report it as H.263
        Case(preset: .h263pMKV, codec: .h263, width: 640, height: 360),
        Case(
            preset: .mpeg2DVDVOB, codec: .mpeg2, width: 720, height: 480,
            sampleAspectRatio: RationalAspectRatio(numerator: 32, denominator: 27)),
        Case(
            preset: .mpeg2InterlacedTS, codec: .mpeg2, width: 720, height: 576,
            sampleAspectRatio: RationalAspectRatio(numerator: 16, denominator: 15),
            primaries: kCVImageBufferColorPrimaries_EBU_3213 as String),
        Case(preset: .mpeg1MPG, codec: .mpeg1, width: 352, height: 240),
    ]

    /// Presets with B-frames, where decode and presentation order differ.
    static let reorderedPresets: [SyntheticTestMediaFactory.Preset] = [
        .mpeg4XvidAVI, .mpeg2DVDVOB, .mpeg2InterlacedTS, .mpeg1MPG,
    ]

    @Test(
        "MediaDemuxer reads codec, geometry and SD colorimetry; the factory picks the FFmpeg decoder", arguments: cases)
    func demuxerAndFactory(_ testCase: Case) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: testCase.preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))

        #expect(demuxer.hasVideo)
        #expect(demuxer.codec == testCase.codec)
        #expect(demuxer.width == testCase.width)
        #expect(demuxer.height == testCase.height)
        #expect(demuxer.sampleAspectRatio == testCase.sampleAspectRatio)
        #expect(demuxer.formatDescription != nil)
        #expect(demuxer.colorPrimaries as String == testCase.primaries)
        #expect(demuxer.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)

        let decoder = VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer)
        #expect(decoder is FFmpegVideoDecoder)
    }

    @Test("Untagged streams default to BT.601 at SD and BT.709 at HD")
    func standardDefinitionPrimaries() {
        #expect(
            StreamColorimetry.standardDefinitionPrimaries(width: 720, height: 480)
                == kCVImageBufferColorPrimaries_SMPTE_C)
        #expect(
            StreamColorimetry.standardDefinitionPrimaries(width: 720, height: 576)
                == kCVImageBufferColorPrimaries_EBU_3213)
        #expect(
            StreamColorimetry.standardDefinitionPrimaries(width: 352, height: 288)
                == kCVImageBufferColorPrimaries_EBU_3213)
        #expect(StreamColorimetry.standardDefinitionPrimaries(width: 1280, height: 720) == nil)
        #expect(StreamColorimetry.standardDefinitionPrimaries(width: 1920, height: 536) == nil)
        #expect(StreamColorimetry.standardDefinitionPrimaries(width: 960, height: 720) == nil)
    }

    /// AVI stores decode timestamps only; with B-frames the decoder must still emit every frame
    /// once, in presentation order.
    @Test("FFmpegVideoDecoder emits every frame with strictly increasing PTS", arguments: cases)
    func decodesInPresentationOrder(_ testCase: Case) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: testCase.preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let params = try #require(demuxer.getVideoCodecParameters())
        let decoder = try #require(FFmpegVideoDecoder(codecParameters: params, timebase: demuxer.timebase))

        let ptsList = LockIsolated<[Double]>([])
        let size = LockIsolated((0, 0))
        decoder.setOutputHandler { frame in
            ptsList.withValue { $0.append(CMTimeGetSeconds(frame.pts)) }
            size.withValue {
                $0 = (CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer))
            }
        }

        var fedPackets = 0
        while let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            fedPackets += 1
        }
        decoder.drain()

        let pts = ptsList.value
        #expect(fedPackets > 0)
        #expect(pts.count == fedPackets)
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $0 < $1 }, "PTS not strictly increasing: \(pts)")
        #expect(size.value == (testCase.width, testCase.height))
    }

    /// AVI I/P packets have no PTS, so the demuxer flags exact-seek preroll by DTS, which runs ahead of
    /// the reordered PTS. The decoder must settle on the target and keep every frame from it onwards.
    @Test("Exact seek lands on the target without dropping frames after it", arguments: reorderedPresets)
    func exactSeekKeepsFramesAfterTarget(_ preset: SyntheticTestMediaFactory.Preset) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let decoder = try #require(VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer))
        let frameDuration = demuxer.nominalFrameDuration
        let target = 1.5

        demuxer.seek(to: target, exact: true)
        let preview = PlayerEngine.seekPreview(
            demuxer: demuxer, decoder: decoder, frameQueue: FrameQueue(), seconds: target, exact: true,
            isCurrent: { true })
        #expect(abs((preview?.pts ?? -1) - target) <= frameDuration / 2 + 0.001)

        decoder.flush()
        demuxer.seek(to: target, exact: true)
        let displayed = LockIsolated<[Double]>([])
        decoder.setOutputHandler { frame in
            if !frame.doNotDisplay { displayed.withValue { $0.append(frame.pts.seconds) } }
        }
        // Index-less containers (PS/TS) may back off to an earlier keyframe: allow ~2.5 s of preroll.
        for _ in 0..<80 {
            guard let sample = demuxer.nextVideoSample() else { break }
            decoder.decode(sampleBuffer: sample)
        }

        let frames = displayed.value
        let first = try #require(frames.first)
        #expect(first >= target - frameDuration / 2 && first <= target + frameDuration)
        #expect(
            zip(frames, frames.dropFirst()).allSatisfy { abs($1 - $0 - frameDuration) < frameDuration / 2 },
            "Gap after exact seek: \(frames)")
    }

    @Test("PlayerEngine loads, plays, seeks and steps", arguments: cases)
    @MainActor
    func playerEnginePlays(_ testCase: Case) async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: testCase.preset) else { return }

        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)

        #expect(engine.isLoaded)
        #expect(engine.duration > 0)
        #expect(engine.videoCodecName == testCase.codec.displayName)

        engine.play()
        var progressed = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            if engine.currentTime > 0 {
                progressed = true
                break
            }
        }
        #expect(progressed)

        engine.seek(to: 1.5)
        try await Task.sleep(for: .milliseconds(200))

        engine.pause()
        try await Task.sleep(for: .milliseconds(100))
        let ptsBeforeStep = engine.currentFramePTS >= 0 ? engine.currentFramePTS : engine.currentTime
        engine.stepFrameForward()
        try await Task.sleep(for: .milliseconds(300))
        let ptsAfterStep = engine.currentFramePTS >= 0 ? engine.currentFramePTS : engine.currentTime
        #expect(ptsAfterStep > ptsBeforeStep)

        engine.stop()
    }
}
