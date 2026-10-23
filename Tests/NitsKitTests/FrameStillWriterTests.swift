import Foundation
import NitsCore
import Testing

@testable import NitsKit

@Suite("Frame Still Writer")
struct FrameStillWriterTests {
    @Test func namesFileAfterTitleAndTime() {
        #expect(FrameStillWriter.fileName(title: "Film", pts: 3723.456) == "Film 01-02-03.456")
    }

    @Test func replacesCharactersPathsReject() {
        #expect(FrameStillWriter.fileName(title: "A/B: C", pts: 0) == "A-B- C 00-00-00.000")
    }

    @Test func untitledMediaIsNamedAfterThePlayer() {
        #expect(FrameStillWriter.fileName(title: " . ", pts: .nan) == "Nits 00-00-00.000")
    }

    @Test func neverOverwritesAnEarlierStill() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frame = CapturedFrame(data: Data([1, 2, 3]), contentType: .png, pts: 1, isHDR: false)
        let first = try FrameStillWriter.write(frame, title: "Film", in: directory)
        let second = try FrameStillWriter.write(frame, title: "Film", in: directory)
        #expect(first.lastPathComponent == "Film 00-00-01.000.png")
        #expect(second.lastPathComponent == "Film 00-00-01.000 2.png")
    }
}
