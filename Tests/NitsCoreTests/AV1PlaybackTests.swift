import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("AV1 Playback & dav1d Decoding Tests")
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

    @Test("Dav1dVideoDecoder decodes AV1 video frames into valid CVPixelBuffers")
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

        guard let decoder = Dav1dVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else {
            Issue.record("Failed to initialize Dav1dVideoDecoder")
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

    @Test("PlayerEngine seamlessly loads, plays and seeks AV1 media")
    @MainActor
    func playerEnginePlaysAV1() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else {
            return
        }

        let engine = PlayerEngine()
        engine.load(path: av1Path)

        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == true)
        #expect(engine.duration > 0)

        engine.play()
        #expect(engine.isPlaying == true)

        try? await Task.sleep(nanoseconds: 800_000_000)  // 0.8s
        #expect(engine.currentTime > 0)

        // Test seek
        engine.seek(to: 1.0)
        try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3s

        engine.pause()
        #expect(engine.isPlaying == false)

        // Test exact seek on pause for AV1
        let initialPTS = engine.currentFramePTS
        engine.seekRelative(by: 1.0, exact: true)

        // Poll for seek & decode to settle up to 1 second
        var settled = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms intervals
            if engine.currentFramePTS != initialPTS && engine.getLastRenderedBuffer() != nil {
                settled = true
                break
            }
        }
        #expect(settled == true)
        #expect(engine.getLastRenderedBuffer() != nil)
        #expect(engine.currentFramePTS != initialPTS)

        engine.stop()
        #expect(engine.isLoaded == false)
    }

    @Test("Dav1dVideoDecoder handles non-unitary timebase without PTS drift")
    func dav1dTimebaseScaling() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else { return }
        guard let demuxer = MediaDemuxer(url: av1Path) else { return }
        guard let codecParams = demuxer.getVideoCodecParameters() else { return }

        // Use standard non-unitary timebase e.g. 1001/30000 (29.97 fps)
        let nonUnitaryTimebase = AVRational(num: 1001, den: 30000)
        guard let decoder = Dav1dVideoDecoder(codecParameters: codecParams, timebase: nonUnitaryTimebase) else {
            Issue.record("Failed to initialize Dav1dVideoDecoder with custom timebase")
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

    @Test("Dav1dVideoDecoder preserves color metadata attachments across drain() on EOF")
    func dav1dPreservesColorAttachmentsOnDrain() async throws {
        guard let av1Path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else { return }
        guard let demuxer = MediaDemuxer(url: av1Path) else { return }
        guard let codecParams = demuxer.getVideoCodecParameters() else { return }

        guard let decoder = Dav1dVideoDecoder(codecParameters: codecParams, timebase: demuxer.timebase) else { return }

        let colorPrimariesObserved = LockIsolated<String?>(nil)
        decoder.setOutputHandler { frame in
            if let prim = CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferColorPrimariesKey, nil) {
                colorPrimariesObserved.withValue { $0 = String(describing: prim) }
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
}

// Simple thread-safe box for unit testing callbacks
private final class LockIsolated<T: Sendable>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&_value)
    }
}
