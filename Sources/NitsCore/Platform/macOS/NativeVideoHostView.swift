#if os(macOS)
    import AVFoundation
    import AppKit

    public final class NativeVideoHostView: NSView {
        public var onFileDrop: ((String) -> Void)?
        public var onFilesDrop: (([URL]) -> Void)?
        private let engine: PlayerEngine
        private let layers: VideoLayers

        public init(engine: PlayerEngine) {
            self.engine = engine
            self.layers = VideoLayers(
                engine: engine, contentsScale: NSScreen.main?.backingScaleFactor ?? 2.0, originIsBottomLeft: true)
            super.init(frame: .zero)
            registerForDraggedTypes([.fileURL])
            wantsLayer = true
        }

        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public override func makeBackingLayer() -> CALayer {
            return layers.rootLayer
        }

        /// The part of this view the picture covers (in its coordinates), for hosts that draw over the video; updated
        /// on every layout.
        public var presentedVideoRect: CGRect { layers.presentedVideoRect }

        /// Whether the picture is larger than the view (zoomed or filled), so a host can let drags move it.
        public var canPanVideo: Bool { layers.canPanVideo }

        /// A window movable by its background doesn't move from a drag on a picture that can be panned.
        public override var mouseDownCanMoveWindow: Bool {
            !canPanVideo
        }

        public func updateMode() {
            layers.updateMode()
            needsLayout = true
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
                engine.attachDisplayLink(to: self)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowDidChangeScreen(_ notification: Notification) {
            engine.videoHostScreenDidChange()
        }

        @objc private func screenParametersDidChange(_ notification: Notification) {
            engine.videoHostScreenDidChange()
        }

        public override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            engine.videoHostScreenDidChange()
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            engine.metalRenderer?.metalLayer.contentsScale = scale
            needsLayout = true
        }

        public override func layout() {
            super.layout()
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            layers.layout(bounds: bounds, backingScale: scale) {
                backingAlignedRect($0, options: .alignAllEdgesNearest)
            }
            layOutPictureInPictureIndicator()
        }

        /// AVKit draws its "playing in picture in picture" placeholder as a sublayer of the display layer and sizes it
        /// to that layer; keep it filling the view (the display layer does not clip its sublayers).
        private func layOutPictureInPictureIndicator() {
            guard engine.pictureInPictureLayerGeometry != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let layerOrigin = engine.displayLayer.frame.origin
            for indicator in engine.displayLayer.sublayers ?? []
            where "\(type(of: indicator))".contains("PictureInPictureIndicator") {
                indicator.frame = CGRect(origin: CGPoint(x: -layerOrigin.x, y: -layerOrigin.y), size: bounds.size)
                for part in indicator.sublayers ?? [] { part.frame = indicator.bounds }
                indicator.setNeedsLayout()
            }
            CATransaction.commit()
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

    extension NativeVideoHostView: VideoHost {
        public var screenEDRHeadroom: CGFloat {
            (window?.screen ?? NSScreen.main)?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        }

        public func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
            displayLink(target: target, selector: selector)
        }

        public func makeScreenDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
            (window?.screen ?? NSScreen.main)?.displayLink(target: target, selector: selector)
        }

        public var maximumFramesPerSecond: Int {
            (window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        }

        public func setNeedsVideoLayout(immediately: Bool) {
            needsLayout = true
            if immediately { layoutSubtreeIfNeeded() }
        }

        public var visibilityDescription: String {
            guard let window else { return "none" }
            return window.occlusionState.contains(.visible) ? "visible" : "occluded"
        }
    }
#endif
