import CoreMedia
import CoreVideo
import Testing

@testable import NitsCore

@Suite("StepFrameCache Tests")
struct StepFrameCacheTests {
    private func dummyPixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pixelBuffer)
        precondition(status == kCVReturnSuccess && pixelBuffer != nil)
        return pixelBuffer!
    }

    private func append(_ cache: StepFrameCache, _ seconds: Double) -> CVPixelBuffer {
        let buf = dummyPixelBuffer()
        cache.append(pixelBuffer: buf, pts: CMTime(seconds: seconds, preferredTimescale: 1000))
        return buf
    }

    @Test("frameAfter and frameBefore return the nearest neighbors around the cursor")
    func testNeighbors() {
        let cache = StepFrameCache()
        let b100 = append(cache, 1.00)
        let b104 = append(cache, 1.04)
        let b108 = append(cache, 1.08)

        // Stepping forward from 1.04 yields 1.08; backward yields 1.00.
        #expect(cache.frameAfter(1.04)?.pixelBuffer === b108)
        #expect(cache.frameBefore(1.04)?.pixelBuffer === b100)

        // Stepping forward from the first frame yields the second.
        #expect(cache.frameAfter(1.00)?.pixelBuffer === b104)

        // Edges: nothing after the last frame, nothing before the first.
        #expect(cache.frameAfter(1.08) == nil)
        #expect(cache.frameBefore(1.00) == nil)
    }

    @Test("Frames are ordered by PTS regardless of insertion order")
    func testOrdering() {
        let cache = StepFrameCache()
        _ = append(cache, 3.0)
        let b1 = append(cache, 1.0)
        _ = append(cache, 2.0)
        #expect(cache.count == 3)
        #expect(cache.frameBefore(2.0)?.pixelBuffer === b1)
    }

    @Test("Capacity evicts the frame furthest behind as stepping advances forward")
    func testEvictionKeepsForwardWindow() {
        let cache = StepFrameCache(capacity: 4)
        // Append ascending frames 0..7; only the newest 4 (4,5,6,7) should remain.
        for i in 0..<8 { _ = append(cache, Double(i) * 0.04) }
        #expect(cache.count == 4)
        // The oldest retained frame is index 4 (0.16s); nothing before it is cached.
        #expect(cache.frameBefore(0.16) == nil)
        #expect(cache.frameAfter(0.16) != nil)
    }

    @Test("Duplicate PTS inserts are ignored")
    func testDuplicatePTSIgnored() {
        let cache = StepFrameCache()
        _ = append(cache, 1.0)
        _ = append(cache, 1.0)
        #expect(cache.count == 1)
    }

    @Test("countAfter reports the forward look-ahead depth")
    func testCountAfter() {
        let cache = StepFrameCache()
        #expect(cache.countAfter(0.0) == 0)
        for pts in [1.00, 1.04, 1.08, 1.12] { _ = append(cache, pts) }
        // From 1.04, the frames strictly ahead are 1.08 and 1.12.
        #expect(cache.countAfter(1.04) == 2)
        #expect(cache.countAfter(1.12) == 0)
    }

    @Test("Duplicate PTS is rejected from either rounding side")
    func testDuplicateNeighborRejected() {
        let cache = StepFrameCache()
        _ = append(cache, 1.0)
        // A value a hair above an existing PTS lands past it in the sorted order, so only the left-neighbor
        // check can catch it as a duplicate.
        let buf = dummyPixelBuffer()
        cache.append(pixelBuffer: buf, pts: CMTime(value: 10_000_001, timescale: 10_000_000))  // ~1.0000001s
        #expect(cache.count == 1)
    }

    @Test("clear releases all cached frames")
    func testClear() {
        let cache = StepFrameCache()
        _ = append(cache, 1.0)
        _ = append(cache, 1.04)
        cache.clear()
        #expect(cache.count == 0)
        #expect(cache.frameAfter(0.0) == nil)
    }
}
