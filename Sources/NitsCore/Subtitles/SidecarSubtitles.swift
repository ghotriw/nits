import Foundation

/// Subtitle files that belong to a media file by name (`movie.srt`, `movie.en.srt`, `movie.en.forced.vtt` next to
/// `movie.mkv`), and what a subtitle file's name tells about it.
public enum SidecarSubtitles {
    /// Extensions of the formats `SubtitleDocument` parses.
    static let extensions: Set<String> = ["srt", "vtt"]

    /// Whether the URL names a subtitle file of a format `SubtitleDocument` parses.
    public static func isSubtitleFile(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }

    /// Language and flags read from the trailing dot-separated tags of a subtitle file name.
    public struct NameTags: Equatable, Sendable {
        public var language: String?
        public var isForced: Bool
        public var isSDH: Bool

        public init(language: String? = nil, isForced: Bool = false, isSDH: Bool = false) {
            self.language = language
            self.isForced = isForced
            self.isSDH = isSDH
        }
    }

    /// Subtitle files in the media's folder named as the media, optionally followed by dot-separated tags, sorted by
    /// name. Empty for anything but a local file.
    public static func urls(for mediaURL: URL, fileManager: FileManager = .default) -> [URL] {
        guard mediaURL.isFileURL else { return [] }
        let baseName = normalized(mediaURL.deletingPathExtension().lastPathComponent)
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: mediaURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        return
            contents
            .filter { url in
                guard extensions.contains(url.pathExtension.lowercased()) else { return false }
                let name = normalized(url.deletingPathExtension().lastPathComponent)
                return name == baseName || name.hasPrefix(baseName + ".")
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Reads up to three trailing tags of the name (`movie.en.forced.srt`): `forced`, `sdh` / `cc`, and an ISO 639
    /// language code. Stops at the first tag that is none of these, so title words and release tags are ignored.
    public static func tags(of url: URL) -> NameTags {
        var tags = NameTags()
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".")
        for part in parts.dropFirst().reversed().prefix(3) {
            let tag = part.lowercased()
            // Flags first: "sdh" is also an ISO 639 code (Southern Kurdish).
            if tag == "forced" {
                tags.isForced = true
            } else if tag == "sdh" || tag == "cc" {
                tags.isSDH = true
            } else if tags.language == nil, isLanguageCode(tag) {
                tags.language = tag
            } else {
                break
            }
        }
        return tags
    }

    static func isLanguageCode(_ tag: String) -> Bool {
        guard tag != "und", tag.wholeMatch(of: #/[a-z]{2,3}(-[a-z0-9]{2,4})?/#) != nil else { return false }
        return Locale.LanguageCode(tag).isISOLanguage
    }

    /// File names compare case-insensitively and regardless of Unicode normalization (APFS keeps either form).
    private static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
