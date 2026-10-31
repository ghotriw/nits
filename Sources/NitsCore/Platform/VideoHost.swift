import Foundation
import QuartzCore

/// The platform view showing the engine's video layers (`NativeVideoHostView` on macOS), as far as the engine
/// drives it: the display link follows it, its screen decides the render mode, and geometry changes lay it out again.
///
/// The view owns a `VideoLayers` and makes its `rootLayer` its own layer. It calls `attachDisplayLink(to:)` once it
/// is on a screen, and `videoHostScreenDidChange()` when it moves to another screen or that screen's parameters
/// change (display mode, refresh rate, HDR, scale); the engine observes no screens itself.
///
/// Each platform provides its view in `Platform/<os>/`, along with `PlatformScreen`, which stands in for the main
/// screen until a view is attached.
@MainActor
public protocol VideoHost: AnyObject {
    /// How far above SDR white this view's screen shows now: `1` on an SDR screen. Above
    /// `PlayerEngine.minimumHDRDisplayHeadroom` the engine leaves HDR to the system instead of tone-mapping it.
    var screenEDRHeadroom: CGFloat { get }
    /// A link firing at the refresh of the screen this view is on, following it across screens; it may stop
    /// while the view is hidden. `nil` when there is nothing to present on.
    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink?
    /// A link for this view's screen as a whole, which keeps firing while the view is hidden (Picture in Picture
    /// usually hides its window).
    func makeScreenDisplayLink(target: Any, selector: Selector) -> CADisplayLink?
    /// Identifies the screen this view is on, the same for as long as it stays there; `nil` off screen.
    var screenIdentity: AnyHashable? { get }
    /// Highest refresh rate of this view's screen.
    var maximumFramesPerSecond: Int { get }
    /// Lays the video layers out again; `immediately` also when the view is hidden and would not lay out on its own.
    func setNeedsVideoLayout(immediately: Bool)
    /// How visible the view is, for diagnostics ("visible", "occluded", "none").
    var visibilityDescription: String { get }
}
