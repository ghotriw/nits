import Foundation
import Observation

/// Holds the configuration for ordering and visibility of player control bar items.
@Observable
@MainActor
public final class ControlsConfiguration {
    public static let userDefaultsKey = "player.controls.items.v1"

    /// Default item sequence matching original layout.
    public static let defaultItems: [ControlBarItem] = [
        .playlistShuffle,
        .playlistPrevious,
        .playPause,
        .playlistNext,
        .playlistRepeat,
        .timeline,
        .volume,
        .audioTrack,
        .subtitleTrack,
        .playlist,
        .quickSettings,
    ]

    /// Shared instance used across the app to ensure live sync between Settings and player windows.
    public static let shared = ControlsConfiguration()

    /// Flag indicating if the user currently has the Controls settings tab open.
    /// When true, players should keep their controls overlay permanently visible.
    public var isSettingsCustomizingControls: Bool = false

    /// Ordered list of active control bar items.
    public var items: [ControlBarItem] {
        didSet {
            save()
        }
    }

    public init() {
        if let data = UserDefaults.standard.string(forKey: Self.userDefaultsKey),
            let saved = Self.decode(from: data)
        {
            self.items = saved
        } else {
            self.items = Self.defaultItems
        }
    }

    /// Reloads current values from UserDefaults.
    public func reload() {
        if let data = UserDefaults.standard.string(forKey: Self.userDefaultsKey),
            let saved = Self.decode(from: data)
        {
            self.items = saved
        } else {
            self.items = Self.defaultItems
        }
    }

    /// Checks if a specific item is currently present in the active items list.
    public func isEnabled(_ item: ControlBarItem) -> Bool {
        items.contains(item)
    }

    /// Toggles visibility of a specific item while maintaining relative placement or appending.
    public func setEnabled(_ item: ControlBarItem, isEnabled: Bool) {
        if isEnabled {
            if !items.contains(item) {
                // Insert back at original default order relative position
                let defaultIndex = Self.defaultItems.firstIndex(of: item) ?? Self.defaultItems.count
                var inserted = false
                for (idx, existing) in items.enumerated() {
                    let existingDefaultIdx = Self.defaultItems.firstIndex(of: existing) ?? 0
                    if existingDefaultIdx > defaultIndex {
                        items.insert(item, at: idx)
                        inserted = true
                        break
                    }
                }
                if !inserted {
                    items.append(item)
                }
            }
        } else {
            // Cannot disable required controls like play/pause and timeline
            guard !item.isRequired else { return }
            items.removeAll { $0 == item }
        }
    }

    /// Reorders items via standard move operation (e.g. from SwiftUI List .onMove).
    public func move(from offsets: IndexSet, to offset: Int) {
        items.move(fromOffsets: offsets, toOffset: offset)
    }

    /// Resets control layout back to default state.
    public func resetToDefaults() {
        items = Self.defaultItems
    }

    private func save() {
        let rawValues = items.map { $0.rawValue }
        if let data = try? JSONEncoder().encode(rawValues),
            let string = String(data: data, encoding: .utf8)
        {
            UserDefaults.standard.set(string, forKey: Self.userDefaultsKey)
        }
    }

    private static func decode(from jsonString: String) -> [ControlBarItem]? {
        guard let data = jsonString.data(using: .utf8),
            let rawValues = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        var decodedItems = rawValues.compactMap { ControlBarItem(rawValue: $0) }

        // Ensure required items are never completely missing
        for requiredItem in ControlBarItem.allCases where requiredItem.isRequired {
            if !decodedItems.contains(requiredItem) {
                decodedItems.append(requiredItem)
            }
        }
        return decodedItems
    }
}
