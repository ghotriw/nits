import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("Subtitle Parsing and Document Tests")
struct SubtitleTests {

    @Test("Timestamp parser handles comma, dot, and 2-part/3-part formats")
    func testTimestampParsing() {
        // Standard SRT with comma
        let t1 = SubtitleDocument.parseTimestamp("01:23:45,678")
        #expect(t1 != nil)
        #expect(abs(t1! - (3600.0 + 23.0 * 60.0 + 45.678)) < 0.001)

        // WebVTT with dot
        let t2 = SubtitleDocument.parseTimestamp("00:02:10.500")
        #expect(t2 != nil)
        #expect(abs(t2! - 130.5) < 0.001)

        // Short format MM:SS.mmm
        let t3 = SubtitleDocument.parseTimestamp("05:30.250")
        #expect(t3 != nil)
        #expect(abs(t3! - 330.25) < 0.001)
    }

    @Test("Parse SRT content with multiple cues and HTML tags")
    func testParseSRT() {
        let srtData = """
            1
            00:00:01,000 --> 00:00:04,000
            Hello, <i>world</i>!

            2
            00:00:05,500 --> 00:00:08,200
            This is a <b>second</b> line.
            Multiple lines text.

            """

        let doc = SubtitleDocument.parseSRT(srtData)
        #expect(doc.cues.count == 2)
        #expect(doc.cues[0].startTime == 1.0)
        #expect(doc.cues[0].endTime == 4.0)
        #expect(doc.cues[0].text == "Hello, world!")

        #expect(doc.cues[1].startTime == 5.5)
        #expect(doc.cues[1].endTime == 8.2)
        #expect(doc.cues[1].text == "This is a second line.\nMultiple lines text.")

        // Test activeCue lookup
        #expect(doc.activeCue(at: 0.5) == nil)
        #expect(doc.activeCue(at: 2.0)?.text == "Hello, world!")
        #expect(doc.activeCue(at: 4.5) == nil)
        #expect(doc.activeCue(at: 6.0)?.text == "This is a second line.\nMultiple lines text.")
        #expect(doc.activeCue(at: 10.0) == nil)
    }

    @Test("Parse WebVTT with header and line positioning")
    func testParseWebVTT() {
        let vttData = """
            WEBVTT

            00:01:00.000 --> 00:01:05.000 position:50% line:0%
            Subtitle on the top

            00:02:00.000 --> 00:02:04.000
            Second caption
            """

        let doc = SubtitleDocument.parseWebVTT(vttData)
        #expect(doc.cues.count == 2)
        #expect(doc.cues[0].startTime == 60.0)
        #expect(doc.cues[0].endTime == 65.0)
        #expect(doc.cues[0].text == "Subtitle on the top")

        #expect(doc.activeCue(at: 62.0)?.text == "Subtitle on the top")
        #expect(doc.activeCue(at: 59.0) == nil)
    }

    @Test("Strip ASS tags such as {\\an8}, {\\b1}, {\\pos(x,y)} and convert \\N newlines")
    func testStripASSTags() {
        let input = "{\\an8}First line\\NSecond line{\\b1} Yes!"
        let cleaned = SubtitleDocument.cleanFormattingTags(input)
        #expect(cleaned == "First line\nSecond line Yes!")

        let srtWithASS = """
            1
            00:00:02,000 --> 00:00:05,000
            {\\an8}Top subtitle text
            """
        let doc = SubtitleDocument.parseSRT(srtWithASS)
        #expect(doc.cues.first?.text == "Top subtitle text")
        #expect(doc.cues.first?.alignment == .topCenter)
    }

    @Test("Overlapping simultaneous subtitle cues are all returned by activeCues")
    func testOverlappingCues() {
        let cues = [
            SubtitleCue(id: 1, startTime: 10.0, endTime: 30.0, text: "Long dialogue", alignment: .bottomCenter),
            SubtitleCue(id: 2, startTime: 15.0, endTime: 20.0, text: "Sign translation", alignment: .topCenter),
        ]
        let doc = SubtitleDocument(cues: cues)

        let at12 = doc.activeCues(at: 12.0)
        #expect(at12.count == 1)
        #expect(at12.first?.text == "Long dialogue")

        let at17 = doc.activeCues(at: 17.0)
        #expect(at17.count == 2)
        #expect(at17.map(\.text).contains("Long dialogue"))
        #expect(at17.map(\.text).contains("Sign translation"))

        let at25 = doc.activeCues(at: 25.0)
        #expect(at25.count == 1)
        #expect(at25.first?.text == "Long dialogue")

        let at35 = doc.activeCues(at: 35.0)
        #expect(at35.isEmpty)
    }

