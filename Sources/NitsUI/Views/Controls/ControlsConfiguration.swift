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
        .chapters,
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

    /// Items the host app doesn't offer, e.g. the playlist's (`.playlist`, `.playlistRepeat`, `.playlistShuffle`) in a
    /// media server client that keeps its own queue. They stay off the control bar and out of the Controls settings
    /// whatever the saved layout says, and the playlist panel and its menu item go with `.playlist`. Not saved: the
    /// host sets it at launch.
    public var unavailableItems: Set<ControlBarItem> = []

    /// `items` the control bar shows: without `unavailableItems`.
    public var visibleItems: [ControlBarItem] {
        items.filter(isAvailable)
    }

    public func isAvailable(_ item: ControlBarItem) -> Bool {
        !unavailableItems.contains(item)
    }

    /// Whether `item` is on the control bar: in the layout and available.
    public func isVisible(_ item: ControlBarItem) -> Bool {
        isEnabled(item) && isAvailable(item)
    }

    /// Where the layout persists; `nil` keeps it in memory (tests, previews).
    private let userDefaults: UserDefaults?

    public init(userDefaults: UserDefaults? = .standard) {
        self.userDefaults = userDefaults
        self.items = Self.load(from: userDefaults) ?? Self.defaultItems
    }

    /// Reloads current values from UserDefaults.
    public func reload() {
        items = Self.load(from: userDefaults) ?? Self.defaultItems
    }

    private static func load(from userDefaults: UserDefaults?) -> [ControlBarItem]? {
        userDefaults?.string(forKey: userDefaultsKey).flatMap(decode(from:))
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

    /// Reorders `visibleItems` via standard move operation (e.g. from SwiftUI List .onMove, offsets into the list the
    /// Controls settings show); unavailable items keep their slots in `items`.
    public func move(from offsets: IndexSet, to offset: Int) {
        var visible = visibleItems
        visible.move(fromOffsets: offsets, toOffset: offset)
        var reordered = visible.makeIterator()
        items = items.map { isAvailable($0) ? reordered.next() ?? $0 : $0 }
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
            userDefaults?.set(string, forKey: Self.userDefaultsKey)
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
