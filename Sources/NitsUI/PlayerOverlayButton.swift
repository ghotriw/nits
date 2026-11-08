import Foundation

/// A button of the host's over the picture (a like, a close), in a corner the player leaves free: the top trailing one
/// or the bottom leading one. Unlike an action button (`PlaybackActionButton`) it has no span of the timeline: it is
/// there until the host takes it away, through loads too. The player only shows it and reports its `id` when pressed
/// (`PlayerSession.onOverlayButton`); a button that changes with what it did (a filled heart) is replaced by the host.
public struct PlayerOverlayButton: Sendable, Identifiable, Equatable {
    public enum Placement: Sendable, Equatable {
        /// The top trailing corner, below the windowed player's top bar, beside an open side panel.
        case topTrailing
        /// The bottom leading corner, above the control bar.
        case bottomLeading
    }

    public enum Visibility: Sendable, Equatable {
        /// Comes and goes with the control bar.
        case withControls
        /// Stays on screen while the controls are hidden too.
        case always
    }

    /// Reported back to the host when the button is pressed; unique among the host's overlay buttons.
    public let id: String
    /// The button's label, already localized by the host: the tooltip and accessibility label of an icon, the text
    /// of a button without one.
    public var title: String
    /// An SF Symbol; `nil` shows `title` as the button's text.
    public var systemImage: String?
    public var placement: Placement
    public var visibility: Visibility
    public var isEnabled: Bool

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        placement: Placement = .topTrailing,
        visibility: Visibility = .withControls,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.placement = placement
        self.visibility = visibility
        self.isEnabled = isEnabled
    }
}
