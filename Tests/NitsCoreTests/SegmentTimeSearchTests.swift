import Foundation
import Testing
import os

@testable import NitsCore

/// The start time of a fragment of a fragmented MP4, and the search of the segment that holds a moment by those times.
@Suite("Segment times")
struct SegmentTimeSearchTests {
    // MARK: Fragment header

    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + payload
    }

    private static func uint32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    private static func uint64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

    /// A fragment's start: `moov` with the track's `mdhd`, `moof` with the `tfdt`, and an `mdat` of `mediaBytes`.
    private static func fragment(
        timescale: UInt32 = 90000, decodeTime: UInt64, mdhdVersion: UInt8 = 0, tfdtVersion: UInt8 = 1,
        mediaBytes: Int = 100
    ) -> [UInt8] {
        let mdhdBody: [UInt8] =
            mdhdVersion == 1
            ? [1, 0, 0, 0] + uint64(0) + uint64(0) + uint32(timescale) + uint64(0)
            : [0, 0, 0, 0] + uint32(0) + uint32(0) + uint32(timescale) + uint32(0)
        let mdhd = box("mdhd", mdhdBody)
        let trak = box("trak", box("mdia", mdhd + box("hdlr", [UInt8](repeating: 0, count: 8))))
        let moov = box("moov", box("mvhd", [UInt8](repeating: 0, count: 20)) + trak)
        let tfdtBody: [UInt8] =
            tfdtVersion == 1
            ? [1, 0, 0, 0] + uint64(decodeTime) : [0, 0, 0, 0] + uint32(UInt32(decodeTime))
        let moof = box(
            "moof",
            box("mfhd", [0, 0, 0, 0, 0, 0, 0, 1]) + box("traf", box("tfhd", [0, 0, 0, 0]) + box("tfdt", tfdtBody)))
        return box("ftyp", Array("dash".utf8) + [0, 0, 0, 0]) + moov + moof
            + box("mdat", [UInt8](repeating: 7, count: mediaBytes))
    }

    @Test("The start comes from the track's timescale and the first sample's decode time")
    func readsStart() {
        let data = Data(Self.fragment(decodeTime: 90000 * 1_549_013 + 60000))
        #expect(FragmentStartTime.seconds(in: data) == 1_549_013 + 60000.0 / 90000)
    }

    @Test("Version 0 boxes are read as well as version 1")
    func readsOldVersions() {
        let data = Data(Self.fragment(timescale: 1000, decodeTime: 12345, mdhdVersion: 0, tfdtVersion: 0))
        #expect(FragmentStartTime.seconds(in: data) == 12.345)
        let wide = Data(Self.fragment(timescale: 48000, decodeTime: 96000, mdhdVersion: 1, tfdtVersion: 1))
        #expect(FragmentStartTime.seconds(in: wide) == 2)
    }

    @Test("A request for the first kilobytes is enough: the media data may be cut off")
    func readsCutFragment() {
        let whole = Self.fragment(decodeTime: 180_000, mediaBytes: 100_000)
        let moofEnd = whole.count - 100_000 - 8
        for length in [moofEnd, moofEnd + 8, moofEnd + 300] {
            #expect(FragmentStartTime.seconds(in: Data(whole.prefix(length))) == 2, "\(length) bytes")
        }
    }

    @Test("A box whose size is a corrupt largesize reads as nothing, and does not overflow")
    func refusesAHugeBox() {
        var bytes = Self.box("ftyp", Array("dash".utf8))
        // A `moov` with the size field 1 and a largesize of Int.max: the sum with its position would overflow.
        bytes += Self.uint32(1) + Array("moov".utf8) + Self.uint64(UInt64(Int.max))
        bytes += Self.uint32(1) + Array("moof".utf8) + Self.uint64(UInt64.max - 1)
        #expect(FragmentStartTime.seconds(in: Data(bytes)) == nil)
        // And a size that runs past the data by a little, the cut-off fragment a range gives, still reads.
        let whole = Self.fragment(decodeTime: 90_000)
        #expect(FragmentStartTime.seconds(in: Data(whole.prefix(whole.count - 40))) == 1)
    }

    @Test("What is not a fragment, or ends before its decode time, reads as nothing")
    func refusesWhatIsNotAFragment() {
        let whole = Self.fragment(decodeTime: 180_000)
        let moofStart = (whole.indices.first { whole[$0...].starts(with: Array("moof".utf8)) } ?? 4) - 4
        #expect(FragmentStartTime.seconds(in: Data()) == nil)
        #expect(FragmentStartTime.seconds(in: Data("<html>404</html>".utf8)) == nil)
        #expect(FragmentStartTime.seconds(in: Data(whole.prefix(moofStart))) == nil, "a header without its moof")
        #expect(FragmentStartTime.seconds(in: Data(whole.prefix(whole.count - 100 - 8 - 6))) == nil, "a cut tfdt")
        #expect(FragmentStartTime.seconds(in: Data(Self.fragment(timescale: 0, decodeTime: 5))) == nil)
    }

    // MARK: History

    @Test("The oldest segment the server has is found in a few probes, never asked for far past the edge")
    func findsOldest() async throws {
        for oldest in [1, 2, 20, 719, 720, 5000, 99_999, 330_000] {
            let probes = OSAllocatedUnfairLock(initialState: 0)
            let farthestPast = OSAllocatedUnfairLock(initialState: 0)
            let found = try await SegmentTimeSearch.oldestAvailable(upTo: 330_100) { number in
                probes.withLock { $0 += 1 }
                farthestPast.withLock { $0 = max($0, oldest - number) }
                return number >= oldest
            }
            #expect(found == oldest, "edge at \(oldest)")
            // Doubling strides, then the stride of 8640 along the history, and rounds of eight in the last stretch.
            #expect(
                probes.withLock { $0 } <= 12 + 330_100 / 8640 + 8 * 5,
                "\(probes.withLock { $0 }) probes, edge at \(oldest)")
            #expect(farthestPast.withLock { $0 } <= 8640, "asked \(farthestPast.withLock { $0 }) past the edge")
        }
    }
    @Test("A tolerance ends the search with a segment that is there, no farther from the edge than it")
    func oldestWithTolerance() async throws {
        for oldest in [1000, 12_345, 100_001] {
            let probes = OSAllocatedUnfairLock(initialState: 0)
            let found = try await SegmentTimeSearch.oldestAvailable(upTo: 200_000, tolerance: 360) { number in
                probes.withLock { $0 += 1 }
                return number >= oldest
            }
            #expect(found >= oldest && found - oldest <= 360, "edge at \(oldest): \(found)")
            #expect(probes.withLock { $0 } < 80, "\(probes.withLock { $0 }) probes")
        }
    }

    @Test("A stream the server has from its first segment, or has none but the newest")
    func oldestAtTheEnds() async throws {
        #expect(try await SegmentTimeSearch.oldestAvailable(upTo: 3000) { _ in true } == 0)
        #expect(try await SegmentTimeSearch.oldestAvailable(upTo: 3000) { $0 == 3000 } == 3000)
        #expect(try await SegmentTimeSearch.oldestAvailable(upTo: 50, floor: 40) { _ in true } == 40)
        #expect(try await SegmentTimeSearch.oldestAvailable(upTo: 41, floor: 40) { $0 > 40 } == 41)
    }

    @Test("A failed answer fails the search")
    func oldestPropagatesFailure() async {
        struct Down: Error {}
        await #expect(throws: Down.self) {
            _ = try await SegmentTimeSearch.oldestAvailable(upTo: 1000) { number in
                if number == 0 { return false }
                throw Down()
            }
        }
    }

    // MARK: Manifest window

    @Test("A window's segments take the length that fits the anchors they lie between")
    func windowRuns() throws {
        let window = try #require(
            SegmentedDASHManifest.window(
                through: [
                    .init(number: 100, time: 1000), .init(number: 110, time: 1050),
                    .init(number: 120, time: 1098.5),
                ], lastNumber: 124, lastDuration: 5))
        #expect(window.firstNumber == 100)
        #expect(window.startTime == 1000)
        #expect(
            window.runs == [
                .init(duration: 5, count: 10), .init(duration: 4.85, count: 10), .init(duration: 5, count: 5),
            ])
    }

    @Test("A window needs an anchor and a length for the last segment; anchors past the end are ignored")
    func windowNeedsAnchors() throws {
        #expect(SegmentedDASHManifest.window(through: [], lastNumber: 5, lastDuration: 5) == nil)
        #expect(
            SegmentedDASHManifest.window(through: [.init(number: 1, time: 0)], lastNumber: 5, lastDuration: 0) == nil)
        let window = try #require(
            SegmentedDASHManifest.window(
                through: [.init(number: 10, time: 50), .init(number: 99, time: 500)], lastNumber: 12, lastDuration: 5))
        #expect(window.runs == [.init(duration: 5, count: 3)])
    }

    @Test("The manifest of a window numbers its segments from the first, on the stream's own timeline")
    func windowText() throws {
        let window = try #require(
            SegmentedDASHManifest.window(
                through: [.init(number: 311_256, time: 1_549_013.667), .init(number: 311_266, time: 1_549_063.0)],
                lastNumber: 311_270, lastDuration: 5))
        var manifest = SegmentedDASHManifest(
            streams: [.init(kind: .video, id: "134", container: "mp4", url: "https://example.com/videoplayback?id=1")],
            segmentDuration: 5, segmentCount: 15)
        manifest.firstNumber = window.firstNumber
        manifest.startTime = window.startTime
        manifest.runs = window.runs
        let text = manifest.text()
        #expect(text.contains(#"startNumber="311256""#))
        // Every run says where it starts (from the exact lengths, 49.333 s after the first), not only the first.
        #expect(text.contains(#"<S t="1549013667" d="4933" r="9"/><S t="1549063000" d="5000" r="4"/>"#), "\(text)")
        #expect(text.contains(#"mediaPresentationDuration="PT74.33S""#), "\(text)")
        #expect(text.contains("sq=$Number$"))
    }

    @Test("A recording's manifest is as it was: from segment 0 at time 0, one length")
    func recordingTextUnchanged() {
        let manifest = SegmentedDASHManifest(
            streams: [.init(kind: .audio, id: "140", container: "mp4", url: "https://example.com/a")],
            segmentDuration: 5, segmentCount: 3)
        let text = manifest.text()
        #expect(text.contains(#"startNumber="0""#))
        #expect(text.contains(#"<SegmentTimeline><S t="0" d="5000" r="2"/></SegmentTimeline>"#), "\(text)")
        #expect(text.contains(#"mediaPresentationDuration="PT15.0S""#))
    }
}
