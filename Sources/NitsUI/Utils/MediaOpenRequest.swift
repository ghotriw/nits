import Foundation
import NitsCore

/// What a drop, the Open panel or Finder hands the player: the media to play and the subtitle files that come with it.
public struct MediaOpenRequest: Sendable, Equatable {
    /// What to load, in order, folders and playlists resolved; the first one starts playing.
    public var media: [URL]
    /// Subtitle files, attached to the first of `media`, or to the media playing when no media came with them.
    public var subtitles: [URL]

    public init(media: [URL], subtitles: [URL] = []) {
        self.media = media
        self.subtitles = subtitles
    }

    /// Splits off the subtitle files and resolves the rest (`MediaURLResolver`, off the main actor).
    @MainActor
    public static func resolving(_ urls: [URL], source: String) async -> MediaOpenRequest {
        let (subtitles, others) = SubtitleFileDrop.split(urls)
        guard !others.isEmpty else { return MediaOpenRequest(media: [], subtitles: subtitles) }
        let media = await MediaURLResolver.resolveAsync(others, source: source).urls
        // Subtitles that came with a video belong to it: none for the media playing if it can't be opened.
        return MediaOpenRequest(media: media, subtitles: media.isEmpty ? [] : subtitles)
    }

    /// The path `url` loads by: the URL of a stream, the standardized path of a file.
    public static func loadPath(for url: URL) -> String {
        MediaURL.isNetworkURL(url.absoluteString)
            ? url.absoluteString : url.standardizedFileURL.path(percentEncoded: false)
    }

    /// Loads the first of `media` with `load`, the rest becoming the playlist, and attaches the subtitle files to it
    /// once it is in; subtitle files alone attach to the media playing. `load` defaults to the engine's own.
    @MainActor
    public func open(in engine: PlayerEngine, osd: OSDManager, load: ((URL) -> Void)? = nil) async {
        guard let first = media.first else {
            if subtitles.isEmpty {
                osd.show(.custom(symbol: "exclamationmark.triangle", text: "No playable media"))
            } else {
                SubtitleFileDrop.attach(subtitles, to: engine, osd: osd)
            }
            return
        }
        if media.count > 1 {
            AppLog.info(.playlist, "Opening \(media.count) media files, starting '\(first.lastPathComponent)'")
            engine.playlist.clear()
            engine.playlist.append(urls: media)
        }
        let path = Self.loadPath(for: first)
        if let load {
            load(first)
        } else {
            engine.load(path: path)
        }
        guard !subtitles.isEmpty else { return }

        // A file on a network volume loads in the background; attach once it is in, unless another took its place.
        await engine.waitForPendingLoad()
        guard engine.isLoaded, engine.currentPath == MediaURL.normalizeMediaPath(path) else {
            AppLog.info(.subtitles, "Subtitles opened with '\(path)' not attached: it isn't what is loaded")
            return
        }
        SubtitleFileDrop.attach(subtitles, to: engine, osd: osd)
    }
}
