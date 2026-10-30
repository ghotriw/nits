import Foundation

/// Finds the yt-dlp installed on the system: Nits doesn't bundle it (it changes with the sites, weekly), as mpv and VLC
/// don't. An app opened from the Finder gets the launchd `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), without the
/// directories package managers install to, so these are searched too.
struct YTDLPLocator: Sendable {
    /// Names yt-dlp is installed under: Homebrew's, pip's and pipx's script, the standalone macOS build.
    static let names = ["yt-dlp", "yt-dlp_macos"]

    /// The user's yt-dlp (`AppSettings.ytdlpPath`), the only one tried when set.
    var customPath: String = ""
    /// The process's `PATH`, searched first.
    var environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var homeDirectory: String = NSHomeDirectory()

    /// Where package managers install to: Homebrew (Apple silicon, Intel), pip `--user` and pipx, MacPorts.
    var installDirectories: [String] {
        [
            "/opt/homebrew/bin", "/usr/local/bin", homeDirectory + "/.local/bin",
            homeDirectory + "/Library/Python/3/bin", "/opt/local/bin",
        ]
    }

    /// The directories searched, in order: `PATH`'s, then the install directories it lacks.
    var searchDirectories: [String] {
        var directories: [String] = []
        for directory in environmentPath.split(separator: ":").map(String.init) + installDirectories
        where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }

    /// The executable to run; `nil` when none is installed (or the user's isn't one). Only checks files: cheap enough
    /// for each load, so one installed while Nits runs is found without a restart.
    func executable() -> URL? {
        let fileManager = FileManager.default
        if !customPath.isEmpty {
            let path = (customPath as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for directory in searchDirectories {
            for name in Self.names {
                let path = directory + "/" + name
                if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// `PATH` for yt-dlp to run with: the search directories, so that it finds what it runs in turn from them (Deno for
    /// YouTube's challenges, FFmpeg).
    func processPath(for executable: URL) -> String {
        let own = executable.deletingLastPathComponent().path
        return ([own] + searchDirectories.filter { $0 != own }).joined(separator: ":")
    }
}
