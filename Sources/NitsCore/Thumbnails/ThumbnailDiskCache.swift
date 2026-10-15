import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Manages on-disk caching of generated video thumbnails under `~/Library/Caches/Nits/Thumbnails/`.
/// Keyed by file path, file size, and modification timestamp to ensure freshness.
public final class ThumbnailDiskCache: Sendable {
    private static let cacheVersion: UInt32 = 4
    private static let maxDiskCacheSizeBytes: Int64 = 250 * 1024 * 1024  // 250 MB

    private let cacheDirectory: URL
    private let lock = OSAllocatedUnfairLock()

    public init(customCacheDirectory: URL? = nil) {
        let baseCacheURL: URL = {
            if let custom = customCacheDirectory {
                return custom
            } else if let userCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                return userCache.appendingPathComponent("Nits", isDirectory: true).appendingPathComponent(
                    "Thumbnails", isDirectory: true)
            } else {
                return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
                    "NitsThumbnails", isDirectory: true)
            }
        }()
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

        let cleanPath = PlayerEngine.normalizeMediaPath(path)

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
        lock.lock()
        defer { lock.unlock() }

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

        return results.isEmpty ? nil : results
    }

    /// Saves generated thumbnails to disk asynchronously or synchronously.
    public func saveThumbnails(_ thumbnails: [ThumbnailItem], for key: String) {
        lock.lock()
        defer { lock.unlock() }

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

        pruneOldCachesIfNeeded()
    }

    private struct IndexEntry: Codable {
        let id: String
        let time: Double
        let width: Int
        let height: Int
    }

    /// Cleans up older caches if total disk usage exceeds threshold.
    private func pruneOldCachesIfNeeded() {
        guard
            let enumerator = FileManager.default.enumerator(
                at: cacheDirectory,
                includingPropertiesForKeys: [
                    .contentAccessDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey,
                ],
                options: [.skipsSubdirectoryDescendants]
            )
        else { return }

        var dirs: [(url: URL, date: Date, size: Int64)] = []
        var totalSize: Int64 = 0

        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .contentAccessDateKey, .contentModificationDateKey,
                ]),
                values.isDirectory == true
            else { continue }

            let date = values.contentAccessDate ?? values.contentModificationDate ?? Date.distantPast
            let dirSize = directorySize(url: url)
            totalSize += dirSize
            dirs.append((url: url, date: date, size: dirSize))
        }

        if totalSize > Self.maxDiskCacheSizeBytes {
            dirs.sort { $0.date < $1.date }
            for item in dirs {
                try? FileManager.default.removeItem(at: item.url)
                totalSize -= item.size
                if totalSize <= Self.maxDiskCacheSizeBytes / 2 {
                    break
                }
            }
        }
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
