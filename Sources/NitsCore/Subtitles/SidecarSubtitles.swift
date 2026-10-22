import Foundation

/// Subtitle files that belong to a media file by name (`movie.srt`, `movie.en.srt`, `movie.en.forced.vtt` next to
/// `movie.mkv`), and what a subtitle file's name tells about it.
public enum SidecarSubtitles {
    /// Extensions of the text formats: those `SubtitleDocument` parses, and those FFmpeg reads (`FFmpegTextSubtitles`).
    static let textExtensions: Set<String> = Set(["srt", "vtt", "ass", "ssa"]).union(FFmpegTextSubtitles.extensions)

    /// Extensions of bitmap subtitle files: PGS streams (`.sup`) and VobSub indexes (`.idx`, with their `.sub` data).
    static let bitmapExtensions: Set<String> = ["sup", "idx"]

    /// Extensions of the subtitle formats the player loads.
    static let extensions: Set<String> = textExtensions.union(bitmapExtensions)

    /// Extensions an open panel for subtitle files offers. A VobSub `.sub` among them loads through the `.idx` next to
    /// it; one with none is read as text (MicroDVD, SubViewer).
    public static let pickableExtensions: [String] = extensions.sorted()

    /// Whether the URL names a local subtitle file of a format the player loads.
    public static func isSubtitleFile(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the URL names a local subtitle file made of pictures (PGS, VobSub).
    public static func isBitmapSubtitleFile(_ url: URL) -> Bool {
        url.isFileURL && bitmapExtensions.contains(url.pathExtension.lowercased())
    }

    /// The `.idx` that goes with a VobSub `.sub` file next to it, which is what loads the pair; `nil` for any other
    /// URL or a `.sub` with no index (MicroDVD or SubViewer text).
    public static func vobSubIndex(forDataFile url: URL, fileManager: FileManager = .default) -> URL? {
        guard url.isFileURL, url.pathExtension.lowercased() == "sub" else { return nil }
        let base = url.deletingPathExtension()
        return ["idx", "IDX"].map { base.appendingPathExtension($0) }.first { fileManager.fileExists(atPath: $0.path) }
    }

    public typealias NameTags = SidecarFiles.NameTags

    /// Subtitle files in the media's folder named as the media, optionally followed by dot-separated tags, sorted by
    /// name. Empty for anything but a local file.
    public static func urls(for mediaURL: URL, fileManager: FileManager = .default) -> [URL] {
        // A VobSub pair is one file, found as its `.idx`.
        SidecarFiles.urls(for: mediaURL, extensions: extensions, fileManager: fileManager) {
            vobSubIndex(forDataFile: $0, fileManager: fileManager) == nil
        }
    }

    /// See `SidecarFiles.tags(of:)`.
    public static func tags(of url: URL) -> NameTags {
        SidecarFiles.tags(of: url)
    }
}
