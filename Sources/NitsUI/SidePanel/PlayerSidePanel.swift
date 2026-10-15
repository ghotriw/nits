import CoreGraphics

/// Panels that slide in from the trailing edge of the player. Only one is open at a time.
public enum PlayerSidePanel: Sendable, Equatable {
    case playlist
    case quickSettings

    public var width: CGFloat {
        switch self {
        case .playlist:
            return 350
        case .quickSettings:
            return 330
        }
    }
}
