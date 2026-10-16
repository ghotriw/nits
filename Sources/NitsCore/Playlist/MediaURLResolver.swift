import Foundation

/// Turns the URLs of a drop or an open request into the items worth loading: folders become the playable
/// media they contain, hidden and missing files are dropped, and files with an unknown extension are kept only
/// when nothing recognisable came with them (so a lone `.y4m` still gets a chance, a stray `.zsh_sessions`
/// next to a movie does not). Remote URLs pass through unchanged.
public enum MediaURLResolver {
    public struct Resolution: Sendable, Equatable {
        /// What to load, in order; the first one starts playing.
        public var urls: [URL]
        /// How many of the given URLs were dropped (folders count as dropped when they held no media).
        public var skippedCount: Int
    }

    /// Touches the file system (folder scans), so call it off the main actor for user-supplied URLs.
    nonisolated public static func resolve(_ urls: [URL]) -> Resolution {
        let fm = FileManager.default
        var recognized: [URL] = []
        var unrecognized: [URL] = []
        var skipped = 0

        for url in urls {
            guard url.isFileURL else {
                recognized.append(url)
                continue
            }
            var isDir: ObjCBool = false
            guard !url.lastPathComponent.hasPrefix("."), fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                skipped += 1
                continue
            }
            if isDir.boolValue {
                let media = PlaylistManager.findPlayableMedia(in: url, recursive: false)
                if media.isEmpty { skipped += 1 }
                recognized.append(contentsOf: media)
            } else if PlaylistManager.supportedExtensions.contains(url.pathExtension.lowercased()) {
                recognized.append(url)
            } else {
                unrecognized.append(url)
            }
        }

        if recognized.isEmpty {
            return Resolution(urls: unrecognized, skippedCount: skipped)
        }
        return Resolution(urls: recognized, skippedCount: skipped + unrecognized.count)
    }

    /// `resolve(_:)` on a background thread, logging what a drop or open request delivered and what survived.
    nonisolated public static func resolveAsync(_ urls: [URL], source: String) async -> Resolution {
        let resolution = await Task.detached(priority: .userInitiated) { resolve(urls) }.value
        if urls.count > 1 || resolution.urls.count != urls.count {
            AppLog.info(
                .playlist,
                "\(source): \(urls.count) URL(s) given, \(resolution.urls.count) playable, \(resolution.skippedCount) skipped"
            )
        }
        if resolution.urls.isEmpty {
            AppLog.warning(
                .playlist,
                "\(source): nothing playable in \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        }
        return resolution
    }
}
