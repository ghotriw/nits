#if os(iOS)
    import UIKit

    /// The view showing the engine's video layers on iOS: a bare canvas, no controls. Its screen decides the display
    /// link and the render mode, so it tells the engine when it moves to a window or its screen changes.
    public final class UIKitVideoHostView: UIView {
        private let engine: PlayerEngine
        private let layers: VideoLayers

        public init(engine: PlayerEngine) {
            self.engine = engine
            self.layers = VideoLayers(engine: engine, contentsScale: 2.0, originIsBottomLeft: false)
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(layers.rootLayer)
            registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _) in
                view.engine.videoHostScreenDidChange()
                view.setNeedsLayout()
            }
        }

        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// The part of this view the picture covers (in its coordinates), for hosts that draw over the video; updated
        /// on every layout.
        public var presentedVideoRect: CGRect { layers.presentedVideoRect }

        /// Whether the picture is larger than the view (zoomed or filled), so a host can let drags move it.
        public var canPanVideo: Bool { layers.canPanVideo }

        /// A change of the video geometry (fit, fill, zoom, pan) lays the picture out again.
        public func updateMode() {
            layers.updateMode()
            setNeedsLayout()
        }

        private var screen: UIScreen? { window?.windowScene?.screen }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: UIScreen.modeDidChangeNotification, object: nil)
            guard window != nil else { return }
            // A display mode change keeps the view on the same screen, so nothing else would tell the engine.
            NotificationCenter.default.addObserver(
                self, selector: #selector(screenModeDidChange(_:)), name: UIScreen.modeDidChangeNotification,
                object: nil)
            engine.attachDisplayLink(to: self)
            setNeedsLayout()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func screenModeDidChange(_ notification: Notification) {
            engine.videoHostScreenDidChange()
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let pixelScale = scale > 0 ? scale : 2.0
            engine.metalRenderer?.metalLayer.contentsScale = pixelScale
            layers.layout(bounds: bounds, backingScale: pixelScale) { rect in
                CGRect(
                    x: (rect.minX * pixelScale).rounded() / pixelScale,
                    y: (rect.minY * pixelScale).rounded() / pixelScale,
                    width: (rect.width * pixelScale).rounded() / pixelScale,
                    height: (rect.height * pixelScale).rounded() / pixelScale)
            }
        }
    }

    extension UIKitVideoHostView: VideoHost {
        public var screenEDRHeadroom: CGFloat {
            screen?.potentialEDRHeadroom ?? 1.0
        }

        public func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
            screen?.displayLink(withTarget: target, selector: selector)
                ?? PlatformScreen.makeMainDisplayLink(target: target, selector: selector)
        }

        public func makeScreenDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
            makeDisplayLink(target: target, selector: selector)
        }

        public var screenIdentity: AnyHashable? {
            screen.map { AnyHashable(ObjectIdentifier($0)) }
        }

        public var maximumFramesPerSecond: Int {
            screen?.maximumFramesPerSecond ?? PlatformScreen.mainMaximumFramesPerSecond ?? 60
        }

        public func setNeedsVideoLayout(immediately: Bool) {
            setNeedsLayout()
            if immediately { layoutIfNeeded() }
        }

        public var visibilityDescription: String {
            guard let scene = window?.windowScene else { return "none" }
            switch scene.activationState {
            case .foregroundActive: return "visible"
            case .foregroundInactive: return "inactive"
            case .background: return "occluded"
            case .unattached: return "none"
            @unknown default: return "none"
            }
        }
    }
#endif
