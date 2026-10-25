import CryptoKit
import Foundation
import Testing

@testable import NitsKit

/// What Nits asks SponsorBlock and reads of its answer; no request leaves the machine.
@Suite("SponsorBlock client")
struct SponsorBlockClientTests {
    @Test("Asks by the id's hash prefix, for chapters too")
    func asksByHashPrefix() throws {
        let url = try #require(SponsorBlockClient.requestURL(for: "dQw4w9WgXcQ"))
        let hash = SHA256.hash(data: Data("dQw4w9WgXcQ".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(url.path == "/api/skipSegments/\(hash.prefix(4))")
        #expect(!url.absoluteString.contains("dQw4w9WgXcQ"))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let actionTypes = try #require(query.first { $0.name == "actionTypes" }?.value)
        // The API answers `skip` segments only without it, no chapters.
        #expect(actionTypes.contains(#""chapter""#))
        // A `mute` span's picture is worth watching: no skip button for it.
        #expect(!actionTypes.contains(#""mute""#))
        #expect(query.first { $0.name == "categories" }?.value?.contains(#""chapter""#) == true)
    }

    @Test("Reads the segments of the video asked for out of its bucket")
    func readsSegmentsOfTheVideo() throws {
        let answer = """
            [{"videoID": "otherVideo1", "segments": [
               {"category": "sponsor", "actionType": "skip", "segment": [1, 2], "videoDuration": 100}]},
             {"videoID": "dQw4w9WgXcQ", "segments": [
               {"category": "sponsor", "actionType": "skip", "segment": [10.5, 30], "UUID": "a", "videoDuration": 212,
                "description": ""},
               {"category": "chapter", "actionType": "chapter", "segment": [0, 60], "videoDuration": 212,
                "description": "Verse"},
               {"category": "intro", "actionType": "skip", "segment": [5]}]}]
            """
        let segments = try SponsorBlockClient.segments(in: Data(answer.utf8), videoID: "dQw4w9WgXcQ")
        #expect(
            segments == [
                SponsorBlockSegment(category: "sponsor", start: 10.5, end: 30, videoDuration: 212),
                SponsorBlockSegment(category: "chapter", start: 0, end: 60, description: "Verse", videoDuration: 212),
            ])
        #expect(try SponsorBlockClient.segments(in: Data(answer.utf8), videoID: "notInBucket").isEmpty)
    }
}
