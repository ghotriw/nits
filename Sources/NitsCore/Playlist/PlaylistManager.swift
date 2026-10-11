import Foundation
import Observation

/// Manages playlist items, navigation, repeat/shuffle states, and filtering.
/// Fully decoupled from UI and designed to be observed via Swift Observation.
@Observable
@MainActor
public final class PlaylistManager: Sendable {
    public private(set) var items: [PlaylistItem] = []
    public private(set) var currentIndex: Int? = nil
    public var repeatMode: PlaylistRepeatMode = .off
    public private(set) var isShuffled: Bool = false
    public var autoPlayNext: Bool = true
    public var searchQuery: String = ""

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

    public init(items: [PlaylistItem] = [], repeatMode: PlaylistRepeatMode = .off, autoPlayNext: Bool = true) {
        self.items = items
        self.repeatMode = repeatMode
        self.autoPlayNext = autoPlayNext
    }

    // MARK: - Current Item & Status

    /// The currently selected/playing playlist item.
    public var currentItem: PlaylistItem? {
        guard let index = currentIndex, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// Whether there is a next track available to play.
    public var hasNext: Bool {
        guard !items.isEmpty, let currentIndex else { return !items.isEmpty }
        if repeatMode == .one || repeatMode == .all {
            return true
        }
        return currentIndex < items.count - 1
    }

    /// Whether there is a previous track available to play.
    public var hasPrevious: Bool {
        guard !items.isEmpty, let currentIndex else { return false }
        if repeatMode == .all {
            return true
        }
        return currentIndex > 0
    }

    /// Items filtered by the current `searchQuery` (case-insensitive).
    public var filteredItems: [PlaylistItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(trimmed)
                || item.filename.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: - Navigation

    /// Advances to the next item based on current index and repeat mode.
    /// - Parameter isUserAction: If true (e.g. user pressed Next button or shortcut), advances to next item even if repeatMode is .one.
    @discardableResult
    public func playNext(isUserAction: Bool = false) -> PlaylistItem? {
        guard !items.isEmpty else { return nil }

        guard let current = currentIndex else {
            currentIndex = 0
            let next = items[0]
            onCurrentItemChanged?(next)
            return next
        }

        if repeatMode == .one && !isUserAction {
            return items[current]
        }

        if current + 1 < items.count {
            let nextIndex = current + 1
            currentIndex = nextIndex
            let item = items[nextIndex]
            onCurrentItemChanged?(item)
            return item
        } else if repeatMode == .all {
            currentIndex = 0
            let item = items[0]
            onCurrentItemChanged?(item)
            return item
        } else {
            // End of playlist reached
            return nil
        }
    }

    /// Moves to the previous item, or signals to restart the current track if played past threshold.
    public func playPrevious(
        restartThresholdSeconds: Double = 3.0,
        currentPlaybackTime: Double = 0.0
    ) -> (item: PlaylistItem?, shouldRestart: Bool) {
        guard !items.isEmpty else { return (nil, false) }

        // If played for more than threshold seconds, restart current track
        if currentPlaybackTime > restartThresholdSeconds, let currentItem {
            return (currentItem, true)
        }

        guard let current = currentIndex else {
            currentIndex = 0
            let item = items[0]
            onCurrentItemChanged?(item)
            return (item, false)
        }

        if current > 0 {
            let prevIndex = current - 1
            currentIndex = prevIndex
            let item = items[prevIndex]
            onCurrentItemChanged?(item)
            return (item, false)
        } else if repeatMode == .all {
            let lastIndex = items.count - 1
            currentIndex = lastIndex
            let item = items[lastIndex]
            onCurrentItemChanged?(item)
            return (item, false)
        } else {
            // At start of playlist with repeat off: restart current track
            return (items[current], true)
        }
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

        let startOriginalIndex = items.count
        for (offset, var item) in newItems.enumerated() {
            item.originalIndex = startOriginalIndex + offset
            items.append(item)
        }
        AppLog.info(.playlist, "Appended \(newItems.count) item(s) to playlist. Total items: \(items.count)")
        if currentIndex == nil && !items.isEmpty {
            currentIndex = 0
            onCurrentItemChanged?(items[0])
        }
    }

    /// Asynchronously appends multiple URLs to the playlist, fetching remote playlists without blocking.
    public func appendAsync(urls: [URL]) async {
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
                let parsedItems = await PlaylistParser.parseAsync(url: url)
                AppLog.info(
                    .playlist, "Parsed \(parsedItems.count) item(s) from playlist '\(url.lastPathComponent)'")
                newItems.append(contentsOf: parsedItems)
            } else {
                newItems.append(PlaylistItem(url: url))
            }
        }

        guard !newItems.isEmpty else { return }

        let startOriginalIndex = items.count
        for (offset, var item) in newItems.enumerated() {
            item.originalIndex = startOriginalIndex + offset
            items.append(item)
        }
        AppLog.info(.playlist, "Appended \(newItems.count) item(s) to playlist. Total items: \(items.count)")
        if currentIndex == nil && !items.isEmpty {
            currentIndex = 0
            onCurrentItemChanged?(items[0])
        }
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
    public func append(items newItems: [PlaylistItem]) {
        guard !newItems.isEmpty else { return }
        let startOriginalIndex = items.count
        for (offset, var item) in newItems.enumerated() {
            item.originalIndex = startOriginalIndex + offset
            items.append(item)
        }
        AppLog.info(.playlist, "Appended \(newItems.count) item(s) to playlist. Total items: \(items.count)")
        if currentIndex == nil && !items.isEmpty {
            currentIndex = 0
            onCurrentItemChanged?(items[0])
        }
    }

    /// Appends a single item to the playlist.
    public func append(item: PlaylistItem) {
        var newItem = item
        newItem.originalIndex = items.count
        items.append(newItem)
        AppLog.info(.playlist, "Appended 1 item '\(newItem.title)' to playlist. Total items: \(items.count)")
        if currentIndex == nil && !items.isEmpty {
            currentIndex = 0
            onCurrentItemChanged?(items[0])
        }
    }

    /// Inserts URLs at a specific index.
    public func insert(urls: [URL], at index: Int) {
        let clampedIndex = min(max(index, 0), items.count)
        let newItems = urls.enumerated().map { offset, url in
            PlaylistItem(url: url, originalIndex: clampedIndex + offset)
        }
        items.insert(contentsOf: newItems, at: clampedIndex)

        // Adjust current index if insertion happens before or at current
        if let current = currentIndex, clampedIndex <= current {
            currentIndex = current + urls.count
        }

        // Re-index originalIndex so unshuffle restores current sequential order
        if !isShuffled {
            for (idx, _) in items.enumerated() {
                items[idx].originalIndex = idx
            }
        }
    }

    /// Removes items at specified offsets.
    public func remove(at offsets: IndexSet) {
        let currentId = currentItem?.id
        for index in offsets.sorted(by: >) {
            if items.indices.contains(index) {
                items.remove(at: index)
            }
        }

        // Re-index originalIndex if not shuffled
        if !isShuffled {
            for (idx, _) in items.enumerated() {
                items[idx].originalIndex = idx
            }
        }

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

        let movingItems = sourceIndices.map { items[$0] }
        for index in sourceIndices.reversed() {
            items.remove(at: index)
        }

        let adjustedDestination = destination - sourceIndices.filter { $0 < destination }.count
        let clampedDestination = max(0, min(adjustedDestination, items.count))
        items.insert(contentsOf: movingItems, at: clampedDestination)

        if let currentId, let newIndex = items.firstIndex(where: { $0.id == currentId }) {
            currentIndex = newIndex
        }

        // Re-index originalIndex so user-reordered items are preserved on unshuffle
        if !isShuffled {
            for (idx, _) in items.enumerated() {
                items[idx].originalIndex = idx
            }
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

    /// Cycles through repeat modes: off -> all -> one -> off.
    public func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    /// Toggles shuffle state, preserving original ordering for unshuffling.
    public func toggleShuffle() {
        guard items.count > 1 else {
            isShuffled.toggle()
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
    }

    // MARK: - Sorting

    /// Sorts the playlist items according to the requested order.
    public func sort(by order: PlaylistSortOrder) {
        let currentId = currentItem?.id

        switch order {
        case .titleAscending:
            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleDescending:
            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .filenameAscending:
            items.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .filenameDescending:
            items.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
        }

        isShuffled = false
        for (idx, _) in items.enumerated() {
            items[idx].originalIndex = idx
        }

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
        self.isShuffled = false

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

            self.items = newItems
            self.currentIndex = activeIndex
            self.isShuffled = false
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
            self.isShuffled = false
        }
    }
}
