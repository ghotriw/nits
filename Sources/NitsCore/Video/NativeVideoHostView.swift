import AVFoundation
import AppKit

public final class NativeVideoHostView: NSView {
    public var onFileDrop: ((String) -> Void)?
    public var onFilesDrop: (([URL]) -> Void)?
    private let engine: PlayerEngine
    private let rootLayer = CALayer()

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

    private func setup() {
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        rootLayer.backgroundColor = NSColor.black.cgColor

        // Add AVSampleBufferDisplayLayer
        engine.displayLayer.backgroundColor = NSColor.black.cgColor
        engine.displayLayer.frame = rootLayer.bounds
        engine.displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.addSublayer(engine.displayLayer)

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
        let videoFrame = aspectFitVideoFrame()

        // No implicit animation: the video layers would lag behind the window being resized.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch engine.pictureInPictureLayerGeometry {
        case nil:
            engine.displayLayer.frame = bounds
        case .pipWindow(let size):
            engine.displayLayer.frame = CGRect(origin: .zero, size: size)
        case .videoRect:
            engine.displayLayer.frame = videoFrame
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

        var drawableSizeChanged = false
        if let metalLayer = engine.metalRenderer?.metalLayer {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            // On whole pixels: a fractional frame makes the compositor resample the drawable, softening the picture.
            let metalFrame = backingAlignedRect(videoFrame, options: .alignAllEdgesNearest)
            let drawableSize = CGSize(
                width: (metalFrame.width * scale).rounded(), height: (metalFrame.height * scale).rounded())
            drawableSizeChanged = metalLayer.drawableSize != drawableSize
            metalLayer.contentsScale = scale
            metalLayer.frame = metalFrame
            metalLayer.drawableSize = drawableSize
        }
        CATransaction.commit()

        // While playing, the next frame comes within a frame duration; a redraw would only compete with the display
        // link for drawables.
        if drawableSizeChanged, engine.isMetalLayerVisible, !engine.isPlaying {
            engine.metalRenderer?.redrawLastFrame()
        }
    }

    /// Aspect-fit frame of the video in the view, matching AVSampleBufferDisplayLayer `resizeAspect` (SAR / DAR).
    private func aspectFitVideoFrame() -> CGRect {
        let videoAspect = CGFloat(engine.displayAspectRatio > 0 ? engine.displayAspectRatio : 16.0 / 9.0)
        let viewAspect = bounds.width / max(bounds.height, 1)
        if viewAspect > videoAspect {
            // View is wider than video: letterbox on sides
            let targetWidth = bounds.height * videoAspect
            let offsetX = (bounds.width - targetWidth) / 2.0
            return CGRect(x: offsetX, y: 0, width: targetWidth, height: bounds.height)
        } else {
            // View is taller than video: letterbox on top/bottom
            let targetHeight = bounds.width / videoAspect
            let offsetY = (bounds.height - targetHeight) / 2.0
            return CGRect(x: 0, y: offsetY, width: bounds.width, height: targetHeight)
        }
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
