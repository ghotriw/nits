import AppKit
import UniformTypeIdentifiers

@MainActor
public enum MediaOpenPanel {
    public static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [
            .movie,
            .video,
            .quickTimeMovie,
            .mpeg4Movie,
            .avi,
            .audio,
            .mp3,
            .wav,
            .aiff,
            .playlist,
            .m3uPlaylist,
        ]
        // Add common video, audio, and playlist formats supported by Nits that may not be covered by system presets
        let extensions = [
            // Video
            "mkv", "webm", "flv", "wmv", "ts", "m4v", "mov", "mp4", "ogv", "divx", "3gp",
            "mpg", "mpeg", "vob", "m2v", "m2ts", "mts", "rm", "rmvb",
            // Audio
            "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "alac", "aif", "aiff", "wma", "ape",
            // Playlists
            "m3u", "m3u8", "pls", "xspf", "cue",
        ]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()

    public static func promptForMediaFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = supportedContentTypes

        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    public static func promptForMediaFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedContentTypes

        let response = panel.runModal()
        return response == .OK ? panel.urls : []
    }

    public static func promptForMediaFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Playlist"
        panel.message = "Choose folders containing media files to add to playlist"

        let response = panel.runModal()
        return response == .OK ? panel.urls : []
    }

    public static func promptForMediaFolder() -> URL? {
        promptForMediaFolders().first
    }
}
