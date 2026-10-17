import Foundation

/// A button the host shows over the video for a span of the timeline ("Skip Intro", "Next Episode").
///
/// The host decides where the spans are and what pressing the button does: the player only shows the button while
/// playback is inside `start..<end` and reports its `id` through `onActionButton` when it is pressed.
public struct PlaybackActionButton: Sendable, Identifiable, Equatable {
    /// Reported back to the host when the button is pressed.
    public let id: String
    /// The button's label, already localized by the host.
    public let title: String
    /// Seconds on the media timeline where the button appears.
    public let start: Double
    /// Seconds where it disappears again (exclusive); `nil` keeps it up to the end of the media.
    public let end: Double?
    /// Whether the player may press the button by itself when the user enabled auto-press. Hosts turn it off for
    /// actions their own settings keep manual (e.g. "Next Episode" without auto-play).
    public let allowsAutoPress: Bool

    public init(id: String, title: String, start: Double, end: Double? = nil, allowsAutoPress: Bool = true) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allowsAutoPress = allowsAutoPress
    }

    /// Whether `time` falls inside the button's span.
    public func contains(_ time: Double) -> Bool {
        guard time.isFinite, time >= start else { return false }
        guard let end else { return true }
        return time < end
    }

    /// The button to show at `time`: of the buttons whose span contains it, the one that started last, so a
    /// span nested in a longer one (a recap inside a cold open) wins while it lasts.
    public static func active(in buttons: [PlaybackActionButton], at time: Double) -> PlaybackActionButton? {
        var active: PlaybackActionButton?
        for button in buttons where button.contains(time) {
            if let current = active, current.start > button.start { continue }
            active = button
        }
        return active
    }
}
