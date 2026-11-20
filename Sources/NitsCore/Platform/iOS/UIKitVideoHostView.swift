#if os(iOS)
    import UIKit

    /// The view showing the engine's video layers on iOS. A compiling stub until the iOS platform layer task: it holds the
    /// layers but has no screen, so no display link.
    public final class UIKitVideoHostView: UIView {
        private let engine: PlayerEngine
        private let layers: VideoLayers

        public init(engine: PlayerEngine) {
            self.engine = engine
            self.layers = VideoLayers(engine: engine, contentsScale: 2.0, originIsBottomLeft: false)
            super.init(frame: .zero)
            layer.addSublayer(layers.rootLayer)
        }

        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// The part of this view the picture covers (in its coordinates), for hosts that draw over the video.
        public var presentedVideoRect: CGRect { layers.presentedVideoRect }

        /// Whether the picture is larger than the view (zoomed or filled).
        public var canPanVideo: Bool { layers.canPanVideo }

        public func updateMode() {
            layers.updateMode()
            setNeedsLayout()
        }
    }

    extension UIKitVideoHostView: VideoHost {
        public var screenEDRHeadroom: CGFloat { 1.0 }

        public func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink? { nil }

        public func makeScreenDisplayLink(target: Any, selector: Selector) -> CADisplayLink? { nil }

        public var screenIdentity: AnyHashable? { nil }

        public var maximumFramesPerSecond: Int { 60 }

        public func setNeedsVideoLayout(immediately: Bool) {
            setNeedsLayout()
            if immediately { layoutIfNeeded() }
        }

        public var visibilityDescription: String { "none" }
    }
#endif
