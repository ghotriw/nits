import NitsCore
import Observation

/// When the action button ("Skip Intro") is on screen and when it presses itself, driven by the playback position.
///
/// On entering a button's span the button stays up for `displayDuration` seconds of playback, then only shows with
/// the controls. With auto-press it fills up over that time and presses itself at the end. The time is playback
/// time, so the countdown stops on pause, and a seek restarts it. Pressing or dismissing the button hides it for the
/// rest of its span; leaving the span and coming back brings it back.
@Observable
@MainActor
public final class ActionButtonPresenter {
    /// Position steps this long or longer, or any step back, are seeks rather than playback (as a backstop: seeks
    /// already come with `isPlaying` off). Updates come every 50 ms while playing, so this leaves room for fast
    /// playback rates and a late tick.
    static let maxPlaybackStep: Double = 1.0
    /// Steps back this small are clock jitter (a resume re-anchoring the clock), not a seek: they neither count nor
    /// restart the countdown.
    static let backwardJitterTolerance: Double = 0.25

    /// Seconds of playback the button stays up on its own.
    public var displayDuration: Double = 8.0
    /// Whether the button presses itself when `displayDuration` runs out (if the button allows it).
    public var autoPress: Bool = false
    /// Whether the player controls are on screen; after its own time the button shows only with them.
    public var areControlsVisible: Bool = false

    /// Seconds of playback since the button appeared, or since the last seek inside its span.
    public private(set) var elapsed: Double = 0
    /// The button of the span playback is in, pressed and dismissed or not.
    private var entry: PlaybackActionButton?
    /// Pressed or dismissed: hidden until playback leaves the span.
    private var isResolved = false
    @ObservationIgnored private var lastTime: Double?

    public init() {}

    /// The button to offer: `nil` outside every span and once pressed or dismissed for this one.
    public var button: PlaybackActionButton? {
        isResolved ? nil : entry
    }

    /// Whether the button is still within its own display time.
    public var isProminent: Bool {
        button != nil && elapsed < displayDuration
    }

    /// Whether the button is on screen.
    public var isVisible: Bool {
        button != nil && (isProminent || areControlsVisible)
    }

    /// Whether the button will press itself when its display time runs out.
    public var isAutoPressArmed: Bool {
        autoPress && button?.allowsAutoPress == true
    }

    /// How far the auto-press countdown has run (0...1); `nil` when there is none on screen.
    public var autoPressProgress: Double? {
        guard isAutoPressArmed, isProminent, displayDuration > 0 else { return nil }
        return min(1, elapsed / displayDuration)
    }

    /// Feeds the playback position and the engine's `activeActionButton`. `isPlaying` is whether the position moves
    /// by playback (playing, not seeking): only then does it count, so scrubbing and frame steps on pause don't.
    /// Returns the button to press when its auto-press countdown has just run out.
    public func update(active: PlaybackActionButton?, at time: Double, isPlaying: Bool) -> PlaybackActionButton? {
        // Outside every span on most ticks: leave the observed state untouched.
        if active == nil && entry == nil { return nil }
        guard let active, active.id == entry?.id else {
            enter(active, at: time)
            return nil
        }
        // The host may replace the button list mid-span; keep the state but take its new title.
        if active != entry {
            entry = active
        }
        if let lastTime, !isPlaying {
            // Scrubbing, a seek or a frame step: not playback. Anything past jitter restarts the countdown.
            let step = time - lastTime
            if abs(step) > Self.backwardJitterTolerance {
                elapsed = 0
            }
            self.lastTime = time
        } else if let lastTime {
            let step = time - lastTime
            if step > 0 && step < Self.maxPlaybackStep {
                elapsed += step
                self.lastTime = time
            } else if step < -Self.backwardJitterTolerance || step >= Self.maxPlaybackStep {
                elapsed = 0
                self.lastTime = time
            }
        } else {
            lastTime = time
        }
        guard !isResolved, isAutoPressArmed, elapsed >= displayDuration else { return nil }
        isResolved = true
        return active
    }

    /// Takes the button for a press by the user, hiding it; `nil` when none is offered.
    public func press() -> PlaybackActionButton? {
        guard let button else { return nil }
        isResolved = true
        return button
    }

    /// Hides the button for the rest of its span and stops its countdown.
    public func dismiss() {
        guard entry != nil else { return }
        isResolved = true
    }

    /// Forgets the span and whether its button was pressed or dismissed, for new media.
    public func reset() {
        enter(nil, at: 0)
    }

    private func enter(_ button: PlaybackActionButton?, at time: Double) {
        entry = button
        isResolved = false
        elapsed = 0
        lastTime = button == nil ? nil : time
    }
}
