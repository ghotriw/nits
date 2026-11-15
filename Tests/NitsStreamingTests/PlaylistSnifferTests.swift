import Foundation
import Testing

@testable import NitsStreaming

@Suite("Playlist sniffer")
struct PlaylistSnifferTests {
    private func kind(_ text: String) -> SniffedPlaylist? { SniffedPlaylist.classify(Array(text.utf8)) }

    @Test("A manifest is told by its root, after the prolog, whatever its namespace prefix")
    func tellsManifests() {
        #expect(kind("<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\">") == .dash)
        #expect(kind("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MPD>") == .dash)
        #expect(kind("\u{FEFF}  \r\n<?xml version=\"1.0\"?><!-- made by a packager -->\n<!DOCTYPE x>\n<MPD/>") == .dash)
        #expect(kind("<?xml version=\"1.0\"?><mpd:MPD xmlns:mpd=\"urn:mpeg:dash:schema:mpd:2011\">") == .dash)
    }

    @Test("A playlist is told by its first line; any other text is neither")
    func tellsPlaylistsAndTheRest() {
        #expect(kind("#EXTM3U\n#EXT-X-VERSION:3") == .hls)
        #expect(kind("\u{FEFF}#EXTM3U\n") == .hls)
        #expect(kind("\n#EXTM3U\n") == nil, "The parser wants the tag on the first line")
        #expect(kind("  \t#EXTM3U\n") == .hls, "The parser trims the first line")
        let banner = "<!-- " + String(repeating: "licence ", count: 200) + "-->"
        #expect(kind("<?xml version=\"1.0\"?>\n\(banner)\n<MPD/>") == .dash, "A long comment before the root")
        #expect(kind("<?xml version=\"1.0\"?><rss version=\"2.0\">") == nil)
        #expect(kind("<html><body>MPD</body></html>") == nil)
        #expect(kind("<?xml version=\"1.0\"") == nil, "A prolog that does not end")
        #expect(kind("<MPDX>") == nil)
        #expect(kind("ID3\u{3}\u{0}binary") == nil)
        #expect(kind("") == nil)
    }
}
