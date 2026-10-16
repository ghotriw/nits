import Foundation
import NitsCore
import NitsTestSupport
import Testing

@testable import NitsUI

@Suite("Subtitle file drop")
@MainActor
struct SubtitleFileDropTests {
    @Test("Dropped subtitle files, supported or not, are split from media, keeping order")
    func testSplit() {
        let urls = ["/m/a.mkv", "/m/a.srt", "/m/b.MP4", "/m/b.VTT", "/m/c.ass"].map { URL(fileURLWithPath: $0) }
        let (subtitles, others) = SubtitleFileDrop.split(urls)
        #expect(subtitles.map(\.lastPathComponent) == ["a.srt", "b.VTT", "c.ass"])
        #expect(others.map(\.lastPathComponent) == ["a.mkv", "b.MP4"])
        #expect(SubtitleFileDrop.split([URL(string: "https://example.com/a.srt")!]).subtitles.isEmpty)
    }

    @Test("Subtitles dropped with nothing playing add no track and say why on the OSD")
    func testDropWithoutMedia() {
        let engine = PlayerEngine.makeForTesting()
        let osd = OSDManager()
        SubtitleFileDrop.attach([URL(fileURLWithPath: "/m/a.srt")], to: engine, osd: osd)
        #expect(engine.subtitleTracks.isEmpty)
        guard case .custom(_, let text, _, _) = osd.currentEvent else {
            Issue.record("Expected a custom OSD event, got \(String(describing: osd.currentEvent))")
            return
        }
        #expect(text == "Open a video first")
    }
}
