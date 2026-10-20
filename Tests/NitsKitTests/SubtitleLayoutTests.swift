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

    private func cue(_ regions: [SubtitleImageCue.Region], placement: SubtitleImageCue.Placement = .decodedFrame)
        -> SubtitleImageCue
    {
        SubtitleImageCue(
            id: 1, startTime: 0, endTime: 1, canvasWidth: 1920, canvasHeight: 1080, regions: regions,
            placement: placement)
    }

    private func croppedLayout() -> VideoLayout {
        SubtitleOverlayView.computeVideoLayout(
            containerSize: CGSize(width: 1920, height: 1080), videoWidth: 1920, videoHeight: 1080,
            geometry: VideoGeometrySettings(crop: RationalAspectRatio(numerator: 235, denominator: 100)))
    }

    @Test("A crop keeps a stream's canvas at the scale of the picture and moves cut-off lines inside, together")
    func cropKeepsScaleAndMovesLinesInside() {
        let layout = croppedLayout()
        let visible = layout.visibleRect
        // Two dialogue lines in the bottom bar of a 16:9 frame, cut off by the crop to 2.35:1, and a sign at the top.
        let lines = [region(x: 700, y: 960, width: 520, height: 50), region(x: 760, y: 1020, width: 400, height: 50)]
        let sign = region(x: 860, y: 300, width: 200, height: 40)
        let frames = SubtitleOverlayView.imageFrames(
            of: cue(lines + [sign]), canvas: CGSize(width: 1920, height: 1080), in: layout)
        let scale = layout.frameRect.width / 1920
        #expect(abs(frames[0].width - 520 * scale) < 0.001, "Not shrunk to fit the canvas into the crop")
        #expect(frames.allSatisfy { visible.insetBy(dx: -0.001, dy: -0.001).contains($0) })
        #expect(abs(frames[0].maxY - visible.maxY) > 0 && abs(frames[1].maxY - visible.maxY) < 0.001)
        #expect(abs((frames[1].minY - frames[0].minY) - 60 * scale) < 0.001, "Lines keep their spacing")
        #expect(abs(frames[2].minY - (layout.frameRect.minY + 300 * scale)) < 0.001, "The sign stays where it was")
    }

    @Test("Scale grows each half's block from its edge, and raise lifts only the bottom block")
    func scalesAndRaisesBlocks() {
        let layout = SubtitleOverlayView.computeVideoLayout(
            containerSize: CGSize(width: 1920, height: 1080), videoWidth: 1920, videoHeight: 1080)
        let lines = [region(x: 700, y: 900, width: 520, height: 50), region(x: 760, y: 960, width: 400, height: 50)]
        let sign = region(x: 860, y: 100, width: 200, height: 40)
        let canvas = CGSize(width: 1920, height: 1080)
        let plain = SubtitleOverlayView.imageFrames(of: cue(lines + [sign]), canvas: canvas, in: layout)
        let placed = SubtitleOverlayView.imageFrames(
            of: cue(lines + [sign]), canvas: canvas, in: layout, scale: 1.5, raise: 0.1)

        #expect(abs(placed[0].width - plain[0].width * 1.5) < 0.001)
        #expect(abs((placed[1].minY - placed[0].minY) - 60 * 1.5) < 0.001, "Spacing scaled with the lines")
        #expect(abs(placed[1].maxY - (plain[1].maxY - 108)) < 0.001, "Bottom edge kept, then raised by 10%")
        #expect(abs(placed[1].midX - plain[1].midX) < 0.001)
        #expect(abs(placed[2].minY - plain[2].minY) < 0.001, "The sign keeps its top edge and isn't raised")
        #expect(abs(placed[2].height - plain[2].height * 1.5) < 0.001)
    }

    @Test("Under a crop, a raise lifts lines from the visible bottom at once, and no further than the top")
    func raisesFromVisibleBottomUnderCrop() {
        let layout = croppedLayout()
        let visible = layout.visibleRect
        let lines = [region(x: 700, y: 960, width: 520, height: 50), region(x: 760, y: 1020, width: 400, height: 50)]
        let canvas = CGSize(width: 1920, height: 1080)
        let raised = SubtitleOverlayView.imageFrames(of: cue(lines), canvas: canvas, in: layout, raise: 0.05)
        #expect(abs(raised[1].maxY - (visible.maxY - 0.05 * visible.height)) < 0.001, "The first steps already lift")
        let topmost = SubtitleOverlayView.imageFrames(of: cue(lines), canvas: canvas, in: layout, raise: 1)
        #expect(abs(topmost[0].minY - visible.minY) < 0.001, "Stopped at the top")
    }

    @Test("A libass frame covers the visible picture, crop or not")
    func libassFrameCoversVisiblePicture() {
        let layout = croppedLayout()
        let size = CGSize(width: layout.visibleRect.width.rounded(), height: layout.visibleRect.height.rounded())
        let frames = SubtitleOverlayView.imageFrames(
            of: cue(
                [region(x: 0, y: 0, width: Int(size.width), height: Int(size.height))], placement: .visiblePicture),
            canvas: size, in: layout)
        let visible = layout.visibleRect
        #expect(abs(frames[0].minX - visible.minX) < 0.001 && abs(frames[0].minY - visible.minY) < 0.001)
        #expect(abs(frames[0].width - visible.width) < 0.001 && abs(frames[0].height - visible.height) < 0.001)
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
