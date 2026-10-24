@preconcurrency import AVFoundation
import Foundation
import QuartzCore

/// The engine's video layers as a host view shows them, and their layout for the view's bounds: `displayLayer` in a
/// clip layer, the Metal layer over both. The platform view (`VideoHost`) makes `rootLayer` its own layer and calls
/// `layout` on every layout pass.
@MainActor
final class VideoLayers {
    let rootLayer = CALayer()
    /// Holds the display layer and clips it to the visible part of the picture when it is cropped or larger than
    /// the view (see `layout`); covers the view without clipping otherwise.
    private let videoClipLayer = CALayer()
    private let engine: PlayerEngine
    /// Whether the host's coordinates have their origin at the bottom left (AppKit) rather than the top left.
    private let originIsBottomLeft: Bool

    /// The part of the view the picture covers (in its coordinates); updated on every layout.
    private(set) var presentedVideoRect: CGRect = .zero

    /// Whether the picture is larger than the view (zoomed or filled), so a host can let drags move it.
    private(set) var canPanVideo = false

    init(engine: PlayerEngine, contentsScale: CGFloat, originIsBottomLeft: Bool) {
        self.engine = engine
        self.originIsBottomLeft = originIsBottomLeft
        let black = CGColor(gray: 0, alpha: 1)
        rootLayer.backgroundColor = black

        videoClipLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(videoClipLayer)
        engine.displayLayer.backgroundColor = black
        engine.displayLayer.frame = videoClipLayer.bounds
        videoClipLayer.addSublayer(engine.displayLayer)

        if let metalLayer = engine.metalRenderer?.metalLayer {
            metalLayer.backgroundColor = black
            metalLayer.frame = rootLayer.bounds
            metalLayer.contentsScale = contentsScale
            metalLayer.isHidden = true
            rootLayer.addSublayer(metalLayer)
        }
    }

    /// Shows whichever of the display layer and the Metal layer the engine presents on.
    func updateMode() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        engine.displayLayer.isHidden = engine.isMetalLayerVisible
        engine.metalRenderer?.metalLayer.isHidden = !engine.isMetalLayerVisible
        CATransaction.commit()
    }

    /// Lays the layers out for a view of `bounds` at `backingScale`; `alignToBacking` rounds a rect in view
    /// coordinates to whole device pixels.
    func layout(bounds: CGRect, backingScale scale: CGFloat, alignToBacking: (CGRect) -> CGRect) {
        // PiP shows the display layer as the stream lays it out: it mirrors the layer itself, without the clip.
        let isPictureInPicture = engine.pictureInPictureLayerGeometry != nil
        let settings = isPictureInPicture ? VideoGeometrySettings() : engine.videoGeometry
        let videoLayout = VideoGeometry.layout(
            viewSize: bounds.size,
            videoWidth: engine.media.video.width,
            videoHeight: engine.media.video.height,
            sampleAspectRatio: engine.media.video.sampleAspectRatio,
            settings: settings,
            backingScale: scale
        )
        let visibleFrame = viewRect(videoLayout.visibleRect, in: bounds)
        presentedVideoRect = visibleFrame
        canPanVideo = videoLayout.panLimit != .zero

        // No implicit animation: the video layers would lag behind the window being resized.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if settings.isSourceAspectFit {
            // The layout without overrides stays as it always was: the layer covers the view and fits the video.
            videoClipLayer.frame = bounds
            videoClipLayer.masksToBounds = false
            engine.displayLayer.videoGravity = .resizeAspect
            switch engine.pictureInPictureLayerGeometry {
            case nil:
                engine.displayLayer.frame = bounds
            case .pipWindow(let size):
                engine.displayLayer.frame = CGRect(origin: .zero, size: size)
            case .videoRect:
                engine.displayLayer.frame = visibleFrame
            }
        } else {
            // The layer takes the whole (zoomed, uncropped) frame and is stretched to it; the clip layer cuts it to
            // the visible part, so crop, stretch and zoom need no change to the buffers.
            let frame = viewRect(videoLayout.frameRect, in: bounds)
            videoClipLayer.frame = visibleFrame
            videoClipLayer.masksToBounds = true
            engine.displayLayer.videoGravity = .resize
            engine.displayLayer.frame = frame.offsetBy(dx: -visibleFrame.minX, dy: -visibleFrame.minY)
        }

        var needsRedraw = false
        if let renderer = engine.metalRenderer {
            let metalLayer = renderer.metalLayer
            // On whole pixels: a fractional frame makes the compositor resample the drawable, softening the picture.
            // The drawable covers only the visible part, so a zoomed picture never costs more than the view.
            let metalFrame = alignToBacking(visibleFrame)
            let drawableSize = CGSize(
                width: (metalFrame.width * scale).rounded(), height: (metalFrame.height * scale).rounded())
            let sourceRect = videoLayout.sourceRect(for: viewRect(metalFrame, in: bounds))
            needsRedraw = metalLayer.drawableSize != drawableSize || renderer.sourceRect != sourceRect
            metalLayer.contentsScale = scale
            metalLayer.frame = metalFrame
            metalLayer.drawableSize = drawableSize
            renderer.sourceRect = sourceRect
        }
        CATransaction.commit()

        // While playing, the next frame comes within a frame duration; a redraw would only compete with the display
        // link for drawables.
        if needsRedraw, engine.isMetalLayerVisible, !engine.isPlaying {
            engine.metalRenderer?.redrawLastFrame()
        }
    }

    /// `rect` moved between the top-left origin of `VideoLayout` and the view's coordinates; its own inverse.
    private func viewRect(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard originIsBottomLeft else { return rect }
        return CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
