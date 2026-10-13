import Foundation
import Observation

/// Manages playlist items, navigation, repeat/shuffle states, and filtering.
/// Fully decoupled from UI and designed to be observed via Swift Observation.
@Observable
@MainActor
public final class PlaylistManager: Sendable {
    public private(set) var items: [PlaylistItem] = [] {
        didSet {
            recomputeFilteredItems()
        }
    }
    public private(set) var currentIndex: Int? = nil
    public var repeatMode: PlaylistRepeatMode = .off
    public private(set) var isShuffled: Bool = false
    public var autoPlayNext: Bool = true
    public var searchQuery: String = "" {
        didSet {
            recomputeFilteredItems()
        }
    }

    /// Whether the playlist is currently loading/parsing media tracks asynchronously.
    public private(set) var isLoading: Bool = false

    /// Items filtered by the current `searchQuery` (cached for performance).
    public private(set) var filteredItems: [PlaylistItem] = []

    /// Optional persistence store for playlist repeat & shuffle preferences.
    @ObservationIgnored
    private let userDefaults: UserDefaults?

    /// Callback invoked when the active playlist item changes.
    public var onCurrentItemChanged: ((PlaylistItem?) -> Void)?

    @ObservationIgnored
    private var folderScanTask: Task<Void, Never>? = nil

    /// Supported playlist file extensions.
    public static let playlistExtensions: Set<String> = PlaylistParser.supportedExtensions

