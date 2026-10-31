import Foundation
import NitsCore

/// Subtitle files dropped on the player attach to the media playing instead of opening as media themselves.
@MainActor
public enum SubtitleFileDrop {
    /// Splits dropped URLs into subtitle files (never media) and everything else, keeping order.
    public static func split(_ urls: [URL]) -> (subtitles: [URL], others: [URL]) {
        (urls.filter(SidecarSubtitles.isSubtitleFile), urls.filter { !SidecarSubtitles.isSubtitleFile($0) })
    }

    /// Adds the files as subtitle tracks of the loaded media, selecting the last readable one, and reports the
    /// outcome on the OSD. The files are read off the main actor.
    public static func attach(_ urls: [URL], to engine: PlayerEngine, osd: OSDManager) async {
        guard !urls.isEmpty else { return }
        guard engine.isLoaded else {
            osd.show(
                .custom(symbol: "captions.bubble", text: "Open a video first", subtext: "Then drop subtitles on it"))
            return
        }

        // A VobSub `.sub` loads through its `.idx`: dropped together, the pair is listed once.
        AppLog.info(.subtitles, "Adding \(urls.count) subtitle file(s) to the media playing")
        switch await engine.subtitles.addExternal(urls: urls) {
        case .selected(let track):
            let title = TrackTitleFormatter.format(
                title: track.title, language: track.language, fallbackId: track.id + 1)
            osd.show(.subtitleTrack(title: title))
        case .unreadable:
            let name = urls[urls.count - 1].lastPathComponent
            osd.show(.custom(symbol: "exclamationmark.triangle", text: "Can't read \(name)"))
        case .mediaChanged:
            // The media they were for is gone; the new one shows its own.
            break
        }
    }
}
