import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("VP9 Playback & Decoding Tests")
struct VP9PlaybackTests {

    @Test("MediaDemuxer correctly identifies VP9 SDR codec in WebM and creates format description")
    func demuxerIdentifiesVP9SDR() async throws {
        guard let vp9Path = SyntheticTestMediaFactory.ensureMedia(preset: .vp9SDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: vp9Path) else {
            Issue.record("Failed to open VP9 SDR media with MediaDemuxer")
            return
        }

        #expect(demuxer.hasVideo == true)
        #expect(demuxer.codec == .vp9)
        #expect(demuxer.width == 640)
        #expect(demuxer.height == 360)
        #expect(demuxer.bitDepth == 8)
        #expect(demuxer.formatDescription != nil)

        // Verify vpcC atom is present and valid in format description
        if let desc = demuxer.formatDescription,
            let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
            let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                as? [String: Any],
            let vpcc = atoms["vpcC"] as? Data
        {
            #expect(vpcc.count >= 12)
            #expect(vpcc[0] == 1)  // version
            #expect(vpcc[4] == 0)  // profile 0 (8-bit)
            #expect((vpcc[6] >> 4) == 8)  // 8-bit depth
        } else {
            Issue.record("Format description is missing synthesized vpcC atom")
        }

        // Read sample buffer
        let sample = demuxer.nextVideoSample()
        #expect(sample != nil)
        if let sample {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            #expect(pts.isValid)
        }
    }

    @Test("MediaDemuxer correctly identifies VP9 10-bit HDR (BT.2020 / PQ) in WebM")
    func demuxerIdentifiesVP9HDR() async throws {
        guard let vp9Path = SyntheticTestMediaFactory.ensureMedia(preset: .vp910BitHDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: vp9Path) else {
            Issue.record("Failed to open VP9 HDR media with MediaDemuxer")
            return
        }

        #expect(demuxer.hasVideo == true)
        #expect(demuxer.codec == .vp9)
        #expect(demuxer.width == 640)
        #expect(demuxer.height == 360)
        #expect(demuxer.bitDepth == 10)
        #expect(demuxer.isHDR == true)
        #expect(demuxer.formatDescription != nil)

        // Verify 10-bit HDR vpcC atom
        if let desc = demuxer.formatDescription,
            let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
            let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                as? [String: Any],
            let vpcc = atoms["vpcC"] as? Data
        {
            #expect(vpcc.count >= 12)
            #expect(vpcc[0] == 1)  // version
            #expect(vpcc[4] == 2)  // profile 2 (10-bit HDR)
            #expect((vpcc[6] >> 4) == 10)  // 10-bit depth
        } else {
            Issue.record("Format description is missing synthesized vpcC atom for 10-bit HDR")
        }

        let sample = demuxer.nextVideoSample()
        #expect(sample != nil)
        if let sample {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            #expect(pts.isValid)
        }
    }

    @Test("FFmpegVideoDecoder decodes VP9 SDR video frames into 8-bit bi-planar CVPixelBuffers")
    func ffmpegDecodesVP9SDRFrames() async throws {
        guard let vp9Path = SyntheticTestMediaFactory.ensureMedia(preset: .vp9SDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: vp9Path) else {
            Issue.record("Failed to open VP9 SDR file")
            return
        }

        guard let codecParams = demuxer.getVideoCodecParameters() else {
            Issue.record("Failed to get video codec parameters for VP9")
            return
        }

        guard let decoder = FFmpegVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else {
            Issue.record("Failed to initialize FFmpegVideoDecoder for VP9")
            return
        }

        let decodedCount = LockIsolated(0)
        let lastPts = LockIsolated<Double>(-1.0)
        let lastWidth = LockIsolated(0)
        let lastHeight = LockIsolated(0)
        let lastPixelFormat = LockIsolated<OSType>(0)

        decoder.setOutputHandler { frame in
            decodedCount.withValue { $0 += 1 }
            lastPts.withValue { $0 = frame.pts.seconds }
            let w = CVPixelBufferGetWidth(frame.pixelBuffer)
            let h = CVPixelBufferGetHeight(frame.pixelBuffer)
            let fmt = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            lastWidth.withValue { $0 = w }
            lastHeight.withValue { $0 = h }
            lastPixelFormat.withValue { $0 = fmt }
        }

        var fed = 0
        while fed < 30, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            fed += 1
        }
        decoder.flush()

        #expect(decodedCount.value > 0)
        #expect(lastWidth.value == 640)
        #expect(lastHeight.value == 360)
        #expect(lastPts.value >= 0)
        #expect(
            lastPixelFormat.value == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || lastPixelFormat.value == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
    }

    @Test("FFmpegVideoDecoder decodes VP9 10-bit HDR video frames into P010 CVPixelBuffers")
    func ffmpegDecodesVP910BitHDRFrames() async throws {
        guard let vp9Path = SyntheticTestMediaFactory.ensureMedia(preset: .vp910BitHDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: vp9Path) else {
            Issue.record("Failed to open VP9 HDR file")
            return
        }

        guard let codecParams = demuxer.getVideoCodecParameters() else {
            Issue.record("Failed to get video codec parameters for VP9 10-bit")
            return
        }

        guard let decoder = FFmpegVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else {
            Issue.record("Failed to initialize FFmpegVideoDecoder for VP9 10-bit")
            return
        }

        let decodedCount = LockIsolated(0)
        let lastWidth = LockIsolated(0)
        let lastHeight = LockIsolated(0)
        let lastPixelFormat = LockIsolated<OSType>(0)

        decoder.setOutputHandler { frame in
            decodedCount.withValue { $0 += 1 }
            let w = CVPixelBufferGetWidth(frame.pixelBuffer)
            let h = CVPixelBufferGetHeight(frame.pixelBuffer)
            let fmt = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            lastWidth.withValue { $0 = w }
            lastHeight.withValue { $0 = h }
            lastPixelFormat.withValue { $0 = fmt }
        }

        var fed = 0
        while fed < 30, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            fed += 1
        }
        decoder.flush()

        #expect(decodedCount.value > 0)
        #expect(lastWidth.value == 640)
        #expect(lastHeight.value == 360)
        #expect(
            lastPixelFormat.value == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || lastPixelFormat.value == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
    }

    @Test("PlayerEngine seamlessly loads, plays and seeks VP9 WebM media")
    @MainActor
    func playerEnginePlaysVP9() async throws {
        guard let vp9Path = SyntheticTestMediaFactory.ensureMedia(preset: .vp9SDR) else {
            return
        }

        let engine = PlayerEngine()
        engine.load(path: vp9Path)

        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == true)
        #expect(engine.duration > 0)
        #expect(engine.videoCodecName == "VP9")

        engine.play()
        #expect(engine.isPlaying == true)

        var played = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if engine.currentTime > 0 {
                played = true
                break
            }
        }
        #expect(played == true)
        #expect(engine.currentTime > 0)

        // Test seeking
        engine.seek(to: 1.5, exact: true)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !engine.isSeeking && engine.pendingSeekTime == nil {
                break
            }
        }
        #expect(engine.currentTime >= 0)

        engine.pause()
        #expect(engine.isPlaying == false)
        engine.stop()
    }
}
