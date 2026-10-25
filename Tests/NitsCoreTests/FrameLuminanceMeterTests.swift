import CoreVideo
import Foundation
import Testing

@testable import NitsCore

/// Synthetic 4:2:0 biplanar frames for `FrameLuminanceMeter`: each pixel's R'G'B' (PQ or HLG code values, BT.2020)
/// encoded to Y'CbCr codes as a decoder would hand them over.
private enum SyntheticFrame {
    static let width = 128
    static let height = 72

    /// A frame of `format` whose pixel at (x, y) has non-linear R'G'B' `rgb(x, y)` in [0, 1].
    static func make(_ format: OSType, rgb: (Int, Int) -> SIMD3<Float>) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &buffer) == kCVReturnSuccess,
            let buffer
        else { return nil }
        let tenBit =
            format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange =
            format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let maxCode: Float = tenBit ? 1023 : 255
        let scale: Float = tenBit ? 4 : 1  // video-range limits are given for 8 bits
        func codes(_ e: SIMD3<Float>) -> SIMD3<Float> {
            let y = 0.2627 * e.x + 0.6780 * e.y + 0.0593 * e.z
            let cb = (e.z - y) / 1.8814
            let cr = (e.x - y) / 1.4746
            if fullRange {
                return SIMD3(y * maxCode, (cb + 0.5) * maxCode, (cr + 0.5) * maxCode).rounded(.toNearestOrEven)
            }
            return SIMD3(16 * scale + 219 * scale * y, 128 * scale + 224 * scale * cb, 128 * scale + 224 * scale * cr)
                .rounded(.toNearestOrEven)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height {
            for x in 0..<width {
                let c = codes(rgb(x, y))
                if tenBit {
                    // P010: 10-bit codes in the high bits of 16.
                    luma.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt16.self)[x] = UInt16(c.x) << 6
                    if x % 2 == 0, y % 2 == 0 {
                        let row = chroma.advanced(by: y / 2 * chromaStride).assumingMemoryBound(to: UInt16.self)
                        row[x] = UInt16(c.y) << 6
                        row[x + 1] = UInt16(c.z) << 6
                    }
                } else {
                    luma.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt8.self)[x] = UInt8(c.x)
                    if x % 2 == 0, y % 2 == 0 {
                        let row = chroma.advanced(by: y / 2 * chromaStride).assumingMemoryBound(to: UInt8.self)
                        row[x] = UInt8(c.y)
                        row[x + 1] = UInt8(c.z)
                    }
                }
            }
        }
        return buffer
    }

    static func pq(_ nits: Float) -> Float { ThumbnailToneMapper.nitsToPQ(nits) }
}

@Suite("Frame Luminance Meter")
struct FrameLuminanceMeterTests {
    private let pqMeter = FrameLuminanceMeter(signal: .pq, isBT709: false)

    @Test("A flat PQ grey measures its own luminance, in 10-bit video range and 8-bit full range")
    func flatGrey() throws {
        for format in [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ] {
            let grey = SIMD3(repeating: SyntheticFrame.pq(100))
            let buffer = try #require(SyntheticFrame.make(format) { _, _ in grey })
            let average = try #require(pqMeter.measure(buffer, reshaping: nil)?.averageNits)
            #expect(abs(average / 100 - 1) < 0.04, "format \(format): \(average) nits")
        }
    }

