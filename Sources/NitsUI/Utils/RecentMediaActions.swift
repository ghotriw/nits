import AppKit
import NitsCore

@MainActor
public enum RecentMediaActions {
    /// Clears both in-app recent media list and macOS Dock recent documents.
    public static func clearAll() {
        RecentMediaStore.shared.clearAll()
    }
}
