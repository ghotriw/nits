import CoreGraphics

/// Panels that slide in from the trailing edge of the player. Only one is open at a time.
public enum PlayerSidePanel: Sendable, Equatable {
    case playlist
    /// The chapters tab of the playlist panel; only offered when the media has chapters.
    case chapters
    case quickSettings

    /// A tab of the playlist panel (`.playlist` or `.chapters`).
    public var isPlaylistPanelTab: Bool {
        self == .playlist || self == .chapters
    }

    public var width: CGFloat {
        switch self {
        case .playlist, .chapters:
            return 350
        case .quickSettings:
            return 330
        }
    }
}
