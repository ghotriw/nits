import Foundation

/// What a host that keeps its own queue (a media server client's series) has around the media playing now; see
/// `PlayerEngine.onTrackNavigation`.
public struct TrackNavigation: Sendable, Equatable {
    /// The host has an item after this one.
    public var hasNext: Bool
    /// The host has an item before this one. Without one, Previous still restarts the media.
    public var hasPrevious: Bool
    /// The next item's title, already localized by the host; shown when the user moves to it.
    public var nextTitle: String?
    /// The previous item's title; see `nextTitle`.
    public var previousTitle: String?

    public init(
        hasNext: Bool = false, hasPrevious: Bool = false, nextTitle: String? = nil, previousTitle: String? = nil
    ) {
        self.hasNext = hasNext
        self.hasPrevious = hasPrevious
        self.nextTitle = nextTitle
        self.previousTitle = previousTitle
    }
}

/// Which way the user asked to move through the host's queue.
public enum TrackNavigationDirection: Sendable, Equatable {
    case next
    case previous
}
