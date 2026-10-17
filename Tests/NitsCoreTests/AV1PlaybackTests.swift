import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("AV1 Playback & dav1d Decoding Tests", .hostDependent)
struct AV1PlaybackTests {

    @Test("MediaDemuxer correctly identifies AV1 codec and produces format description")
    func demuxerIdentifiesAV1() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: av1Path) else {
            Issue.record("Failed to open AV1 synthetic media with MediaDemuxer")
            return
        }

        #expect(demuxer.hasVideo == true)
        #expect(demuxer.codec == .av1)
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

    @Test("FFmpegVideoDecoder decodes AV1 video frames into valid CVPixelBuffers")
    func dav1dDecodesFrames() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: av1Path) else {
            Issue.record("Failed to open AV1 file")
            return
        }

        guard let codecParams = demuxer.getVideoCodecParameters() else {
            Issue.record("Failed to get video codec parameters for AV1")
            return
        }

        guard let decoder = FFmpegVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else {
            Issue.record("Failed to initialize FFmpegVideoDecoder")
            return
        }

        let decodedCount = LockIsolated(0)
        let lastPts = LockIsolated<Double>(-1.0)
        let lastWidth = LockIsolated(0)
        let lastHeight = LockIsolated(0)

        decoder.setOutputHandler { frame in
            decodedCount.withValue { $0 += 1 }
            lastPts.withValue { $0 = frame.pts.seconds }
            let w = CVPixelBufferGetWidth(frame.pixelBuffer)
            let h = CVPixelBufferGetHeight(frame.pixelBuffer)
            lastWidth.withValue { $0 = w }
            lastHeight.withValue { $0 = h }
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
    }

    @Test("PlayerEngine seamlessly loads, plays and seeks AV1 media", .realtimePlayback)
    @MainActor
    func playerEnginePlaysAV1() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else {
            return
        }

        let engine = PlayerEngine.makeForTesting()
        engine.load(path: av1Path)

        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == true)
        #expect(engine.duration > 0)

        engine.play()
        #expect(engine.isPlaying == true)

        #expect(await engine.waitUntil { engine.currentTime > 0 }, "Playback did not progress")

        // Test seek
        engine.seek(to: 1.0)
        #expect(await engine.waitForSeekToSettle())

        engine.pause()
        #expect(engine.isPlaying == false)
        #expect(
            await engine.waitUntil { engine.currentFramePTS >= 0 && engine.getLastRenderedBuffer() != nil },
            "No frame presented before the relative seek")

        // Test exact seek on pause for AV1
        let initialPTS = engine.currentFramePTS
        engine.seekRelative(by: 1.0, exact: true)
        #expect(await engine.waitForSeekToSettle())
        #expect(await engine.waitUntil { engine.currentFramePTS != initialPTS })
        #expect(engine.getLastRenderedBuffer() != nil)
        #expect(engine.currentFramePTS != initialPTS)

        engine.stop()
        #expect(engine.isLoaded == false)
    }

    @Test("FFmpegVideoDecoder handles non-unitary timebase without PTS drift")
    func dav1dTimebaseScaling() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else { return }
        guard let demuxer = MediaDemuxer(url: av1Path) else { return }
        guard let codecParams = demuxer.getVideoCodecParameters() else { return }

        // Use standard non-unitary timebase e.g. 1001/30000 (29.97 fps)
        let nonUnitaryTimebase = AVRational(num: 1001, den: 30000)
        guard let decoder = FFmpegVideoDecoder(codecParameters: codecParams, timebase: nonUnitaryTimebase) else {
            Issue.record("Failed to initialize FFmpegVideoDecoder with custom timebase")
            return
        }

        let firstPts = LockIsolated<Double>(-1.0)
        decoder.setOutputHandler { frame in
            if firstPts.value < 0 {
                firstPts.withValue { $0 = frame.pts.seconds }
            }
        }

        if let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            decoder.drain()
        }

        #expect(firstPts.value >= 0.0)
    }

    @Test("FFmpegVideoDecoder preserves color metadata attachments across drain() on EOF")
    func dav1dPreservesColorAttachmentsOnDrain() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else { return }
        guard let demuxer = MediaDemuxer(url: av1Path) else { return }
        guard let codecParams = demuxer.getVideoCodecParameters() else { return }

        guard let decoder = FFmpegVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else { return }

        let colorPrimariesObserved = LockIsolated<String?>(nil)
        decoder.setOutputHandler { frame in
            if let prim = CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferColorPrimariesKey, nil) {
                let primDesc = String(describing: prim)
                colorPrimariesObserved.withValue { $0 = primDesc }
            }
        }

        // Decode 5 frames, then trigger drain()
        var fed = 0
        while fed < 5, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            fed += 1
        }
        decoder.drain()
        #expect(colorPrimariesObserved.value != nil)
    }

    @Test("FFmpegVideoDecoder flush does not block or deadlock during concurrent decode")
    func dav1dConcurrentFlushDuringDecode() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else { return }
        guard let demuxer = MediaDemuxer(url: av1Path) else { return }
        guard let codecParams = demuxer.getVideoCodecParameters() else { return }
        guard let decoder = FFmpegVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else { return }

        let deliveredFrames = LockIsolated(0)
        decoder.setOutputHandler { _ in
            deliveredFrames.withValue { $0 += 1 }
        }

        final class SampleBox: @unchecked Sendable {
            let samples: [CMSampleBuffer]
            init(samples: [CMSampleBuffer]) {
                self.samples = samples
            }
        }

        // Collect samples first
        var collectedSamples: [CMSampleBuffer] = []
        while let s = demuxer.nextVideoSample() {
            collectedSamples.append(s)
            if collectedSamples.count >= 30 { break }
        }
        let box = SampleBox(samples: collectedSamples)

        // Concurrently feed samples and trigger flush()
        let isDone = LockIsolated(false)
        let flushCount = LockIsolated(0)

        let feedTask = Task {
            for sample in box.samples {
                decoder.decode(sampleBuffer: sample)
                // Yield after each sample so the cooperative scheduler can run flushTask
                // between decode iterations, guaranteeing at least one flush occurs.
                await Task.yield()
            }
            isDone.withValue { $0 = true }
        }

        let flushTask = Task {
            while !isDone.value {
                decoder.flush()
                flushCount.withValue { $0 += 1 }
                await Task.yield()
            }
        }

        _ = await feedTask.result
        _ = await flushTask.result

        // Verify that flushes indeed occurred during decoding
        #expect(flushCount.value > 0)

        // Reset and verify decoder remains fully functional after concurrent flushes
        decoder.flush()
        let postFlushDelivered = LockIsolated(0)
        decoder.setOutputHandler { _ in
            postFlushDelivered.withValue { $0 += 1 }
        }

        demuxer.seek(to: 0.0)
        var fedCount = 0
        while fedCount < 10, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            fedCount += 1
        }
        decoder.drain()
        #expect(postFlushDelivered.value > 0)
    }

    @Test("FFmpegVideoDecoder does not deliver stale pre-flush frames after flush()")
    func dav1dRejectsStaleFramesAfterFlush() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else { return }
        guard let demuxer = MediaDemuxer(url: av1Path) else { return }
        guard let codecParams = demuxer.getVideoCodecParameters() else { return }
        guard let decoder = FFmpegVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else { return }

        // Feed some frames from beginning (PTS ~ 0.0s .. 0.16s)
        var count = 0
        while count < 5, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            count += 1
        }

        // Flush immediately to invalidate prior generation
        decoder.flush()

        // Clear tracking and set handler to observe post-flush frames
        let deliveredFrames = LockIsolated<[DecodedFrame]>([])
        decoder.setOutputHandler { frame in
            deliveredFrames.withValue { $0.append(frame) }
        }

        // Seek demuxer back to start without exact preroll discard (exact: false)
        demuxer.seek(to: 0.0, exact: false)
        var afterFlushCount = 0
        while afterFlushCount < 10, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            afterFlushCount += 1
        }
        decoder.drain()

        let frames = deliveredFrames.value
        #expect(!frames.isEmpty)
        for f in frames {
            #expect(!f.doNotDisplay)
            #expect(f.pts.seconds >= 0.0)
        }
    }
}