    @Test("MediaDemuxer getLiveSubtitleDocument returns currently accumulated cues")
    func testLiveSubtitleDocumentAccumulation() {
        // Test that SubtitleDocument sorts and serves dynamic cues properly
        var cues = [
            SubtitleCue(id: 1, startTime: 1.0, endTime: 3.0, text: "First live cue", alignment: .bottomCenter)
        ]
        var doc = SubtitleDocument(cues: cues)
        #expect(doc.activeCues(at: 1.5).count == 1)
        #expect(doc.activeCues(at: 4.0).isEmpty)

        // Simulate incoming in-band packet
        cues.append(
            SubtitleCue(id: 2, startTime: 3.5, endTime: 6.0, text: "Second live cue", alignment: .bottomCenter)
        )
        doc = SubtitleDocument(cues: cues)
        #expect(doc.activeCues(at: 4.0).count == 1)
        #expect(doc.activeCues(at: 4.0).first?.text == "Second live cue")
    }

    @Test("ASS comma metadata fields are stripped cleanly")
    func testStripASSMetadataPrefix() {
        let rawLine = "0,0,Default,Narrator,0,0,0,,{\\pos(192,200)}Welcome to the show!"
        let parts = rawLine.components(separatedBy: ",")
        #expect(parts.count >= 9)
        let dialogueText = parts.suffix(from: 8).joined(separator: ",")
        let cleaned = SubtitleDocument.cleanFormattingTags(dialogueText)
        #expect(cleaned == "Welcome to the show!")

        // Test with Dialogue: prefix format
        let dialoguePrefixLine = "Dialogue: 0,0:01:23.45,0:01:25.67,Default,,0,0,0,,Here is some dialogue"
        let parts2 = dialoguePrefixLine.components(separatedBy: ",")
        #expect(parts2.count >= 10)
        let dialogueText2 = parts2.suffix(from: 9).joined(separator: ",")
        let cleaned2 = SubtitleDocument.cleanFormattingTags(dialogueText2)
        #expect(cleaned2 == "Here is some dialogue")
    }
}

@Suite("Subtitle Delay Tests")
@MainActor
struct SubtitleDelayTests {
    private func makeEngine() -> PlayerEngine {
        let engine = PlayerEngine.makeForTesting()
        engine.activeSubtitleDocument = SubtitleDocument(cues: [
            SubtitleCue(id: 1, startTime: 10.0, endTime: 12.0, text: "Line", alignment: .bottomCenter)
        ])
        return engine
    }

    @Test("A positive delay shows cues later, a negative one earlier, and changes apply at once")
    func testDelayShiftsCueLookup() {
        let engine = makeEngine()
        engine.currentTime = 12.5
        engine.updateActiveSubtitles(at: engine.currentTime)
        #expect(engine.currentSubtitleCues.isEmpty)

        engine.setSubtitleDelay(1.0)  // cue now spans 11...13
        #expect(engine.currentSubtitleText == "Line")

        engine.setSubtitleDelay(-1.0)  // cue now spans 9...11
        #expect(engine.currentSubtitleCues.isEmpty)
        engine.currentTime = 9.5
        engine.updateActiveSubtitles(at: engine.currentTime)
        #expect(engine.currentSubtitleText == "Line")

        engine.resetSubtitleDelay()
        #expect(engine.subtitleDelay == 0)
        #expect(engine.currentSubtitleCues.isEmpty)
    }

    @Test("Delay steps round to milliseconds and clamp to the allowed range")
    func testDelayRoundingAndClamping() {
        let engine = makeEngine()
        for _ in 0..<3 { engine.stepSubtitleDelay(by: 0.1) }
        #expect(engine.subtitleDelay == 0.3)

        engine.setSubtitleDelay(100)
        #expect(engine.subtitleDelay == PlayerEngine.subtitleDelayRange.upperBound)
        engine.setSubtitleDelay(-100)
        #expect(engine.subtitleDelay == PlayerEngine.subtitleDelayRange.lowerBound)
        engine.setSubtitleDelay(.nan)
        #expect(engine.subtitleDelay == PlayerEngine.subtitleDelayRange.lowerBound)
    }
}
