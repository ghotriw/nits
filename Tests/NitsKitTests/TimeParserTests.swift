import Foundation
import NitsUI
import Testing

@Suite("TimeParser Tests")
struct TimeParserTests {
    @Test("Format seconds to MM:SS and HH:MM:SS")
    func testFormat() {
        #expect(TimeParser.format(seconds: 0) == "00:00")
        #expect(TimeParser.format(seconds: 9) == "00:09")
        #expect(TimeParser.format(seconds: 65) == "01:05")
        #expect(TimeParser.format(seconds: 3599) == "59:59")
        #expect(TimeParser.format(seconds: 3600) == "01:00:00")
        #expect(TimeParser.format(seconds: 3665) == "01:01:05")
        #expect(TimeParser.format(seconds: 7325) == "02:02:05")
        #expect(TimeParser.format(seconds: -5) == "00:00")
        #expect(TimeParser.format(seconds: Double.nan) == "00:00")
    }

    @Test("Format difference with sign")
    func testFormatDiff() {
        #expect(TimeParser.formatDiff(from: 10, to: 25) == "+00:15")
        #expect(TimeParser.formatDiff(from: 25, to: 10) == "-00:15")
        #expect(TimeParser.formatDiff(from: 10, to: 10) == "+00:00")
        #expect(TimeParser.formatDiff(from: 0, to: 3661) == "+01:01:01")
    }

    @Test("Format seek offset (seconds <= 60s, minutes and seconds > 60s)")
    func testFormatSeekOffset() {
        #expect(TimeParser.formatSeekOffset(0) == "+0s")
        #expect(TimeParser.formatSeekOffset(5) == "+5s")
        #expect(TimeParser.formatSeekOffset(-5) == "-5s")
        #expect(TimeParser.formatSeekOffset(10) == "+10s")
        #expect(TimeParser.formatSeekOffset(-10) == "-10s")
        #expect(TimeParser.formatSeekOffset(5.0416) == "+5s")
        #expect(TimeParser.formatSeekOffset(4.98) == "+5s")
        #expect(TimeParser.formatSeekOffset(-2.4) == "-2s")
        #expect(TimeParser.formatSeekOffset(0.2) == "+0s")
        #expect(TimeParser.formatSeekOffset(55) == "+55s")
        #expect(TimeParser.formatSeekOffset(60) == "+60s")
        #expect(TimeParser.formatSeekOffset(-60) == "-60s")
        #expect(TimeParser.formatSeekOffset(65) == "+1m 05s")
        #expect(TimeParser.formatSeekOffset(-65) == "-1m 05s")
        #expect(TimeParser.formatSeekOffset(70) == "+1m 10s")
        #expect(TimeParser.formatSeekOffset(90) == "+1m 30s")
        #expect(TimeParser.formatSeekOffset(120) == "+2m 00s")
        #expect(TimeParser.formatSeekOffset(125) == "+2m 05s")
        #expect(TimeParser.formatSeekOffset(3599) == "+59m 59s")
        #expect(TimeParser.formatSeekOffset(3600) == "+1h 00m 00s")
        #expect(TimeParser.formatSeekOffset(3665) == "+1h 01m 05s")
        #expect(TimeParser.formatSeekOffset(-0.02) == "+0s")
        #expect(TimeParser.formatSeekOffset(-0.0) == "+0s")
        #expect(TimeParser.formatSeekOffset(Double.nan) == "+0s")
        #expect(TimeParser.formatSeekOffset(Double.infinity) == "+0s")
        #expect(TimeParser.formatSeekOffset(-Double.infinity) == "+0s")
    }

    @Test("Parse colon-separated timestamps")
    func testParseColonSeparated() {
        let dur = 7200.0  // 2 hours
        let cur = 600.0  // 10 minutes

        // mm:ss
        #expect(TimeParser.parse(input: "14:30", currentTime: cur, duration: dur) == 870.0)
        #expect(TimeParser.parse(input: "01:05", currentTime: cur, duration: dur) == 65.0)
        #expect(TimeParser.parse(input: "1:5", currentTime: cur, duration: dur) == 65.0)
        #expect(TimeParser.parse(input: "0:0", currentTime: cur, duration: dur) == 0.0)
        #expect(TimeParser.parse(input: "10:59", currentTime: cur, duration: dur) == 659.0)

        // hh:mm:ss
        #expect(TimeParser.parse(input: "1:00:00", currentTime: cur, duration: dur) == 3600.0)
        #expect(TimeParser.parse(input: "01:23:45", currentTime: cur, duration: dur) == 5025.0)
        #expect(TimeParser.parse(input: "1:59:59", currentTime: cur, duration: dur) == 7199.0)

        // Invalid colon-separated: seconds or minutes >= 60
        #expect(TimeParser.parse(input: "10:90", currentTime: cur, duration: dur) == nil)
        #expect(TimeParser.parse(input: "10:60", currentTime: cur, duration: dur) == nil)
        #expect(TimeParser.parse(input: "1:75:30", currentTime: cur, duration: dur) == nil)
        #expect(TimeParser.parse(input: "1:20:60", currentTime: cur, duration: dur) == nil)

        // Relative with colon
        #expect(TimeParser.parse(input: "+1:30", currentTime: cur, duration: dur) == 690.0)
        #expect(TimeParser.parse(input: "-2:00", currentTime: cur, duration: dur) == 480.0)
    }

