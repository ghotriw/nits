import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("Legacy & Software-Decoded Video (FFmpegVideoDecoder)")
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
        Case(preset: .flvSpark, codec: .flv1, width: 320, height: 240),
        Case(preset: .vp8WebM, codec: .vp8, width: 640, height: 360),
        Case(
            preset: .rv10RM, codec: .rv10, width: 320, height: 240,
            primaries: kCVImageBufferColorPrimaries_SMPTE_C as String),
        Case(
            preset: .rv20RM, codec: .rv20, width: 352, height: 288,
            primaries: kCVImageBufferColorPrimaries_EBU_3213 as String),
        // libswscale fallback: 4:2:2 full range, 4:1:1 anamorphic, RGB, and 10-bit 4:2:2
        Case(preset: .mjpegAVI, codec: .software(ffmpegCodecID: AV_CODEC_ID_MJPEG.rawValue), width: 640, height: 360),
        Case(
            preset: .dvNTSC, codec: .software(ffmpegCodecID: AV_CODEC_ID_DVVIDEO.rawValue), width: 720, height: 480,
            sampleAspectRatio: RationalAspectRatio(numerator: 8, denominator: 9)),
        Case(
            preset: .cinepakMOV, codec: .software(ffmpegCodecID: AV_CODEC_ID_CINEPAK.rawValue), width: 320, height: 240),
        Case(preset: .proresMOV, codec: .software(ffmpegCodecID: AV_CODEC_ID_PRORES.rawValue), width: 640, height: 360),
        // Field-coded H.264: hardware can't decode it, so it plays in software.
        Case(
            preset: .h264InterlacedTS, codec: .h264, width: 720, height: 576,
            sampleAspectRatio: RationalAspectRatio(numerator: 16, denominator: 15),
            primaries: kCVImageBufferColorPrimaries_EBU_3213 as String),
    ]

    /// Presets with B-frames, where decode and presentation order differ.
    static let reorderedPresets: [SyntheticTestMediaFactory.Preset] = [
        .mpeg4XvidAVI, .mpeg2DVDVOB, .mpeg2InterlacedTS, .mpeg1MPG, .vp8WebM, .h264InterlacedTS,
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
        let decoder = try #require(
            FFmpegVideoDecoder(
                codecParameters: params, timebase: demuxer.timebase, formatDescription: demuxer.formatDescription))

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
        // Interlaced presets come out a frame per field.
        let frameDuration =
            decoder.outputsFieldRate
            ? FieldTiming.fieldDuration(ofFrameDuration: demuxer.nominalFrameDuration) : demuxer.nominalFrameDuration
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

    @Test("PlayerEngine loads, plays, seeks and steps", .realtimePlayback, arguments: cases)
    @MainActor
    func playerEnginePlays(_ testCase: Case) async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: testCase.preset) else { return }

        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)

        #expect(engine.isLoaded)
        #expect(engine.duration > 0)
        #expect(engine.videoCodecName == testCase.codec.displayName)

        engine.play()
        #expect(await engine.waitUntil { engine.currentTime > 0 }, "Playback did not progress")

        engine.seek(to: 1.5)
        #expect(await engine.waitForSeekToSettle())

        engine.pause()
        #expect(await engine.waitUntil { engine.currentFramePTS >= 0 }, "No frame presented after the seek")
        let ptsBeforeStep = engine.currentFramePTS
        #expect(await engine.stepFrameForwardAndWait(), "Frame step did not advance from \(ptsBeforeStep)s")

        engine.stop()
    }
}
