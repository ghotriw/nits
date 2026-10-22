import Foundation

/// Audio files that belong to a media file by name (`movie.mka`, `movie.uk.ac3` next to `movie.mkv`): a dub or a
/// commentary sold apart from the picture. They are added as audio tracks of the media (`PlaybackInputs`).
public enum SidecarAudio {
    /// Extensions of the audio files picked up next to the media. Not of the containers a picture comes in (`mkv`,
    /// `mp4`): one named as the media is another cut of it, not its audio; such a file can still be added by hand.
    static let extensions: Set<String> = [
        "mka", "m4a", "aac", "ac3", "eac3", "ec3", "dts", "thd", "flac", "opus", "ogg", "oga", "mp3", "wav", "w64",
    ]

    /// Extensions an open panel for audio files offers: the audio formats, and the containers a dub may come in.
    public static let pickableExtensions: [String] = extensions.union(["mkv", "mp4", "mov", "webm"]).sorted()

    /// Audio files in the media's folder named as the media, optionally followed by dot-separated tags, sorted by
    /// name. Empty for anything but a local file.
    public static func urls(for mediaURL: URL, fileManager: FileManager = .default) -> [URL] {
        SidecarFiles.urls(for: mediaURL, extensions: extensions, fileManager: fileManager)
    }
}
