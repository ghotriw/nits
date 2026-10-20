import AVFoundation
import AppKit

public final class NativeVideoHostView: NSView {
    public var onFileDrop: ((String) -> Void)?
    public var onFilesDrop: (([URL]) -> Void)?
    private let engine: PlayerEngine
    private let rootLayer = CALayer()
    /// Holds the display layer and clips it to the visible part of the picture when it is cropped or larger than
    /// the view (see `layout()`); covers the view without clipping otherwise.
    private let videoClipLayer = CALayer()

    public init(engine: PlayerEngine) {
        self.engine = engine
        super.init(frame: .zero)
        setup()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeBackingLayer() -> CALayer {
        return rootLayer
    }

    /// The part of this view the picture covers (in its coordinates), for hosts that draw over the video; updated
    /// on every layout.
    public private(set) var presentedVideoRect: CGRect = .zero

    /// Whether the picture is larger than the view (zoomed or filled), so a host can let drags move it.
    public private(set) var canPanVideo = false

    /// A window movable by its background doesn't move from a drag on a picture that can be panned.
    public override var mouseDownCanMoveWindow: Bool {
        !canPanVideo
    }

    private func setup() {
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        rootLayer.backgroundColor = NSColor.black.cgColor

        // Add AVSampleBufferDisplayLayer
        videoClipLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(videoClipLayer)
        engine.displayLayer.backgroundColor = NSColor.black.cgColor
        engine.displayLayer.frame = videoClipLayer.bounds
        videoClipLayer.addSublayer(engine.displayLayer)

        // Add CAMetalLayer
        if let metalLayer = engine.metalRenderer?.metalLayer {
            metalLayer.backgroundColor = NSColor.black.cgColor
            metalLayer.frame = rootLayer.bounds
            metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            metalLayer.isHidden = true
            rootLayer.addSublayer(metalLayer)
        }
    }

    public func updateMode() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        engine.displayLayer.isHidden = engine.isMetalLayerVisible
        engine.metalRenderer?.metalLayer.isHidden = !engine.isMetalLayerVisible
        CATransaction.commit()
        needsLayout = true
    }

    public func updateScreenHDRStatus() {
        let screen = window?.screen ?? NSScreen.main
        let isHDR = (screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.01
        if engine.isHDRDisplay != isHDR {
            engine.isHDRDisplay = isHDR
            updateMode()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            // A display mode change (e.g. ProMotion → 60 Hz in System Settings) keeps the window on the same
            // screen, so `didChangeScreen` does not fire for it.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenParametersDidChange(_:)),
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            updateScreenHDRStatus()
            engine.attachDisplayLink(to: self)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        engine.updateDisplayLinkFrameRate()
        updateScreenHDRStatus()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        engine.updateDisplayLinkFrameRate()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScreenHDRStatus()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        engine.metalRenderer?.metalLayer.contentsScale = scale
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        // PiP shows the display layer as the stream lays it out: it mirrors the layer itself, without the clip.
        let isPictureInPicture = engine.pictureInPictureLayerGeometry != nil
        let settings = isPictureInPicture ? VideoGeometrySettings() : engine.videoGeometry
        let videoLayout = VideoGeometry.layout(
            viewSize: bounds.size,
            videoWidth: engine.videoWidth,
            videoHeight: engine.videoHeight,
            sampleAspectRatio: engine.sampleAspectRatio,
            settings: settings,
            backingScale: scale
        )
        let visibleFrame = viewRect(videoLayout.visibleRect)
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
            let frame = viewRect(videoLayout.frameRect)
            videoClipLayer.frame = visibleFrame
            videoClipLayer.masksToBounds = true
            engine.displayLayer.videoGravity = .resize
            engine.displayLayer.frame = frame.offsetBy(dx: -visibleFrame.minX, dy: -visibleFrame.minY)
        }
        if engine.pictureInPictureLayerGeometry != nil {
            // AVKit draws its "playing in picture in picture" placeholder as a sublayer of the display layer and
            // sizes it to that layer; keep it filling the view (the display layer does not clip its sublayers).
            let layerOrigin = engine.displayLayer.frame.origin
            for indicator in engine.displayLayer.sublayers ?? []
            where "\(type(of: indicator))".contains("PictureInPictureIndicator") {
                indicator.frame = CGRect(origin: CGPoint(x: -layerOrigin.x, y: -layerOrigin.y), size: bounds.size)
                for part in indicator.sublayers ?? [] { part.frame = indicator.bounds }
                indicator.setNeedsLayout()
            }
        }

        var needsRedraw = false
        if let renderer = engine.metalRenderer {
            let metalLayer = renderer.metalLayer
            // On whole pixels: a fractional frame makes the compositor resample the drawable, softening the picture.
            // The drawable covers only the visible part, so a zoomed picture never costs more than the view.
            let metalFrame = backingAlignedRect(visibleFrame, options: .alignAllEdgesNearest)
            let drawableSize = CGSize(
                width: (metalFrame.width * scale).rounded(), height: (metalFrame.height * scale).rounded())
            let sourceRect = videoLayout.sourceRect(for: viewRect(metalFrame))
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

    /// `rect` with its origin moved between the top left (`VideoLayout`) and this view's bottom left; its own inverse.
    private func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Accepts files only when the host handles them, so an embedding host without drop handlers shows no copy cursor.
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard onFilesDrop != nil || onFileDrop != nil,
            sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
        else { return [] }
        return .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            !items.isEmpty
        else {
            return false
        }
        if let onFilesDrop {
            onFilesDrop(items)
        } else if let onFileDrop, let firstUrl = items.first {
            onFileDrop(firstUrl.path)
        } else {
            return false
        }
        return true
    }
}
