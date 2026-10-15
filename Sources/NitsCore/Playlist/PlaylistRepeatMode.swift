import Foundation

/// Defines repeat behavior for playlist playback.
public enum PlaylistRepeatMode: String, Sendable, CaseIterable, Identifiable {
    /// Play through the playlist and stop at the end.
    case off = "Off"
    /// Loop through all items continuously.
    case all = "Repeat All"
    /// Repeat the current item indefinitely.
    case one = "Repeat Current"

    public var id: String { rawValue }

    /// SF Symbol icon representation for the repeat mode.
    public var iconName: String {
        switch self {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    /// User-friendly title.
    public var title: String {
        switch self {
        case .off:
            return "Repeat: Off"
        case .all:
            return "Repeat: All"
        case .one:
            return "Repeat: One"
        }
    }

    /// Advances to the next repeat mode in sequence: off -> all -> one -> off.
    public var next: PlaylistRepeatMode {
        switch self {
        case .off:
            return .all
        case .all:
            return .one
        case .one:
            return .off
        }
    }
}

/// What playlist items are sorted by; the direction is chosen separately.
public enum PlaylistSortKey: String, Sendable, CaseIterable, Identifiable {
    case title = "Title"
    case filename = "Filename"
    case duration = "Duration"

    public var id: String { rawValue }

    /// Describes a direction for this key, e.g. "A–Z" or "Shortest First".
    public func directionTitle(ascending: Bool) -> String {
        switch self {
        case .title, .filename:
            return ascending ? "A–Z" : "Z–A"
        case .duration:
            return ascending ? "Shortest First" : "Longest First"
        }
    }
}
