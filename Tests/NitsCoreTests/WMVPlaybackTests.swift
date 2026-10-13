import CFFmpeg
import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

@Suite("WMV Playback & FFmpeg Software Decoding Tests")
struct WMVPlaybackTests {

    @Test("MediaDemuxer correctly identifies WMV2 codec and produces valid format description")
    func demuxerIdentifiesWMV2() async throws {
        guard let wmvPath = SyntheticTestMediaFactory.ensureMedia(preset: .wmv2SDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: wmvPath) else {
            Issue.record("Failed to open WMV synthetic media with MediaDemuxer")
            return
        }

        #expect(demuxer.hasVideo == true)
        #expect(demuxer.codec == .wmv2)
        #expect(demuxer.width == 640)
        #expect(demuxer.height == 360)
        #expect(demuxer.formatDescription != nil)

        // Read sample buffer
        let sample = demuxer.nextVideoSample()
        #expect(sample != nil)
        if let sample {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            #expect(pts.isValid)
        }
    }

    @Test("FFmpegVideoDecoder decodes WMV2 video frames into valid CVPixelBuffers")
    func ffmpegDecodesWMV2Frames() async throws {
        guard let wmvPath = SyntheticTestMediaFactory.ensureMedia(preset: .wmv2SDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: wmvPath) else {
            Issue.record("Failed to open WMV file")
            return
        }

        guard let codecParams = demuxer.getVideoCodecParameters() else {
            Issue.record("Failed to get video codec parameters for WMV2")
            return
        }

        guard let decoder = FFmpegVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else {
            Issue.record("Failed to initialize FFmpegVideoDecoder for WMV2")
            return
        }

        let decodedCount = LockIsolated(0)
        let lastPts = LockIsolated<Double>(-1.0)
        let lastWidth = LockIsolated(0)
        let lastHeight = LockIsolated(0)

        decoder.setOutputHandler { frame in
            decodedCount.withValue { $0 += 1 }
            lastPts.withValue { $0 = CMTimeGetSeconds(frame.pts) }
            lastWidth.withValue { $0 = CVPixelBufferGetWidth(frame.pixelBuffer) }
            lastHeight.withValue { $0 = CVPixelBufferGetHeight(frame.pixelBuffer) }
        }

        var fedPackets = 0
        while let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            fedPackets += 1
        }
        decoder.drain()

        #expect(fedPackets > 0)
        #expect(decodedCount.value > 0)
        #expect(decodedCount.value >= fedPackets - 2)
        #expect(lastWidth.value == 640)
        #expect(lastHeight.value == 360)
        #expect(lastPts.value > 0.0)
    }

    @Test("VideoDecoderFactory creates FFmpegVideoDecoder for WMV2")
    func factoryCreatesSoftwareDecoderForWMV2() async throws {
        guard let wmvPath = SyntheticTestMediaFactory.ensureMedia(preset: .wmv2SDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: wmvPath) else {
            Issue.record("Failed to open WMV file")
            return
        }

        let decoder = VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer)
        #expect(decoder != nil)
        #expect(decoder is FFmpegVideoDecoder)
    }

    @Test("PlayerEngine seamlessly loads, plays and seeks WMV2 media")
    @MainActor
    func playerEnginePlaysWMV2() async throws {
        guard let wmvPath = SyntheticTestMediaFactory.ensureMedia(preset: .wmv2SDR) else {
            return
        }

        let engine = PlayerEngine()
        engine.load(path: wmvPath)

        #expect(engine.isLoaded == true)
        #expect(engine.duration > 0)
        #expect(engine.videoCodecName == "WMV2")

        // Start playback
        engine.play()
        #expect(engine.isPlaying == true)

        // Wait for playback progress
        var progressed = false
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if engine.currentTime > 0 {
                progressed = true
                break
            }
        }
        #expect(progressed == true)

        // Test seeking in WMV file
        engine.seek(to: 1.0)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Test step-frame forward progression while paused
        engine.pause()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let ptsBeforeStep = engine.currentFramePTS >= 0 ? engine.currentFramePTS : engine.currentTime
        engine.stepFrameForward()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let ptsAfterStep1 = engine.currentFramePTS >= 0 ? engine.currentFramePTS : engine.currentTime
        #expect(ptsAfterStep1 > ptsBeforeStep)

        engine.stepFrameForward()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let ptsAfterStep2 = engine.currentFramePTS >= 0 ? engine.currentFramePTS : engine.currentTime
        #expect(ptsAfterStep2 > ptsAfterStep1)

        engine.stop()
    }
}
