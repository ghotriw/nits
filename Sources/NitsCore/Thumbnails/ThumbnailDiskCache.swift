import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Manages on-disk caching of generated video thumbnails under `~/Library/Caches/<bundle id>/Thumbnails/`.
/// Keyed by file path, file size, and modification timestamp to ensure freshness.
public final class ThumbnailDiskCache: Sendable {
    private static let cacheVersion: UInt32 = 4
    private static let defaultMaxSizeBytes: Int64 = 250 * 1024 * 1024  // 250 MB

    private let cacheDirectory: URL
    private let maxSizeBytes: Int64
    /// One lock for every instance: each engine's `ThumbnailManager` has a cache of its own over the same directory,
    /// and one's pruning must not remove an item another is reading or writing.
    private static let lock = OSAllocatedUnfairLock()

    public convenience init(customCacheDirectory: URL? = nil) {
        self.init(customCacheDirectory: customCacheDirectory, maxSizeBytes: Self.defaultMaxSizeBytes)
    }

    init(customCacheDirectory: URL?, maxSizeBytes: Int64) {
        self.maxSizeBytes = maxSizeBytes
        let baseCacheURL =
            customCacheDirectory ?? AppDirectories.caches.appendingPathComponent("Thumbnails", isDirectory: true)
        self.cacheDirectory = baseCacheURL

        try? FileManager.default.createDirectory(at: baseCacheURL, withIntermediateDirectories: true)
    }

    /// Generates a stable unique hash identifier for a given file URL/path and its filesystem attributes.
    public func cacheKey(for path: String) -> String? {
        guard !MediaURL.isNetworkURL(path) else {
            // For network URLs, hash the clean URL string along with cache version
            let digest = SHA256.hash(data: Data("\(path)|v\(Self.cacheVersion)".utf8))
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        }

        let cleanPath = MediaURL.normalizeMediaPath(path)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cleanPath) else {
            return nil
        }

        let size = (attrs[.size] as? Int64) ?? 0
        let modDate = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let rawIdentity = "\(cleanPath)|\(size)|\(modDate)|v\(Self.cacheVersion)"
        let digest = SHA256.hash(data: Data(rawIdentity.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Returns the directory URL for a given cache key.
    private func itemDirectory(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key, isDirectory: true)
    }

    /// Loads all cached thumbnails for a given cache key, if available.
    public func loadThumbnails(for key: String) -> [ThumbnailItem]? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let dir = itemDirectory(for: key)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let indexURL = dir.appendingPathComponent("index.json")
        guard let indexData = try? Data(contentsOf: indexURL),
            let entries = try? JSONDecoder().decode([IndexEntry].self, from: indexData)
        else {
            return nil
        }

        var results: [ThumbnailItem] = []
        results.reserveCapacity(entries.count)

        for entry in entries {
            let imgURL = dir.appendingPathComponent("\(entry.id).jpg")
            guard let imageSource = CGImageSourceCreateWithURL(imgURL as CFURL, nil),
                let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
            else {
                continue
            }
            results.append(ThumbnailItem(time: entry.time, image: cgImage, width: entry.width, height: entry.height))
        }
        guard !results.isEmpty else { return nil }

        // Reading files by path leaves the directory's dates alone: mark the hit, so pruning evicts the least
        // recently used item, not the oldest one.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return results
    }

    /// Saves generated thumbnails to disk asynchronously or synchronously.
    public func saveThumbnails(_ thumbnails: [ThumbnailItem], for key: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let dir = itemDirectory(for: key)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var indexEntries: [IndexEntry] = []
        indexEntries.reserveCapacity(thumbnails.count)

        for (index, item) in thumbnails.enumerated() {
            let entryId = "\(index)"
            let imgURL = dir.appendingPathComponent("\(entryId).jpg")

            let typeIdentifier = UTType.jpeg.identifier as CFString
            if let destination = CGImageDestinationCreateWithURL(imgURL as CFURL, typeIdentifier, 1, nil) {
                let options: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: 0.75
                ]
                CGImageDestinationAddImage(destination, item.image, options as CFDictionary)
                CGImageDestinationFinalize(destination)
            }

            indexEntries.append(
                IndexEntry(
                    id: entryId,
                    time: item.time,
                    width: item.width,
                    height: item.height
                )
            )
        }

        if let indexData = try? JSONEncoder().encode(indexEntries) {
            let indexURL = dir.appendingPathComponent("index.json")
            try? indexData.write(to: indexURL, options: .atomic)
        }

        pruneOldCachesIfNeeded(keeping: key)
    }

    private struct IndexEntry: Codable {
        let id: String
        let time: Double
        let width: Int
        let height: Int
    }

    /// Removes the least recently used items once the cache exceeds its size, down to half of it.
    ///
    /// "Used" is the directory's modification date, which a save and a load (`loadThumbnails`) set. Not the access
    /// date: listing a directory, as measuring its size here does, may move it for every item alike. The item just
    /// saved (`keeping`) stays even when it alone is over half of the size. Only folders named as a cache key count:
    /// in a host app the folder is in the host's caches, where it may keep folders of its own.
    private func pruneOldCachesIfNeeded(keeping keptKey: String) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            )
        else { return }

        var dirs: [(url: URL, date: Date, size: Int64)] = []
        var totalSize: Int64 = 0

        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                values.isDirectory == true, Self.isCacheKey(url.lastPathComponent)
            else { continue }

            let date = values.contentModificationDate ?? Date.distantPast
            let dirSize = directorySize(url: url)
            totalSize += dirSize
            dirs.append((url: url, date: date, size: dirSize))
        }

        if totalSize > maxSizeBytes {
            dirs.sort { $0.date < $1.date }
            for item in dirs where item.url.lastPathComponent != keptKey {
                try? FileManager.default.removeItem(at: item.url)
                totalSize -= item.size
                if totalSize <= maxSizeBytes / 2 {
                    break
                }
            }
        }
    }

    /// Whether `name` is a key `cacheKey(for:)` makes: a SHA-256 in lowercase hex.
    static func isCacheKey(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private func directorySize(url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in files {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
