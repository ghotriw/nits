import CoreGraphics
import Testing

@testable import NitsCore

@Suite("Video Geometry")
struct VideoGeometryTests {
    private let view = CGSize(width: 1600, height: 1000)

    private func layout(
        width: Int = 1920, height: Int = 1080, sar: RationalAspectRatio = .square,
        _ settings: VideoGeometrySettings = VideoGeometrySettings(), in viewSize: CGSize? = nil, scale: CGFloat = 1
    ) -> VideoLayout {
        VideoGeometry.layout(
            viewSize: viewSize ?? view, videoWidth: width, videoHeight: height, sampleAspectRatio: sar,
            settings: settings, backingScale: scale)
    }

    private func expectEqual(_ a: CGRect, _ b: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
        let close =
            abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6
            && abs(a.height - b.height) < 1e-6
        #expect(close, "\(a) != \(b)", sourceLocation: sourceLocation)
    }

    private let fullSource = CGRect(x: 0, y: 0, width: 1, height: 1)

    @Test func defaultFitLetterboxes() {
        let result = layout()
        expectEqual(result.visibleRect, CGRect(x: 0, y: 50, width: 1600, height: 900))
        expectEqual(result.frameRect, result.visibleRect)
        expectEqual(result.sourceRect, fullSource)
        #expect(result.panLimit == .zero)
    }

    @Test func anamorphicUsesSampleAspectRatio() {
        // DVD PAL 16:9: 720×576 with SAR 64:45.
        let result = layout(width: 720, height: 576, sar: RationalAspectRatio(numerator: 64, denominator: 45))
        #expect(abs(result.visibleRect.width / result.visibleRect.height - 720.0 * 64 / 45 / 576) < 1e-9)
    }

