import Foundation
import NitsCore

/// Saves captured frames to `~/Pictures/Nits`, named after the media and the frame's time
/// ("Title 01-02-03.456.png"), never over an existing file.
enum FrameStillWriter {
    static var directory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nits", isDirectory: true)
    }

    /// Writes `frame` and returns where it went.
    static func write(_ frame: CapturedFrame, title: String, in directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = frame.contentType.preferredFilenameExtension ?? "png"
        let base = fileName(title: title, pts: frame.pts)
        var url = directory.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(copy)").appendingPathExtension(fileExtension)
            copy += 1
        }
        try frame.data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// The file name without extension: the title, with characters Finder or the file system reject replaced, and
    /// the time as `HH-MM-SS.mmm`.
    static func fileName(title: String, pts: Double) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.newlines))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        let name = cleaned.isEmpty ? "Nits" : String(cleaned.prefix(120))
        let milliseconds = Int((max(pts.isFinite ? pts : 0, 0) * 1000).rounded())
        let time = String(
            format: "%02d-%02d-%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
            milliseconds / 1000 % 60, milliseconds % 1000)
        return "\(name) \(time)"
    }
}