    @Test("Parse pure seconds and comma decimal separator")
    func testParseSeconds() {
        let dur = 3600.0
        let cur = 500.0

        #expect(TimeParser.parse(input: "45", currentTime: cur, duration: dur) == 45.0)
        #expect(TimeParser.parse(input: "120.5", currentTime: cur, duration: dur) == 120.5)

        // Comma decimal separator (European / Russian keyboard layout)
        #expect(TimeParser.parse(input: "120,5", currentTime: cur, duration: dur) == 120.5)
        #expect(TimeParser.parse(input: "+30,5", currentTime: cur, duration: dur) == 530.5)

        // Relative pure seconds
        #expect(TimeParser.parse(input: "+30", currentTime: cur, duration: dur) == 530.0)
        #expect(TimeParser.parse(input: "-60", currentTime: cur, duration: dur) == 440.0)
    }

    @Test("Parse unit strings in English and Russian with dot and comma")
    func testParseUnits() {
        let dur = 7200.0
        let cur = 1000.0

        // English
        #expect(TimeParser.parse(input: "45s", currentTime: cur, duration: dur) == 45.0)
        #expect(TimeParser.parse(input: "10m", currentTime: cur, duration: dur) == 600.0)
        #expect(TimeParser.parse(input: "1h", currentTime: cur, duration: dur) == 3600.0)
        #expect(TimeParser.parse(input: "1.5h", currentTime: cur, duration: dur) == 5400.0)
        #expect(TimeParser.parse(input: "1h 30m 15s", currentTime: cur, duration: dur) == 5415.0)
        #expect(TimeParser.parse(input: "+5m", currentTime: cur, duration: dur) == 1300.0)
        #expect(TimeParser.parse(input: "-30s", currentTime: cur, duration: dur) == 970.0)

        // Russian
        #expect(TimeParser.parse(input: "1ч 15мин", currentTime: cur, duration: dur) == 4500.0)
        #expect(TimeParser.parse(input: "1,5ч", currentTime: cur, duration: dur) == 5400.0)
        #expect(TimeParser.parse(input: "+10сек", currentTime: cur, duration: dur) == 1010.0)
        #expect(TimeParser.parse(input: "-2мин", currentTime: cur, duration: dur) == 880.0)
    }

    @Test("Parse percentage with dot and comma")
    func testParsePercentage() {
        let dur = 1000.0
        let cur = 200.0

        #expect(TimeParser.parse(input: "50%", currentTime: cur, duration: dur) == 500.0)
        #expect(TimeParser.parse(input: "25%", currentTime: cur, duration: dur) == 250.0)
        #expect(TimeParser.parse(input: "12,5%", currentTime: cur, duration: dur) == 125.0)
        #expect(TimeParser.parse(input: "100%", currentTime: cur, duration: dur) == 1000.0)
        #expect(TimeParser.parse(input: "0%", currentTime: cur, duration: dur) == 0.0)

        // Relative percentage
        #expect(TimeParser.parse(input: "+10%", currentTime: cur, duration: dur) == 300.0)
        #expect(TimeParser.parse(input: "-5%", currentTime: cur, duration: dur) == 150.0)
    }

    @Test("Clamping to duration bounds")
    func testClamping() {
        let dur = 600.0
        let cur = 50.0

        #expect(TimeParser.parse(input: "-100", currentTime: cur, duration: dur) == 0.0)
        #expect(TimeParser.parse(input: "+9999", currentTime: cur, duration: dur) == 600.0)
        #expect(TimeParser.parse(input: "200%", currentTime: cur, duration: dur) == 600.0)
    }

    @Test("Invalid strings return nil")
    func testInvalid() {
        let dur = 600.0
        let cur = 50.0

        #expect(TimeParser.parse(input: "", currentTime: cur, duration: dur) == nil)
        #expect(TimeParser.parse(input: "hello", currentTime: cur, duration: dur) == nil)
        #expect(TimeParser.parse(input: "   ", currentTime: cur, duration: dur) == nil)
        #expect(TimeParser.parse(input: "::", currentTime: cur, duration: dur) == nil)
    }
}
