import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import NitsCore

@Suite("Apple ProRes (VideoToolbox)", .hostDependent)
struct ProResPlaybackTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let preset: SyntheticTestMediaFactory.Preset
        let fourCC: UInt32
        let profileName: String

        var testDescription: String { preset.rawValue }
    }

    static let cases: [Case] = [
        Case(preset: .proresMOV, fourCC: kCMVideoCodecType_AppleProRes422, profileName: "ProRes 422"),
        Case(preset: .prores4444MOV, fourCC: kCMVideoCodecType_AppleProRes4444, profileName: "ProRes 4444"),
    ]

    @Test("The demuxer names the ProRes profile and the factory picks VideoToolbox", arguments: cases)
    func demuxerAndFactory(_ testCase: Case) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: testCase.preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))

        #expect(demuxer.codec == .proRes(fourCC: testCase.fourCC))
        #expect(demuxer.codec.displayName == testCase.profileName)
        #expect(demuxer.codec.cmVideoCodecType == testCase.fourCC)
        let description = try #require(demuxer.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(description) == testCase.fourCC)

        #expect(VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer) is VTVideoDecoder)
        #expect(
            VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer, preferSoftware: true)
                is FFmpegVideoDecoder)
    }

    @Test("Every frame comes out in order as 10-bit 4:2:0", arguments: cases, [false, true])
    func decodesEveryFrame(_ testCase: Case, preferSoftware: Bool) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: testCase.preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let decoder = try #require(
            VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer, preferSoftware: preferSoftware))
        #expect((decoder is FFmpegVideoDecoder) == preferSoftware)

        let ptsList = LockIsolated<[Double]>([])
        let pixelFormat = LockIsolated<OSType>(0)
        decoder.setOutputHandler { frame in
            ptsList.withValue { $0.append(CMTimeGetSeconds(frame.pts)) }
            pixelFormat.withValue { $0 = CVPixelBufferGetPixelFormatType(frame.pixelBuffer) }
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
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $0 < $1 })
        #expect(pixelFormat.value == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    }

    @Test("PlayerEngine loads, plays, seeks and steps", .realtimePlayback, arguments: cases)
    @MainActor
    func playerEnginePlays(_ testCase: Case) async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: testCase.preset) else { return }

        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)

        #expect(engine.isLoaded)
        #expect(engine.media.video.codecName == testCase.profileName)

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
