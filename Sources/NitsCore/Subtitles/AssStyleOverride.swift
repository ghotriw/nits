import Foundation

/// How much of the user's subtitle style replaces an ASS script's own on its dialogue. libass decides what is
/// dialogue: lines without explicit positioning, so typeset signs keep the script's style in every mode.
public enum AssStyleOverride: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The script's styles as authored.
    case none
    /// The user's font and size.
    case font
    /// The user's font, size, colors and background.
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "As Authored"
        case .font: "Font and Size"
        case .full: "Font, Size and Colors"
        }
    }
}
