import Foundation
internal import NitsStreaming

/// The streaming client as a `DemuxerInput`: what the demuxer asks of an input that the client does not know (its
/// container's chapters and fonts, its traits, the window as a public `LiveWindow`, a saved manifest told by its text).
extension HLSInput: DemuxerInput {
    /// Whether `path` is one the client opens: a playlist (`.m3u8`, `.m3u`) over HTTP(S), or a saved one, a file whose text
    /// is an HLS manifest (`PlaylistParser.isHLSManifest`; a plain `.m3u` list of tracks is not).
    static func applies(to path: String) -> Bool {
        if appliesToNetworkAddress(path) { return true }
        let url = MediaURL.normalizeMediaPath(path)
        let file = URL(fileURLWithPath: url)
        guard !MediaURL.isNetworkURL(url), hasPlaylistExtension(file),
            let data = try? Data(contentsOf: file, options: .mappedIfSafe),
            let text = TextFileEncoding.decode(data)?.text
        else { return false }
        return PlaylistParser.isHLSManifest(content: text)
    }

    var traits: DemuxerInputTraits {
        DemuxerInputTraits(hasIndex: false, landsBetweenKeyframes: true, opensAsFile: false)
    }

    var chapters: [MediaChapter.Raw] { [] }
    var attachedFonts: [AssScript.Font] { [] }

    func liveWindow() -> LiveWindow? {
        streamingLiveWindow().map(LiveWindow.init)
    }
}