    @Test("The average is taken in PQ, as Dolby Vision's L1 average: the mean code value, not the mean of the light")
    func averageInPQ() throws {
        let dark = SIMD3(repeating: SyntheticFrame.pq(10))
        let bright = SIMD3(repeating: SyntheticFrame.pq(1000))
        let buffer = try #require(
            SyntheticFrame.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { _, y in
                y < SyntheticFrame.height / 2 ? dark : bright
            })
        let average = try #require(pqMeter.measure(buffer, reshaping: nil)?.averageNits)
        let expected = ThumbnailToneMapper.pqToNits((SyntheticFrame.pq(10) + SyntheticFrame.pq(1000)) / 2)
        #expect(abs(average / expected - 1) < 0.05, "\(average) nits, expected \(expected)")
        #expect(average < 300, "a mean of the light would be ~505 nits")
    }

    @Test("A saturated colour counts by its strongest channel, not its luminance")
    func maxRGB() throws {
        let red = SIMD3(SyntheticFrame.pq(500), SyntheticFrame.pq(1), SyntheticFrame.pq(1))
        let buffer = try #require(SyntheticFrame.make(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) { _, _ in red })
        let average = try #require(pqMeter.measure(buffer, reshaping: nil)?.averageNits)
        #expect(abs(average / 500 - 1) < 0.06, "\(average) nits; its luminance is ~130")
    }

    @Test("The peak is the brightest sample's max(R, G, B)")
    func peak() throws {
        let dark = SIMD3(repeating: SyntheticFrame.pq(20))
        let sky = SIMD3(SyntheticFrame.pq(600), SyntheticFrame.pq(400), SyntheticFrame.pq(250))
        let buffer = try #require(
            SyntheticFrame.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { _, y in
                y < SyntheticFrame.height / 4 ? sky : dark
            })
        let measurement = try #require(pqMeter.measure(buffer, reshaping: nil))
        #expect(abs(measurement.peakNits / 600 - 1) < 0.06, "\(measurement.peakNits) nits")
        #expect(measurement.averageNits < 100)
    }

    @Test("HLG at reference white (75 %) measures 203 nits through the 1000-nit OOTF")
    func hlgReferenceWhite() throws {
        let meter = FrameLuminanceMeter(signal: .hlg, isBT709: false)
        let buffer = try #require(
            SyntheticFrame.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { _, _ in SIMD3(repeating: 0.75) })
        let average = try #require(meter.measure(buffer, reshaping: nil)?.averageNits)
        #expect(abs(average / 203 - 1) < 0.05, "\(average) nits")
    }

    @Test("A neutral Dolby Vision Profile 5 frame without reshaping measures its intensity")
    func profile5Neutral() throws {
        let meter = FrameLuminanceMeter(signal: .dolbyVisionIPT, isBT709: false)
        // IPT codes: I carries PQ, P and T sit at neutral; written as R'G'B' greys, so Cb / Cr come out neutral.
        let buffer = try #require(
            SyntheticFrame.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { _, _ in
                SIMD3(repeating: SyntheticFrame.pq(100))
            })
        let average = try #require(meter.measure(buffer, reshaping: nil)?.averageNits)
        #expect(abs(average / 100 - 1) < 0.1, "\(average) nits")
    }

    @Test("A buffer it can't read gives no measurement")
    func unsupportedFormat() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        #expect(pqMeter.measure(try #require(buffer), reshaping: nil) == nil)
    }
}

@Suite("Measured Reference White")
struct MeasuredReferenceWhiteTests {
    @Test("The title's static peak sets a dark scene's white; a bright scene's average raises it")
    func rule() {
        func white(_ average: Float, _ peak: Float) -> Float {
            ToneMapController.measuredTargetNits(averageNits: average, staticPeakNits: peak)
        }
        // The fitted points: ~100 at MaxCLL 451, ~115 at ~1000, ~150 at 8154 for dark scenes.
        #expect(abs(white(0, 451) - 100) < 0.5)
        #expect(abs(white(0, 1000) - 113.5) < 0.5)
        #expect(abs(white(0, 8154) - 149.2) < 0.5)
        // A bright scene of a ~1000-nit title: the average's term takes over.
        #expect(abs(white(76, 1000) - 144.9) < 0.5)
        #expect(white(20, 1000) > white(5, 1000))
        // It never falls below the average's own floor, nor goes negative for a missing peak.
        #expect(white(0, 0) >= 80)
    }

    @Test("The user's scale can't take the white under 100 nits")
    func floor() {
        #expect(ToneMapController.scaledTargetNits(110, scale: 0.5) == 100)
        #expect(ToneMapController.scaledTargetNits(150, scale: 0.8) == 120)
    }
}

