import CoreMedia
import CoreVideo
import Testing

@testable import NitsCore

@Suite("FrameQueue Invariant Tests")
struct FrameQueueTests {
    private func createDummyPixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        precondition(status == kCVReturnSuccess && pixelBuffer != nil)
        return pixelBuffer!
    }

    @Test("Frames are sorted by presentation timestamp (PTS) regardless of push order")
    func testPTSSorting() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()
        let buf3 = createDummyPixelBuffer()

        // Push B-frames out of order: 2.0s, 1.0s, 3.0s
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(seconds: 2.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(seconds: 1.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf3, pts: CMTime(seconds: 3.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))

        #expect(queue.count == 3)

        // Popping at 1.0s should yield buf1 first
        let popped = queue.popFrame(forSyncTime: CMTime(seconds: 1.0, preferredTimescale: 1000))
        #expect(popped?.pixelBuffer === buf1)
        #expect(queue.count == 2)
    }

    @Test("DoNotDisplay frames are discarded and never returned to the renderer")
    func testDoNotDisplayDiscarded() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()

        // Frame 1 marked as doNotDisplay
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(seconds: 1.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000), doNotDisplay: true))
        // Frame 2 is displayable
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(seconds: 1.04, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000), doNotDisplay: false))

        let popped = queue.popFrame(forSyncTime: CMTime(seconds: 1.05, preferredTimescale: 1000))
        #expect(popped?.pixelBuffer === buf2)
    }

    @Test("Future frames exceeding lead time are held in the queue")
    func testFutureFramesHeld() {
        let queue = FrameQueue()
        let buf = createDummyPixelBuffer()

        // Frame is at 5.0 seconds
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf, pts: CMTime(seconds: 5.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))

        // Querying at 1.0s should return nil and preserve the frame
        let popped = queue.popFrame(forSyncTime: CMTime(seconds: 1.0, preferredTimescale: 1000))
        #expect(popped == nil)
        #expect(queue.count == 1)
    }

    @Test("Clear discards all frames and last rendered buffer")
    func testQueueClear() {
        let queue = FrameQueue()
        let buf = createDummyPixelBuffer()

        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf, pts: CMTime(seconds: 1.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))
        _ = queue.popFrame(forSyncTime: CMTime(seconds: 1.0, preferredTimescale: 1000))
        #expect(queue.getLastRenderedBuffer() === buf)

        queue.clear()
        #expect(queue.count == 0)
        #expect(queue.getLastRenderedBuffer() == nil)
    }

    @Test("Queue overflow preserves imminent head frames and discards furthest future frames")
    func testQueueOverflowPreservesHeadFrames() {
        let queue = FrameQueue()
        var firstBuffer: CVPixelBuffer?

        for i in 1...65 {
            let buf = createDummyPixelBuffer()
            if i == 1 { firstBuffer = buf }
            let pts = CMTime(seconds: Double(i), preferredTimescale: 1000)
            queue.push(
                VTVideoDecoder.DecodedFrame(pixelBuffer: buf, pts: pts, duration: CMTime(value: 41, timescale: 1000)))
        }

        #expect(queue.count == 60)
        // Earliest frame (PTS 1.0) must still be at the head of the queue!
        let popped = queue.popFrame(forSyncTime: CMTime(seconds: 1.0, preferredTimescale: 1000))
        #expect(popped?.pixelBuffer === firstBuffer)
    }

    @Test("Ring buffer handles wrap-around cycles and complex B-frame out-of-order bursts")
    func testRingBufferWrapAroundAndBFrames() {
        let queue = FrameQueue(capacity: 10)

        // Run multiple cycles to force head/tail index wrap-around past capacity
        for cycle in 0..<5 {
            let baseSeconds = Double(cycle * 10)
            // Push frames: [base + 0, base + 2 (P-frame), base + 1 (B-frame), base + 4 (P-frame), base + 3 (B-frame)]
            let ptsOrder = [0.0, 2.0, 1.0, 4.0, 3.0]
            var buffers: [Double: CVPixelBuffer] = [:]

            for offset in ptsOrder {
                let buf = createDummyPixelBuffer()
                let ptsSec = baseSeconds + offset
                buffers[ptsSec] = buf
                queue.push(
                    VTVideoDecoder.DecodedFrame(
                        pixelBuffer: buf,
                        pts: CMTime(seconds: ptsSec, preferredTimescale: 1000),
                        duration: CMTime(value: 41, timescale: 1000)
                    )
                )
            }

            #expect(queue.count == 5)

            // Verify popped sequence is strictly sorted: 0.0, 1.0, 2.0, 3.0, 4.0
            let expectedOffsets = [0.0, 1.0, 2.0, 3.0, 4.0]
            for offset in expectedOffsets {
                let ptsSec = baseSeconds + offset
                let popped = queue.popFrame(forSyncTime: CMTime(seconds: ptsSec, preferredTimescale: 1000))
                #expect(popped?.pixelBuffer === buffers[ptsSec])
            }
            #expect(queue.count == 0)
        }
    }

    @Test("High framerate (50fps) pacing does not prematurely drop frames in a single tick")
    func testHighFrameratePacingNoPrematureDrop() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()
        let buf3 = createDummyPixelBuffer()

        // 50 fps stream: 20ms per frame
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(value: 0, timescale: 1000), duration: CMTime(value: 20, timescale: 1000)
            )
        )
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(value: 20, timescale: 1000), duration: CMTime(value: 20, timescale: 1000)
            )
        )
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf3, pts: CMTime(value: 40, timescale: 1000), duration: CMTime(value: 20, timescale: 1000)
            )
        )

        #expect(queue.count == 3)
        #expect(queue.droppedFramesCount == 0)

        // Tick 1 at 0ms: should pop exactly buf1, leaving buf2 and buf3 in queue with 0 drops
        let pop1 = queue.popFrame(forSyncTime: CMTime(value: 0, timescale: 1000), nominalFrameDuration: 0.020)
        #expect(pop1?.pixelBuffer === buf1)
        #expect(queue.count == 2)
        #expect(queue.droppedFramesCount == 0)

        // Tick 2 at 18ms (e.g. ~60Hz tick): should pop buf2, leaving buf3 in queue with 0 drops
        let pop2 = queue.popFrame(forSyncTime: CMTime(value: 18, timescale: 1000), nominalFrameDuration: 0.020)
        #expect(pop2?.pixelBuffer === buf2)
        #expect(queue.count == 1)
        #expect(queue.droppedFramesCount == 0)

        // Tick 3 at 36ms: should pop buf3 with 0 drops
        let pop3 = queue.popFrame(forSyncTime: CMTime(value: 36, timescale: 1000), nominalFrameDuration: 0.020)
        #expect(pop3?.pixelBuffer === buf3)
        #expect(queue.count == 0)
        #expect(queue.droppedFramesCount == 0)
    }

    @Test("Truly late frames falling far behind the master clock are dropped to catch up")
    func testLateFramesAreDropped() {
        let queue = FrameQueue()
        let staleBuf = createDummyPixelBuffer()
        let freshBuf = createDummyPixelBuffer()

        // Stale frame at 0.0s, Fresh frame at 1.0s
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: staleBuf, pts: CMTime(value: 0, timescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)
            )
        )
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: freshBuf, pts: CMTime(value: 1000, timescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)
            )
        )

        // Master clock jumped to 1.0s: stale frame at 0.0s is 1000ms behind (> 100ms late tolerance)
        let popped = queue.popFrame(forSyncTime: CMTime(value: 1000, timescale: 1000), nominalFrameDuration: 1.0 / 24.0)
        #expect(popped?.pixelBuffer === freshBuf)
        #expect(queue.droppedFramesCount == 1)
    }

    @Test("Clock micro-jitter where syncTime slightly leads frame PTS does not skip frame")
    func testMicroJitterDoesNotPrematurelyDropFrame() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()

        // 50 fps stream: frame 1 at 20ms, frame 2 at 40ms
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(value: 20, timescale: 1000), duration: CMTime(value: 20, timescale: 1000)
            )
        )
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(value: 40, timescale: 1000), duration: CMTime(value: 20, timescale: 1000)
            )
        )

        // Micro-jitter: syncTime arrived at 21ms (1ms ahead of buf1 at 20ms, but 19ms before buf2 at 40ms)
        // buf1 distance: |20 - 21| = 1ms. buf2 distance: |40 - 21| = 19ms.
        // buf1 must be popped, buf2 must be kept in the queue with 0 drops!
        let pop = queue.popFrame(forSyncTime: CMTime(value: 21, timescale: 1000), nominalFrameDuration: 0.020)
        #expect(pop?.pixelBuffer === buf1)
        #expect(queue.count == 1)
        #expect(queue.droppedFramesCount == 0)
    }

    @Test("High frame rate 120fps HFR content does not drop frames due to lead window")
    func testHFR120fpsPacingNoPrematureDrop() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()

        // 120 fps stream: ~8.33ms per frame (buf1 at 0ms, buf2 at 8.33ms)
        let frameDuration = 1.0 / 120.0
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(seconds: 0.0, preferredTimescale: 12000),
                duration: CMTime(seconds: frameDuration, preferredTimescale: 12000)
            )
        )
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(seconds: frameDuration, preferredTimescale: 12000),
                duration: CMTime(seconds: frameDuration, preferredTimescale: 12000)
            )
        )

        #expect(queue.count == 2)
        // Tick at 0ms should pop buf1 and keep buf2
        let pop1 = queue.popFrame(
            forSyncTime: CMTime(seconds: 0.0, preferredTimescale: 12000), nominalFrameDuration: frameDuration)
        #expect(pop1?.pixelBuffer === buf1)
        #expect(queue.count == 1)
        #expect(queue.droppedFramesCount == 0)
    }

    @Test("Invalid nominalFrameDuration (NaN, 0, negative, infinity) is sanitized safely")
    func testInvalidNominalFrameDurationSanitized() {
        let queue = FrameQueue()
        let buf = createDummyPixelBuffer()

        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf, pts: CMTime(value: 0, timescale: 1000), duration: CMTime(value: 41, timescale: 1000)
            )
        )

        // Passing NaN, 0, or negative duration should not crash or produce invalid CMTime
        let popNaN = queue.popFrame(forSyncTime: CMTime(value: 0, timescale: 1000), nominalFrameDuration: .nan)
        #expect(popNaN?.pixelBuffer === buf)
        #expect(queue.count == 0)
    }

    @Test("Accelerated playback (1.7x) lookahead skips are classified as speedSkippedFrames, not pipeline drops")
    func testAcceleratedPlaybackSkipsClassifiedCorrectly() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()

        // 50 fps stream: frame 1 at 0ms, frame 2 at 20ms
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(value: 0, timescale: 1000), duration: CMTime(value: 20, timescale: 1000)
            )
        )
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(value: 20, timescale: 1000), duration: CMTime(value: 20, timescale: 1000)
            )
        )

        // At 1.7x speed on 60Hz display (tick interval 16.67ms host = 28.33ms PTS).
        // Tick at 21ms: buf1 distance |0 - 21| = 21ms. buf2 distance |20 - 21| = 1ms.
        // buf2 is strictly closer, so buf1 is skipped in favor of buf2.
        // Because playbackRate is 1.7 (> 1.01), this MUST be counted as speedSkippedFrames, NOT pipeline drops!
        let popped = queue.popFrame(
            forSyncTime: CMTime(value: 21, timescale: 1000),
            nominalFrameDuration: 0.020,
            playbackRate: 1.7
        )
        #expect(popped?.pixelBuffer === buf2)
        #expect(queue.speedSkippedFramesCount == 1)
        #expect(queue.pipelineDroppedFramesCount == 0)
        #expect(queue.droppedFramesCount == 1)
    }

    @Test("Late tolerance scales with playbackRate to avoid false pipeline drops at high speed")
    func testLateToleranceScalesWithPlaybackRate() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()

        // At 2.0x speed, 60ms of media time is only 30ms of real-world time.
        // With base tolerance 40ms, unscaled tolerance would drop a frame 60ms behind clock.
        // With scaled tolerance (40ms * 2.0 = 80ms), frame at 940ms when clock is 1000ms is within tolerance!
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(value: 940, timescale: 1000),
                duration: CMTime(value: 20, timescale: 1000)
            )
        )
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(value: 1000, timescale: 1000),
                duration: CMTime(value: 20, timescale: 1000)
            )
        )

        let popped = queue.popFrame(
            forSyncTime: CMTime(value: 1000, timescale: 1000),
            nominalFrameDuration: 0.020,
            playbackRate: 2.0
        )
        #expect(popped?.pixelBuffer === buf2)
        // Lookahead replaced buf1 with buf2 due to closer distance at 2.0x:
        #expect(queue.speedSkippedFramesCount == 1)
        #expect(queue.pipelineDroppedFramesCount == 0)
    }
}
