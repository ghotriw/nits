import Foundation

/// The folders Nits keeps its files in under the user's Library, named after the app's bundle identifier
/// (`com.ghotriw.nits`; a host embedding NitsCore gets folders of its own), as macOS expects. Without a bundle
/// (`swift run`) they are named "Nits".
enum AppDirectories {
    /// `~/Library/Caches/<bundle id>`: what can be built again (thumbnails, media durations).
    static var caches: URL {
        library("Caches")
    }

    /// `~/Library/Application Support/<bundle id>`: what must last (playback history).
    static var applicationSupport: URL {
        library("Application Support")
    }

    /// `~/Library/Logs/<bundle id>`, where Console lists the log.
    static var logs: URL {
        library("Logs")
    }

    private static var name: String {
        Bundle.main.bundleIdentifier ?? "Nits"
    }

    private static func library(_ folder: String) -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }
}