@Suite("Measured White in applyFrame")
@MainActor
struct MeasuredWhiteApplyFrameTests {
    private static func grey(_ nits: Float) throws -> CVPixelBuffer {
        try #require(
            SyntheticFrame.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { _, _ in
                SIMD3(repeating: SyntheticFrame.pq(nits))
            })
    }

    private static func controller() -> ToneMapController {
        let controller = ToneMapController(renderer: nil, monitor: PlayerPerformanceMonitor())
        controller.adapt(toPeakNits: 1000, fallNits: 0, hasStaticPeak: true)
        controller.frameState.withLock { $0.luminanceMeter = FrameLuminanceMeter(signal: .pq, isBT709: false) }
        return controller
    }

    private static func white(of controller: ToneMapController) -> Float {
        controller.frameState.withLock { $0.targetNits }
    }

    private static func expected(_ averageNits: Float) -> Float {
        ToneMapController.measuredTargetNits(averageNits: averageNits, staticPeakNits: 1000)
    }

    @Test("The first measured frame sets the white as is; small changes are smoothed, a cut is taken at once")
    func smoothingAndCuts() throws {
        let controller = Self.controller()
        _ = controller.applyFrame(hdrMetadata: nil, pixelBuffer: try Self.grey(30))
        let first = Self.white(of: controller)
        #expect(abs(first - Self.expected(30)) < 1, "white \(first)")

        // Within 1 % PQ of the smoothed average: only 15 % of the way.
        _ = controller.applyFrame(hdrMetadata: nil, pixelBuffer: try Self.grey(32))
        let smoothed = Self.white(of: controller)
        #expect(smoothed > first && smoothed < Self.expected(32) - 0.1, "white \(smoothed)")

        // A jump of more than 3 % PQ is a cut.
        _ = controller.applyFrame(hdrMetadata: nil, pixelBuffer: try Self.grey(1))
        #expect(abs(Self.white(of: controller) - Self.expected(1)) < 1)

        // A redraw restarts the smoothing.
        _ = controller.applyFrame(hdrMetadata: nil, pixelBuffer: try Self.grey(32), restartsSmoothing: true)
        #expect(abs(Self.white(of: controller) - Self.expected(32)) < 1)
    }

    @Test("A frame without a buffer keeps the measured white; a new media forgets it")
    func holdsAndResets() throws {
        let controller = Self.controller()
        _ = controller.applyFrame(hdrMetadata: nil, pixelBuffer: try Self.grey(50))
        let white = Self.white(of: controller)
        _ = controller.applyFrame(hdrMetadata: nil)
        #expect(Self.white(of: controller) == white)

        controller.adapt(toPeakNits: 1000, fallNits: 0, hasStaticPeak: true)
        #expect(controller.frameState.withLock { $0.smoothedAveragePQ } == nil)
    }

    @Test("A frame brighter than the scene's peak raises the curve's peak to its own; a darker one keeps the scene's")
    func measuredPeakRaisesCurvePeak() throws {
        let controller = Self.controller()
        controller.adapt(toPeakNits: 300, fallNits: 0, hasStaticPeak: true)
        _ = controller.applyFrame(hdrMetadata: nil, pixelBuffer: try Self.grey(600), restartsSmoothing: true)
        let raised = controller.frameState.withLock { $0.curvePeakNits }
        #expect(abs(raised / 600 - 1) < 0.05, "curve peak \(raised)")

        _ = controller.applyFrame(hdrMetadata: nil, pixelBuffer: try Self.grey(100), restartsSmoothing: true)
        #expect(controller.frameState.withLock { $0.curvePeakNits } == 300)

        controller.adapt(toPeakNits: 1000, fallNits: 0, hasStaticPeak: true)
        #expect(controller.frameState.withLock { $0.smoothedMeasuredPeakPQ } == nil)
    }

    @Test("SDR media isn't measured")
    func sdrIsNotMeasured() throws {
        let controller = ToneMapController(renderer: nil, monitor: PlayerPerformanceMonitor())
        controller.adapt(toPeakNits: 1000, fallNits: 0, hasStaticPeak: true)
        let before = Self.white(of: controller)
        _ = controller.applyFrame(hdrMetadata: nil, pixelBuffer: try Self.grey(50))
        #expect(Self.white(of: controller) == before)
    }
}
