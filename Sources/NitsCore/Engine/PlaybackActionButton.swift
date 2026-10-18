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
    /// actions that shouldn't happen without the user (e.g. "Next Episode", which would cut the credits short).
    public let allowsAutoPress: Bool
    /// A second line under the title (e.g. "S2 · E5 · The Episode Name"), already localized by the host.
    public let subtitle: String?
    /// A 16:9 picture of what the button leads to (e.g. the next episode's thumbnail). The URL carries any
    /// authentication itself: it is fetched without headers.
    public let artworkURL: URL?

    public init(
        id: String,
        title: String,
        start: Double,
        end: Double? = nil,
        allowsAutoPress: Bool = true,
        subtitle: String? = nil,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allowsAutoPress = allowsAutoPress
        self.subtitle = subtitle
        self.artworkURL = artworkURL
    }

    /// Whether the button shows as an "Up Next" card (artwork, title and subtitle) rather than a plain title.
    public var isCard: Bool {
        subtitle != nil || artworkURL != nil
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
