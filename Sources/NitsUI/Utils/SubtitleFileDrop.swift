import Foundation
import NitsCore

/// Subtitle files dropped on the player attach to the media playing instead of opening as media themselves.
@MainActor
enum SubtitleFileDrop {
    /// Splits dropped URLs into subtitle files (never media) and everything else, keeping order.
    static func split(_ urls: [URL]) -> (subtitles: [URL], others: [URL]) {
        (urls.filter(SidecarSubtitles.isSubtitleFile), urls.filter { !SidecarSubtitles.isSubtitleFile($0) })
    }

    /// Adds the files as subtitle tracks of the loaded media, selecting the last readable one, and reports the
    /// outcome on the OSD.
    static func attach(_ urls: [URL], to engine: PlayerEngine, osd: OSDManager) {
        guard !urls.isEmpty else { return }
        guard engine.isLoaded else {
            osd.show(
                .custom(symbol: "captions.bubble", text: "Open a video first", subtext: "Then drop subtitles on it"))
            return
        }

        // A VobSub `.sub` loads through its `.idx`; dropped together, the pair is one file. `split` let only subtitle
        // files through, so none is left out here.
        var seen = Set<URL>()
        let files = urls.map { SidecarSubtitles.vobSubIndex(forDataFile: $0) ?? $0 }
            .filter { seen.insert($0.standardizedFileURL).inserted }

        AppLog.info(.subtitles, "Dropped \(files.count) subtitle file(s) onto the player")
        engine.subtitles.addExternal(urls: files)

        let added = Set(files.map(\.standardizedFileURL))
        if let selected = engine.subtitles.tracks.first(where: { $0.id == engine.subtitles.selectedTrackId }),
            let url = selected.externalURL, added.contains(url)
        {
            let title = TrackTitleFormatter.format(
                title: selected.title, language: selected.language, fallbackId: selected.id + 1)
            osd.show(.subtitleTrack(title: title))
        } else {
            let name = (files.last ?? urls[0]).lastPathComponent
            osd.show(.custom(symbol: "exclamationmark.triangle", text: "Can't read \(name)"))
        }
    }
}
