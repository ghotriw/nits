import Foundation
import NitsCore

/// Subtitle files dropped on the player attach to the media playing instead of opening as media themselves.
@MainActor
enum SubtitleFileDrop {
    /// Splits dropped URLs into subtitle files and everything else, keeping their order.
    static func split(_ urls: [URL]) -> (subtitles: [URL], others: [URL]) {
        (urls.filter(SidecarSubtitles.isSubtitleFile), urls.filter { !SidecarSubtitles.isSubtitleFile($0) })
    }

    /// Adds the files as subtitle tracks of the loaded media, selecting the last one, and confirms on the OSD.
    static func attach(_ urls: [URL], to engine: PlayerEngine, osd: OSDManager) {
        guard let last = urls.last else { return }
        guard engine.isLoaded else {
            osd.show(
                .custom(symbol: "captions.bubble", text: "Open a video first", subtext: "Then drop subtitles on it"))
            return
        }

        AppLog.info(.subtitles, "Dropped \(urls.count) subtitle file(s) onto the player")
        for url in urls {
            engine.loadExternalSubtitle(url: url)
        }

        let selected = engine.subtitleTracks.first { $0.id == engine.selectedSubtitleTrackId }
        if let selected, selected.externalURL == last.standardizedFileURL {
            let title = TrackTitleFormatter.format(
                title: selected.title, language: selected.language, fallbackId: selected.id + 1)
            osd.show(.subtitleTrack(title: title))
        } else {
            osd.show(.custom(symbol: "exclamationmark.triangle", text: "Can't read \(last.lastPathComponent)"))
        }
    }
}
