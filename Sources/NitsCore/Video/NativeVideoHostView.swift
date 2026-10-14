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
        engine.displayLayer.frame = bounds

        guard let metalLayer = engine.metalRenderer?.metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale

        // Calculate aspect-fit frame matching AVSampleBufferDisplayLayer resizeAspect (respecting SAR / DAR)
        let videoAspect = CGFloat(engine.displayAspectRatio > 0 ? engine.displayAspectRatio : 16.0 / 9.0)
        let viewAspect = bounds.width / max(bounds.height, 1)

        var targetFrame = bounds
        if viewAspect > videoAspect {
            // View is wider than video: letterbox on sides
            let targetWidth = bounds.height * videoAspect
            let offsetX = (bounds.width - targetWidth) / 2.0
            targetFrame = CGRect(x: offsetX, y: 0, width: targetWidth, height: bounds.height)
        } else {
            // View is taller than video: letterbox on top/bottom
            let targetHeight = bounds.width / videoAspect
            let offsetY = (bounds.height - targetHeight) / 2.0
            targetFrame = CGRect(x: 0, y: offsetY, width: bounds.width, height: targetHeight)
        }

        metalLayer.frame = targetFrame
        metalLayer.drawableSize = CGSize(width: targetFrame.width * scale, height: targetFrame.height * scale)
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
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
        } else if let firstUrl = items.first {
            onFileDrop?(firstUrl.path)
        }
        return true
    }
}