    @Test func aspectOverrideReplacesStreamRatio() {
        let settings = VideoGeometrySettings(aspectRatio: RationalAspectRatio(numerator: 4, denominator: 3))
        let result = layout(settings)
        expectEqual(
            result.visibleRect, CGRect(x: (1600 - 1000 * 4.0 / 3) / 2, y: 0, width: 1000 * 4.0 / 3, height: 1000))
        expectEqual(result.sourceRect, fullSource)
        #expect(
            VideoGeometry.contentAspectRatio(
                videoWidth: 1920, videoHeight: 1080, sampleAspectRatio: .square, settings: settings) == 4.0 / 3)
    }

    @Test func cropToWiderRatioCutsTopAndBottom() {
        let crop = RationalAspectRatio(numerator: 239, denominator: 100)
        let result = layout(VideoGeometrySettings(crop: crop))
        let height = 1600 / 2.39
        expectEqual(result.visibleRect, CGRect(x: 0, y: (1000 - height) / 2, width: 1600, height: height))
        let kept = (16.0 / 9) / 2.39
        expectEqual(result.sourceRect, CGRect(x: 0, y: (1 - kept) / 2, width: 1, height: kept))
        #expect(result.frameRect.height > result.visibleRect.height)
    }

    @Test func cropToNarrowerRatioCutsSides() {
        let result = layout(VideoGeometrySettings(crop: RationalAspectRatio(numerator: 4, denominator: 3)))
        let kept = (4.0 / 3) / (16.0 / 9)
        expectEqual(result.sourceRect, CGRect(x: (1 - kept) / 2, y: 0, width: kept, height: 1))
        #expect(abs(result.visibleRect.width / result.visibleRect.height - 4.0 / 3) < 1e-9)
    }

    @Test func cropAppliesAfterAspectOverride() {
        // A 4:3 frame forced to 16:9, then cropped to 4:3, keeps the middle three quarters of the width.
        let settings = VideoGeometrySettings(
            aspectRatio: RationalAspectRatio(numerator: 16, denominator: 9),
            crop: RationalAspectRatio(numerator: 4, denominator: 3))
        let result = layout(width: 1440, height: 1080, settings)
        expectEqual(result.sourceRect, CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
    }

    @Test func fillCoversViewAndCutsEdges() {
        let result = layout(VideoGeometrySettings(scaling: .fill))
        expectEqual(result.visibleRect, CGRect(origin: .zero, size: view))
        let width = 1000 * 16.0 / 9
        expectEqual(result.contentRect, CGRect(x: (1600 - width) / 2, y: 0, width: width, height: 1000))
        let kept = 1600 / width
        expectEqual(result.sourceRect, CGRect(x: (1 - kept) / 2, y: 0, width: kept, height: 1))
        #expect(abs(result.panLimit.width - (width - 1600) / 2) < 1e-9)
        #expect(result.panLimit.height == 0)
    }

    @Test func stretchIgnoresAspectRatio() {
        let result = layout(VideoGeometrySettings(scaling: .stretch))
        expectEqual(result.visibleRect, CGRect(origin: .zero, size: view))
        expectEqual(result.sourceRect, fullSource)
    }

    @Test func originalSizeMapsPixelsToBackingPixels() {
        let result = layout(width: 1280, height: 720, VideoGeometrySettings(scaling: .original), scale: 2)
        expectEqual(result.visibleRect, CGRect(x: (1600 - 640) / 2, y: (1000 - 360) / 2, width: 640, height: 360))
    }

    @Test func originalSizeFitsLargerVideo() {
        let result = layout(width: 3840, height: 2160, VideoGeometrySettings(scaling: .original), scale: 2)
        expectEqual(result.visibleRect, layout().visibleRect)
    }

    @Test func zoomEnlargesAroundCenterAndClipsToView() {
        let result = layout(VideoGeometrySettings(zoom: 2))
        expectEqual(result.contentRect, CGRect(x: -800, y: -400, width: 3200, height: 1800))
        expectEqual(result.visibleRect, CGRect(origin: .zero, size: view))
        expectEqual(result.sourceRect, CGRect(x: 0.25, y: 400.0 / 1800, width: 0.5, height: 1000.0 / 1800))
    }

    @Test func panMovesWithinLimitsAndClamps() {
        let left = layout(VideoGeometrySettings(zoom: 2, pan: CGPoint(x: -1, y: 0)))
        #expect(left.contentRect.minX == 0)
        let beyond = layout(VideoGeometrySettings(zoom: 2, pan: CGPoint(x: 5, y: 5)))
        #expect(beyond.contentRect.maxX == view.width)
        #expect(beyond.contentRect.maxY == view.height)
        // Fit at 1×: nothing to pan, whatever the setting says.
        let fit = layout(VideoGeometrySettings(pan: CGPoint(x: 1, y: 1)))
        expectEqual(fit.visibleRect, layout().visibleRect)
    }

    @Test func dragTranslatesToPan() {
        let settings = VideoGeometrySettings(zoom: 2)
        let current = layout(settings)
        let pan = VideoGeometry.pan(settings, movedBy: CGSize(width: 400, height: 0), in: current)
        #expect(abs(pan.x - -0.5) < 1e-9)
        #expect(pan.y == 0)
        var moved = settings
        moved.pan = pan
        #expect(abs(layout(moved).contentRect.minX - (current.contentRect.minX + 400)) < 1e-9)
    }

    @Test func zoomStepsSnapAndClamp() {
        let base = VideoGeometrySettings()
        #expect(abs(base.zoomed(bySteps: 4).zoom - 2) < 1e-9)
        #expect(base.zoomed(bySteps: 4).zoomed(bySteps: -4).zoom == 1)
        #expect(base.zoomed(bySteps: 100).zoom == VideoGeometrySettings.zoomRange.upperBound)
        #expect(base.zoomed(bySteps: -100).zoom == VideoGeometrySettings.zoomRange.lowerBound)
    }

    @Test(arguments: [Double.nan, .infinity, 0, -2])
    func unusableZoomActsAsOneAndStepsFromThere(zoom: Double) {
        let settings = VideoGeometrySettings(zoom: zoom)
        #expect(settings.effectiveZoom == 1)
        #expect(settings.isSourceAspectFit)
        expectEqual(layout(settings).visibleRect, layout().visibleRect)
        #expect(abs(settings.zoomed(bySteps: 4).zoom - 2) < 1e-9)
    }

    @Test func zoomOutsideRangeIsClampedInLayout() {
        let result = layout(VideoGeometrySettings(zoom: 100))
        #expect(abs(result.contentRect.width - 1600 * VideoGeometrySettings.zoomRange.upperBound) < 1e-6)
    }

    @Test func infiniteViewIsSafe() {
        let result = layout(in: CGSize(width: CGFloat.infinity, height: 1000))
        #expect(result.sourceRect == fullSource)
        #expect(result.panLimit == .zero)
    }

    @Test func sourceAspectFitOnlyWithoutOverrides() {
        #expect(VideoGeometrySettings().isSourceAspectFit)
        #expect(VideoGeometrySettings(pan: CGPoint(x: 1, y: 0)).isSourceAspectFit)
        #expect(!VideoGeometrySettings(scaling: .fill).isSourceAspectFit)
        #expect(!VideoGeometrySettings(zoom: 1.5).isSourceAspectFit)
        #expect(!VideoGeometrySettings(crop: .square).isSourceAspectFit)
    }

    @Test func presetNamesAndCycle() {
        #expect(RationalAspectRatio(numerator: 235, denominator: 100).displayName == "2.35:1")
        #expect(RationalAspectRatio(numerator: 16, denominator: 9).displayName == "16:9")
        var current: RationalAspectRatio? = nil
        var seen = 0
        repeat {
            current = RationalAspectRatio.nextDisplayPreset(after: current)
            seen += 1
        } while current != nil && seen < 100
        #expect(seen == RationalAspectRatio.displayPresets.count + 1)
    }

    @Test func emptyViewOrVideoIsSafe() {
        let empty = layout(in: .zero)
        #expect(empty.visibleRect == .zero)
        let noVideo = layout(width: 0, height: 0, VideoGeometrySettings(scaling: .original, zoom: 2))
        #expect(noVideo.visibleRect.width.isFinite && noVideo.sourceRect.width.isFinite)
    }
}