    /// Supported media extensions for directory scanning.
    public static let mediaExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "flv", "ogv", "wmv",
        "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "alac", "aif", "aiff", "wma", "ape",
    ]

    /// Supported extensions for media files and playlist files.
    public static let supportedExtensions: Set<String> = mediaExtensions.union(playlistExtensions)

    public init(
        items: [PlaylistItem] = [],
        repeatMode: PlaylistRepeatMode = .off,
        isShuffled: Bool = false,
        autoPlayNext: Bool = true,
        userDefaults: UserDefaults? = nil
    ) {
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
        self.autoPlayNext = autoPlayNext
        self.userDefaults = userDefaults
        let indexedItems = items.enumerated().map { offset, item in
            var copy = item
            copy.originalIndex = offset
            return copy
        }
        if isShuffled && indexedItems.count > 1 {
            var shuffled = indexedItems
            let first = shuffled.remove(at: 0)
            shuffled.shuffle()
            shuffled.insert(first, at: 0)
            self.items = shuffled
        } else {
            self.items = indexedItems
        }
        recomputeFilteredItems()
    }

    private func recomputeFilteredItems() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filteredItems = items
        } else {
            filteredItems = items.filter { item in
                item.title.localizedCaseInsensitiveContains(trimmed)
                    || item.filename.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    /// Sets whether the playlist is currently performing an asynchronous load or network fetch.
    package func setIsLoading(_ loading: Bool) {
        self.isLoading = loading
    }

    // MARK: - Current Item & Status

    /// The currently selected/playing playlist item.
    public var currentItem: PlaylistItem? {
        guard let index = currentIndex, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// The active sequence of items used for navigation (respects search filter if active).
    public var activeSequence: [PlaylistItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? items : filteredItems
    }

    /// Whether there is a next track available to play (respects current search filter).
    public var hasNext: Bool {
        let sequence = activeSequence
        guard !sequence.isEmpty else { return false }
        guard let currentId = currentItem?.id,
            let activeIdx = sequence.firstIndex(where: { $0.id == currentId })
        else {
            // Current item is not in the filtered sequence: next item will be the first one in the filtered list
            return !sequence.isEmpty
        }

        if repeatMode == .one || repeatMode == .all {
            return true
        }
        return activeIdx < sequence.count - 1
    }

    /// Whether there is a previous track available to play (respects current search filter).
    public var hasPrevious: Bool {
        let sequence = activeSequence
        guard !sequence.isEmpty else { return false }
        guard let currentId = currentItem?.id,
            let activeIdx = sequence.firstIndex(where: { $0.id == currentId })
        else {
            // Current item is not in the filtered sequence: previous item will be the last one in the filtered list
            return !sequence.isEmpty
        }

        if repeatMode == .all {
            return true
        }
        return activeIdx > 0
    }

    // MARK: - Navigation

    /// Advances to the next item based on current index, search filter, and repeat mode.
    /// - Parameter isUserAction: If true (e.g. user pressed Next button or shortcut), advances to next item even if repeatMode is .one.
    @discardableResult
    public func playNext(isUserAction: Bool = false) -> PlaylistItem? {
        let sequence = activeSequence
        guard !sequence.isEmpty else { return nil }

        if repeatMode == .one && !isUserAction, let current = currentItem {
            return current
        }

        let targetItem: PlaylistItem?
        if let currentId = currentItem?.id,
            let activeIdx = sequence.firstIndex(where: { $0.id == currentId })
        {
            if activeIdx + 1 < sequence.count {
                targetItem = sequence[activeIdx + 1]
            } else if repeatMode == .all {
                targetItem = sequence[0]
            } else {
                targetItem = nil
            }
        } else {
            // Currently playing item is not in the filtered results: pick the first one from the filter
            targetItem = sequence[0]
        }

        guard let targetItem else {
            return nil
        }

        if let originalIndex = items.firstIndex(where: { $0.id == targetItem.id }) {
            currentIndex = originalIndex
        }
        onCurrentItemChanged?(targetItem)
        return targetItem
    }

    /// Moves to the previous item, or signals to restart the current track if played past threshold.
    public func playPrevious(
        restartThresholdSeconds: Double = 3.0,
        currentPlaybackTime: Double = 0.0
    ) -> (item: PlaylistItem?, shouldRestart: Bool) {
        // If played for more than threshold seconds, restart current track regardless of search filter
        if currentPlaybackTime > restartThresholdSeconds, let currentItem {
            return (currentItem, true)
        }

        let sequence = activeSequence
        guard !sequence.isEmpty else { return (nil, false) }

        let targetItem: PlaylistItem?
        var shouldRestart = false

        if let currentId = currentItem?.id,
            let activeIdx = sequence.firstIndex(where: { $0.id == currentId })
        {
            if activeIdx > 0 {
                targetItem = sequence[activeIdx - 1]
            } else if repeatMode == .all {
                targetItem = sequence[sequence.count - 1]
            } else {
                // At start of playlist/filter with repeat off: restart current track
                targetItem = sequence[activeIdx]
                shouldRestart = true
            }
        } else {
            // Currently playing item is not in the filtered results: jump to the last filtered item
            targetItem = sequence[sequence.count - 1]
        }

        guard let targetItem else {
            return (nil, false)
        }

        if !shouldRestart, let originalIndex = items.firstIndex(where: { $0.id == targetItem.id }) {
            currentIndex = originalIndex
            onCurrentItemChanged?(targetItem)
        }
        return (targetItem, shouldRestart)
    }

    /// Selects and plays an item by its index.
    @discardableResult
    public func selectItem(at index: Int) -> PlaylistItem? {
        guard items.indices.contains(index) else { return nil }
        currentIndex = index
        let item = items[index]
        onCurrentItemChanged?(item)
        return item
    }

    /// Selects and plays an item by its UUID.
    @discardableResult
    public func selectItem(id: UUID) -> PlaylistItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return selectItem(at: index)
    }

    // MARK: - Modification

    /// Replaces the playlist with the specified items, respecting shuffle state.
    /// If `isShuffled` is true, the item at `startIndex` is preserved at the top and remaining items are shuffled.
    public func replaceAll(items newItems: [PlaylistItem], startIndex: Int = 0) {
        clear()
        guard !newItems.isEmpty else { return }

        let clampedStartIndex = newItems.indices.contains(startIndex) ? startIndex : 0
        var indexedItems = newItems.enumerated().map { offset, item in
            var copy = item
            copy.originalIndex = offset
            return copy
        }

        if isShuffled && indexedItems.count > 1 {
            let active = indexedItems.remove(at: clampedStartIndex)
            indexedItems.shuffle()
            indexedItems.insert(active, at: 0)
            self.items = indexedItems
            self.currentIndex = 0
        } else {
            self.items = indexedItems
            self.currentIndex = clampedStartIndex
        }

        AppLog.info(.playlist, "Replaced playlist with \(items.count) item(s) (shuffled: \(isShuffled))")
        if let currentIndex, items.indices.contains(currentIndex) {
            onCurrentItemChanged?(items[currentIndex])
        }
    }

    /// Appends multiple URLs to the playlist (automatically discovering media if any URL is a folder, or parsing playlist files).
    public func append(urls: [URL]) {
        let fm = FileManager.default
        var newItems: [PlaylistItem] = []

        for url in urls {
            var isDir: ObjCBool = false
            if url.isFileURL && fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
                let folderMedia = Self.findPlayableMedia(in: url, recursive: false)
                for mediaURL in folderMedia {
                    newItems.append(PlaylistItem(url: mediaURL))
                }
            } else if PlaylistParser.isPlaylistFile(url: url) {
                // Parse playlist file (.m3u, .m3u8, .pls, .xspf, .cue)
                let parsedItems = PlaylistParser.parse(url: url)
                AppLog.info(
                    .playlist, "Parsed \(parsedItems.count) item(s) from playlist file '\(url.lastPathComponent)'")
                newItems.append(contentsOf: parsedItems)
            } else {
                newItems.append(PlaylistItem(url: url))
            }
        }

        guard !newItems.isEmpty else { return }
        append(items: newItems)
    }

    /// Asynchronously appends multiple URLs to the playlist, fetching remote playlists without blocking.
    public func appendAsync(urls: [URL]) async {
        self.isLoading = true
        defer { self.isLoading = false }

        let fm = FileManager.default
        var newItems: [PlaylistItem] = []

        for url in urls {
            if Task.isCancelled { break }
            var isDir: ObjCBool = false
            if url.isFileURL && fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
                let folderMedia = Self.findPlayableMedia(in: url, recursive: false)
                for mediaURL in folderMedia {
                    newItems.append(PlaylistItem(url: mediaURL))
                }
            } else if PlaylistParser.isPlaylistFile(url: url) {
                let parsedItems = await PlaylistParser.parseAsync(url: url)
                AppLog.info(
                    .playlist, "Parsed \(parsedItems.count) item(s) from playlist '\(url.lastPathComponent)'")
                newItems.append(contentsOf: parsedItems)
            } else {
                newItems.append(PlaylistItem(url: url))
            }
        }

        guard !Task.isCancelled, !newItems.isEmpty else { return }
        append(items: newItems)
    }

    /// Scans a directory for playable media files and appends them to the playlist (flat by default).
    public func append(folderURL: URL, recursive: Bool = false) {
        append(folderURLs: [folderURL], recursive: recursive)
    }

    /// Scans multiple directories for playable media files and appends them to the playlist (flat by default).
    public func append(folderURLs: [URL], recursive: Bool = false) {
        var allDiscovered: [URL] = []
        for folderURL in folderURLs {
            let files = Self.findPlayableMedia(in: folderURL, recursive: recursive)
            allDiscovered.append(contentsOf: files)
        }

        if allDiscovered.isEmpty {
            AppLog.warning(.playlist, "No playable media files found in specified folder(s)")
            return
        }

        append(urls: allDiscovered)
    }

    /// Appends a collection of items to the playlist.
    /// If `isShuffled` is true and playlist is currently empty, keeps the first item at the top and shuffles remaining items.
    /// If `isShuffled` is true and playlist already contains items, shuffles the newly appended slice.
    public func append(items newItems: [PlaylistItem]) {
        guard !newItems.isEmpty else { return }
        let startOriginalIndex = items.count
        let preparedItems = newItems.enumerated().map { offset, item in
            var copy = item
            copy.originalIndex = startOriginalIndex + offset
            return copy
        }

        if items.isEmpty && isShuffled && preparedItems.count > 1 {
            var shuffled = preparedItems
            let first = shuffled.remove(at: 0)
            shuffled.shuffle()
            shuffled.insert(first, at: 0)
            items = shuffled
        } else if isShuffled && !items.isEmpty {
            var shuffledSlice = preparedItems
            shuffledSlice.shuffle()
            items.append(contentsOf: shuffledSlice)
        } else {
            items.append(contentsOf: preparedItems)
        }

        AppLog.info(.playlist, "Appended \(newItems.count) item(s) to playlist. Total items: \(items.count)")
        if currentIndex == nil && !items.isEmpty {
            currentIndex = 0
            onCurrentItemChanged?(items[0])
        }
    }

    /// Appends a single item to the playlist.
    public func append(item: PlaylistItem) {
        append(items: [item])
    }

    /// Inserts URLs at a specific index.
    public func insert(urls: [URL], at index: Int) {
        let clampedIndex = min(max(index, 0), items.count)
        let newItems = urls.enumerated().map { offset, url in
            PlaylistItem(url: url, originalIndex: clampedIndex + offset)
        }
        var updatedItems = items
        updatedItems.insert(contentsOf: newItems, at: clampedIndex)

        // Re-index originalIndex so unshuffle restores current sequential order
        if !isShuffled {
            for idx in updatedItems.indices {
                updatedItems[idx].originalIndex = idx
            }
        }
        self.items = updatedItems

        // Adjust current index if insertion happens before or at current
        if let current = currentIndex, clampedIndex <= current {
            currentIndex = current + urls.count
        }
    }

    /// Removes items at specified offsets.
    public func remove(at offsets: IndexSet) {
        let currentId = currentItem?.id
        var updatedItems = items
        for index in offsets.sorted(by: >) {
            if updatedItems.indices.contains(index) {
                updatedItems.remove(at: index)
            }
        }

        // Re-index originalIndex if not shuffled
        if !isShuffled {
            for idx in updatedItems.indices {
                updatedItems[idx].originalIndex = idx
            }
        }
        self.items = updatedItems

        // Re-locate current item
        if let currentId, let newIndex = items.firstIndex(where: { $0.id == currentId }) {
            currentIndex = newIndex
        } else if items.isEmpty {
            currentIndex = nil
            onCurrentItemChanged?(nil)
        } else if let current = currentIndex {
            currentIndex = min(current, items.count - 1)
            onCurrentItemChanged?(items[currentIndex!])
        }
    }

    /// Removes an item by UUID.
    public func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        remove(at: IndexSet(integer: index))
    }

    /// Moves items within the list (drag & drop reordering).
    public func move(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        let currentId = currentItem?.id

        // Standard RangeReplaceableCollection move logic:
        // Extract elements matching source IndexSet, remove from back to front,
        // compute adjusted destination, and re-insert.
        let sourceIndices = source.filter { items.indices.contains($0) }.sorted()
        guard !sourceIndices.isEmpty else { return }

        var updatedItems = items
        let movingItems = sourceIndices.map { updatedItems[$0] }
        for index in sourceIndices.reversed() {
            updatedItems.remove(at: index)
        }

        let adjustedDestination = destination - sourceIndices.filter { $0 < destination }.count
        let clampedDestination = max(0, min(adjustedDestination, updatedItems.count))
        updatedItems.insert(contentsOf: movingItems, at: clampedDestination)

        // Re-index originalIndex so user-reordered items are preserved on unshuffle
        if !isShuffled {
            for idx in updatedItems.indices {
                updatedItems[idx].originalIndex = idx
            }
        }
        self.items = updatedItems

        if let currentId, let newIndex = items.firstIndex(where: { $0.id == currentId }) {
            currentIndex = newIndex
        }
    }

    /// Clears all items from the playlist.
    public func clear() {
        items.removeAll()
        currentIndex = nil
        onCurrentItemChanged?(nil)
    }

    /// Updates duration for an item once discovered by the demuxer.
    public func updateDuration(for itemID: UUID, duration: Double) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].duration = duration
    }

    /// Updates duration for the currently active item (preserves pre-computed duration for CUE sub-tracks).
    public func updateCurrentItemDuration(_ duration: Double) {
        guard let index = currentIndex, items.indices.contains(index) else { return }
        if items[index].startTime != nil && items[index].duration != nil {
            return
        }
        let effectiveDuration = items[index].startTime.map { max(0, duration - $0) } ?? duration
        items[index].duration = effectiveDuration
    }

    // MARK: - Modes: Shuffle & Repeat

    /// Sets repeat mode and optionally persists it to the configured UserDefaults store.
    public func setRepeatMode(_ mode: PlaylistRepeatMode) {
        repeatMode = mode
        userDefaults?.set(mode.rawValue, forKey: PlayerConfiguration.keyPlaylistRepeatMode)
    }

    /// Cycles through repeat modes: off -> all -> one -> off, persisting the change if configured.
    public func cycleRepeatMode() {
        setRepeatMode(repeatMode.next)
    }

    /// Explicitly sets or restores shuffle state, applying shuffle order if items exist and persisting to UserDefaults if configured.
    public func setShuffle(_ enabled: Bool) {
        guard isShuffled != enabled else { return }
        toggleShuffle()
    }

    /// Toggles shuffle state, preserving original ordering for unshuffling, and persists the setting if configured.
    public func toggleShuffle() {
        if items.count <= 1 {
            isShuffled.toggle()
            userDefaults?.set(isShuffled, forKey: PlayerConfiguration.keyPlaylistIsShuffled)
            return
        }

        let currentId = currentItem?.id

        if !isShuffled {
            // Shuffle
            isShuffled = true
            var shuffledItems = items
            shuffledItems.shuffle()

            // Keep current item at the top if one is playing
            if let currentId, let currIdx = shuffledItems.firstIndex(where: { $0.id == currentId }) {
                let playing = shuffledItems.remove(at: currIdx)
                shuffledItems.insert(playing, at: 0)
            }
            items = shuffledItems
        } else {
            // Unshuffle: restore original index
            isShuffled = false
            items.sort(by: { $0.originalIndex < $1.originalIndex })
        }

        if let currentId, let newIndex = items.firstIndex(where: { $0.id == currentId }) {
            currentIndex = newIndex
        }

        userDefaults?.set(isShuffled, forKey: PlayerConfiguration.keyPlaylistIsShuffled)
    }

    // MARK: - Sorting

    /// Sorts the playlist items according to the requested order.
    public func sort(by order: PlaylistSortOrder) {
        guard items.count > 1 else { return }
        let currentId = currentItem?.id
        var updatedItems = items

        switch order {
        case .titleAscending:
            updatedItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleDescending:
            updatedItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .filenameAscending:
            updatedItems.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .filenameDescending:
            updatedItems.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
        }

        isShuffled = false
        for idx in updatedItems.indices {
            updatedItems[idx].originalIndex = idx
        }
        self.items = updatedItems

        if let currentId, let newIndex = items.firstIndex(where: { $0.id == currentId }) {
            currentIndex = newIndex
        }
    }

    // MARK: - Folder Auto-Discovery

    /// Scans a directory URL for files with supported media extensions (non-recursive by default).
    /// Preserves natural alphanumeric sorting order.
    public static func findPlayableMedia(in directoryURL: URL, recursive: Bool = false) -> [URL] {
        guard directoryURL.isFileURL else {
            AppLog.warning(.playlist, "findPlayableMedia called with non-file URL: \(directoryURL)")
            return []
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            AppLog.warning(.playlist, "findPlayableMedia: path is not a directory: \(directoryURL.path)")
            return []
        }

        AppLog.info(.playlist, "Scanning folder: \(directoryURL.path) (recursive: \(recursive))")

        var foundURLs: [URL] = []
        if recursive {
            guard
                let enumerator = fm.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else {
                AppLog.warning(.playlist, "Failed to create directory enumerator for: \(directoryURL.path)")
                return []
            }

            for case let fileURL as URL in enumerator {
                if let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                    isRegular,
                    Self.mediaExtensions.contains(fileURL.pathExtension.lowercased())
                {
                    foundURLs.append(fileURL)
                }
            }
        } else {
            guard
                let fileURLs = try? fm.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                AppLog.warning(.playlist, "Failed to list contents of directory: \(directoryURL.path)")
                return []
            }

            foundURLs = fileURLs.filter { url in
                guard let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile, isRegular
                else {
                    return false
                }
                return Self.mediaExtensions.contains(url.pathExtension.lowercased())
            }
        }

        foundURLs.sort { url1, url2 in
            url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent) == .orderedAscending
        }

        AppLog.info(
            .playlist,
            "Folder scan complete for '\(directoryURL.lastPathComponent)': found \(foundURLs.count) playable file(s)")
        return foundURLs
    }

    /// Discovers playable siblings in the same directory as the given file URL and builds the playlist.
    /// Preserves natural alphanumeric order (e.g. S01E01, S01E02, S01E10).
    /// Performs directory I/O in the background to avoid blocking the MainActor.
    public func loadSiblingsFromDirectory(for fileURL: URL) {
        guard fileURL.isFileURL else { return }

        // Initialize immediately with the current item so playback begins with zero latency
        let initialItem = PlaylistItem(url: fileURL, originalIndex: 0)
        self.items = [initialItem]
        self.currentIndex = 0

        folderScanTask?.cancel()
        folderScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.loadSiblingsFromDirectoryAsync(for: fileURL)
        }
    }

    /// Asynchronously scans directory siblings off the main actor and applies results to playlist.
    public func loadSiblingsFromDirectoryAsync(for fileURL: URL) async {
        guard fileURL.isFileURL else { return }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let directoryURL: URL
        if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) && isDir.boolValue {
            directoryURL = fileURL
        } else {
            directoryURL = fileURL.deletingLastPathComponent()
        }

        let playableURLs = Self.findPlayableMedia(in: directoryURL, recursive: false)
        guard !playableURLs.isEmpty else { return }

        await MainActor.run { [weak self] in
            guard let self else { return }
            // Only apply if the current item is still the one loaded or list has not been overwritten
            guard self.items.count <= 1 || self.items.first?.url.path == fileURL.path else { return }

            var newItems: [PlaylistItem] = []
            var activeIndex = 0

            for (idx, url) in playableURLs.enumerated() {
                let item = PlaylistItem(url: url, originalIndex: idx)
                newItems.append(item)
                if url.standardizedFileURL.resolvingSymlinksInPath().path
                    == fileURL.standardizedFileURL.resolvingSymlinksInPath().path
                {
                    activeIndex = idx
                }
            }

            if self.isShuffled && newItems.count > 1 {
                // Keep the active item at the top, shuffle the remaining siblings
                let active = newItems.remove(at: activeIndex)
                newItems.shuffle()
                newItems.insert(active, at: 0)
                self.items = newItems
                self.currentIndex = 0
            } else {
                self.items = newItems
                self.currentIndex = activeIndex
            }

            AppLog.info(
                .playlist,
                "Loaded \(newItems.count) sibling media file(s) from '\(directoryURL.lastPathComponent)'"
            )
        }
    }

    /// Sets up playlist for a single loaded media URL. If `autoLoadFolder` is true, scans siblings in background.
    public func setInitialMedia(url: URL, title: String? = nil, autoLoadFolder: Bool = true) {
        // If playlist already has multiple items (e.g. loaded from a playlist file),
        // check if url is already present or was selected from it. Never wipe the playlist!
        if items.count > 1 {
            let targetPath = url.isFileURL ? url.standardizedFileURL.resolvingSymlinksInPath().path : url.absoluteString
            if let existingIndex = items.firstIndex(where: { item in
                let itemPath =
                    item.url.isFileURL
                    ? item.url.standardizedFileURL.resolvingSymlinksInPath().path : item.url.absoluteString
                return itemPath == targetPath
            }) {
                self.currentIndex = existingIndex
                return
            }
            // If url is not found directly, but we already have a loaded multi-track playlist,
            // preserve the playlist without wiping or rescanning.
            return
        }

        if url.isFileURL && autoLoadFolder {
            loadSiblingsFromDirectory(for: url)
        } else {
            let item = PlaylistItem(url: url, title: title, originalIndex: 0)
            self.items = [item]
            self.currentIndex = 0
        }
    }
}
