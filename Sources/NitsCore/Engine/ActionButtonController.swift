import Foundation
import Observation

/// What `ActionButtonController` needs of the player it shows buttons for; `PlayerEngine` is one, held weakly.
@MainActor
protocol ActionButtonHost: AnyObject {
    var currentTime: Double { get }
    var isLoaded: Bool { get }
    func seek(to seconds: Double)
}

/// The action buttons of the media ("Skip Intro", "Next Episode"): the host's and the resolver's (SponsorBlock
/// segments), and the one whose span playback is in. The player tells it when media starts loading
/// (`mediaWillLoad`), when the resolver's buttons arrive (`setResolved`), when a load or a stop takes the host's
/// (`reset`), and when the position or the loaded state changes (`updateActive`).
@MainActor
@Observable
public final class ActionButtonController {
    /// The host's buttons and the resolver's, the host's replacing a resolver's with the same `id`.
    public var buttons: [PlaybackActionButton] { buttonSet.combined }
    private var buttonSet = ActionButtonSet() {
        didSet {
            updateActive()
        }
    }
    /// The button whose span contains the position; `nil` outside every span and while no media is loaded.
    public private(set) var active: PlaybackActionButton?
    /// Bumped by every load. Per-media UI state (a dismissed action button) resets on it: a load from a position inside
    /// a span to the same position in the next media never shows `active` change.
    public private(set) var loadGeneration = 0
    /// Called with the button's `id` when an action button is pressed, by the user or by auto-press.
    public var onPress: ((_ id: String) -> Void)?
    @ObservationIgnored weak var host: (any ActionButtonHost)?

    public init() {}

    /// Replaces the host's buttons of the media playing now, keeping the resolver's.
    public func setHostButtons(_ buttons: [PlaybackActionButton]) {
        buttonSet.setHost(buttons)
    }

    /// Performs `button`: if `button.seeksToEnd` and it has an `end`, seeks to `end`; otherwise reports the press to
    /// the host (`onPress`), letting the host decide what to do (e.g. Next Episode).
    public func perform(_ button: PlaybackActionButton) {
        guard let host, buttons.contains(where: { $0.id == button.id }) else { return }
        AppLog.info(.engine, "Action button '\(button.id)' pressed at \(host.currentTime)s")
        if button.seeksToEnd, let end = button.end {
            host.seek(to: end)
        } else {
            onPress?(button.id)
        }
    }

    func mediaWillLoad() {
        loadGeneration += 1
    }

    func setResolved(_ buttons: [PlaybackActionButton]) {
        buttonSet.setResolved(buttons)
    }

    /// Takes `host`'s buttons for new media, and none of the resolver's yet.
    func reset(host buttons: [PlaybackActionButton] = []) {
        buttonSet.reset(host: buttons)
    }

    func updateActive() {
        // A handful of buttons at most: a linear scan per tick is cheap. Write only on change, so observers of
        // `active` don't re-render at the time update rate.
        // Not while loading: the new media's buttons against the previous media's position.
        let active = host.flatMap { $0.isLoaded ? PlaybackActionButton.active(in: buttons, at: $0.currentTime) : nil }
        if active != self.active {
            self.active = active
        }
    }
}
