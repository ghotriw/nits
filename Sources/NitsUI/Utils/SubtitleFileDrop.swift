import Foundation
import NitsCore

/// Subtitle files dropped on the player attach to the media playing instead of opening as media themselves.
@MainActor
enum SubtitleFileDrop {
    /// Splits dropped URLs into subtitle files (supported or not, never media) and everything else, keeping order.
    static func split(_ urls: [URL]) -> (subtitles: [URL], others: [URL]) {
        let isSubtitle = { (url: URL) in
            SidecarSubtitles.isSubtitleFile(url) || SidecarSubtitles.isUnsupportedSubtitleFile(url)
        }
        return (urls.filter(isSubtitle), urls.filter { !isSubtitle($0) })
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

        let supported = urls.filter(SidecarSubtitles.isSubtitleFile)
        guard let lastSupported = supported.last else {
            let format = urls[0].pathExtension.uppercased()
            osd.show(.custom(symbol: "captions.bubble", text: "\(format) subtitles aren't supported yet"))
            return
        }

        AppLog.info(.subtitles, "Dropped \(supported.count) subtitle file(s) onto the player")
        engine.loadExternalSubtitles(urls: supported)

        let added = Set(supported.map(\.standardizedFileURL))
        if let selected = engine.subtitleTracks.first(where: { $0.id == engine.selectedSubtitleTrackId }),
            let url = selected.externalURL, added.contains(url)
        {
            let title = TrackTitleFormatter.format(
                title: selected.title, language: selected.language, fallbackId: selected.id + 1)
            osd.show(.subtitleTrack(title: title))
        } else {
            osd.show(.custom(symbol: "exclamationmark.triangle", text: "Can't read \(lastSupported.lastPathComponent)"))
        }
    }
}
