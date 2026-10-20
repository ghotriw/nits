import CoreGraphics
import NitsCore
import NitsUI
import SwiftUI
import Testing

@Suite("Subtitle Proportional Layout and Sizing Tests")
@MainActor
struct SubtitleLayoutTests {

    @Test("computeVideoFrame aspect-fit calculations for wider and taller containers")
    func testComputeVideoFrameAspectFit() {
        // 1. Container 16:9 (1920x1080), Video 16:9 (3840x2160) -> Perfect fit
        let frame1 = SubtitleOverlayView.computeVideoFrame(
            containerSize: CGSize(width: 1920, height: 1080),
            videoWidth: 3840,
            videoHeight: 2160
        )
        #expect(abs(frame1.origin.x) < 0.001)
        #expect(abs(frame1.origin.y) < 0.001)
        #expect(abs(frame1.width - 1920) < 0.001)
        #expect(abs(frame1.height - 1080) < 0.001)

        // 2. Container ultrawide (2400x1000), Video 16:9 (1920x1080) -> Pillarbox (bars on sides)
        let frame2 = SubtitleOverlayView.computeVideoFrame(
            containerSize: CGSize(width: 2400, height: 1000),
            videoWidth: 1920,
            videoHeight: 1080
        )
        let expectedWidth = 1000.0 * (16.0 / 9.0)
        let expectedOffsetX = (2400.0 - expectedWidth) / 2.0
        #expect(abs(frame2.origin.x - expectedOffsetX) < 0.001)
        #expect(abs(frame2.origin.y) < 0.001)
        #expect(abs(frame2.width - expectedWidth) < 0.001)
        #expect(abs(frame2.height - 1000.0) < 0.001)

        // 3. Container vertical/tall (1000x1500), Video 16:9 (1920x1080) -> Letterbox (bars on top/bottom)
        let frame3 = SubtitleOverlayView.computeVideoFrame(
            containerSize: CGSize(width: 1000, height: 1500),
            videoWidth: 1920,
            videoHeight: 1080
        )
        let expectedHeight = 1000.0 / (16.0 / 9.0)
        let expectedOffsetY = (1500.0 - expectedHeight) / 2.0
        #expect(abs(frame3.origin.x) < 0.001)
        #expect(abs(frame3.origin.y - expectedOffsetY) < 0.001)
        #expect(abs(frame3.width - 1000.0) < 0.001)
        #expect(abs(frame3.height - expectedHeight) < 0.001)

        // 4. Cinema 2.39:1 video in 16:9 container (1920x1080) -> Letterbox
        let frame4 = SubtitleOverlayView.computeVideoFrame(
            containerSize: CGSize(width: 1920, height: 1080),
            videoWidth: 1920,
            videoHeight: 800  // ~2.4:1
        )
        let expectedCinemaHeight = 1920.0 / (1920.0 / 800.0)  // 800
        let expectedCinemaOffsetY = (1080.0 - 800.0) / 2.0  // 140
        #expect(abs(frame4.origin.x) < 0.001)
        #expect(abs(frame4.origin.y - expectedCinemaOffsetY) < 0.001)
        #expect(abs(frame4.width - 1920.0) < 0.001)
        #expect(abs(frame4.height - expectedCinemaHeight) < 0.001)
    }

    @Test("computeVideoFrame fallback on zero dimensions")
    func testComputeVideoFrameFallback() {
        let frameZero = SubtitleOverlayView.computeVideoFrame(
            containerSize: CGSize(width: 800, height: 600),
            videoWidth: 0,
            videoHeight: 0
        )
        #expect(frameZero.origin == .zero)
        #expect(frameZero.size.width == 800)
        #expect(frameZero.size.height == 600)
    }

    @Test("SubtitleOutlineModifier applies to SwiftUI Text")
    @MainActor
    func testSubtitleOutlineModifier() {
        let view = Text("Subtitle Test")
            .subtitleOutline(radius: 2.0, color: .black)
        _ = view
    }

    @Test("SubtitleOverlayView resolves custom and system fonts")
    func testSubtitleFontResolution() {
        _ = SubtitleOverlayView.resolveFont(name: "System Rounded", size: 24.0, weightName: "Bold")
        _ = SubtitleOverlayView.resolveFont(name: "System", size: 24.0, weightName: "Regular")
        _ = SubtitleOverlayView.resolveFont(name: "System Serif", size: 24.0, weightName: "Heavy")
        _ = SubtitleOverlayView.resolveFont(name: "System Monospaced", size: 24.0, weightName: "Medium")
        _ = SubtitleOverlayView.resolveFont(name: "Helvetica Neue", size: 24.0, weightName: "Semibold")

        #expect(SubtitleOverlayView.resolveWeight("regular") == .regular)
        #expect(SubtitleOverlayView.resolveWeight("medium") == .medium)
        #expect(SubtitleOverlayView.resolveWeight("semibold") == .semibold)
        #expect(SubtitleOverlayView.resolveWeight("bold") == .bold)
        #expect(SubtitleOverlayView.resolveWeight("heavy") == .heavy)
        #expect(SubtitleOverlayView.resolveWeight("unknown") == .semibold)
    }
}

@Suite("Bitmap subtitle placement")
struct BitmapSubtitlePlacementTests {
    private func region(x: Int, y: Int, width: Int, height: Int) -> SubtitleImageCue.Region {
        SubtitleImageCue.Region(x: x, y: y, width: width, height: height, indices: Data(), palette: [])
    }

    @Test("A canvas of the picture's proportions is stretched over it")
    func stretchesMatchingCanvas() {
        let frame = SubtitleOverlayView.imageFrame(
            of: region(x: 850, y: 995, width: 220, height: 75), canvas: CGSize(width: 1920, height: 1080),
            in: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        #expect(frame == CGRect(x: 1700, y: 1990, width: 440, height: 150))
    }

    @Test("A 16:9 canvas on a picture cut to 2:1 is fitted whole, undistorted and inside the frame")
    func fitsCanvasOfOtherProportions() {
        let video = CGRect(x: 0, y: 0, width: 3840, height: 1920)
        let frame = SubtitleOverlayView.imageFrame(
            of: region(x: 899, y: 1026, width: 121, height: 44), canvas: CGSize(width: 1920, height: 1080), in: video)
        let scale = 1920.0 / 1080.0
        #expect(abs(frame.width / 121 - scale) < 0.001 && abs(frame.height / 44 - scale) < 0.001)
        #expect(abs(frame.midX - video.midX) < 0.5 * scale * 4, "Centered text stays centered")
        #expect(video.contains(frame))
    }

    @Test("The frame follows an offset visible rect, and an unusable canvas gives no frame")
    func followsVisibleRect() {
        let frame = SubtitleOverlayView.imageFrame(
            of: region(x: 0, y: 0, width: 100, height: 50), canvas: CGSize(width: 1000, height: 500),
            in: CGRect(x: 40, y: 20, width: 500, height: 250))
        #expect(frame == CGRect(x: 40, y: 20, width: 50, height: 25))
        #expect(
            SubtitleOverlayView.imageFrame(
                of: region(x: 0, y: 0, width: 1, height: 1), canvas: .zero,
                in: CGRect(x: 0, y: 0, width: 10, height: 10))
                == .zero)
    }
}
