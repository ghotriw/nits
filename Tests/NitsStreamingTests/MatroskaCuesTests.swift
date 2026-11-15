import Foundation
import Testing

@testable import NitsStreaming

/// A WebM file's `Cues` read into the segments of a DASH file (`SegmentBase`): each cluster a cue starts is one.
@Suite("Matroska cues")
struct MatroskaCuesTests {
    // MARK: Building the file's bytes

    /// An element: its id, a size of eight bytes (`size`, else the content's), and the content.
    static func element(_ id: [UInt8], _ content: [UInt8], size: UInt64? = nil, unknownSize: Bool = false) -> [UInt8] {
        let declared = unknownSize ? 0x00FF_FFFF_FFFF_FFFF : (size ?? UInt64(content.count))
        let bytes = [0x01] + (0..<7).map { UInt8(truncatingIfNeeded: declared >> UInt64(48 - 8 * $0)) }
        return id + bytes + content
    }

    static func unsigned(_ value: UInt64) -> [UInt8] {
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * $0)) }
        while bytes.count > 1, bytes[0] == 0 { bytes.removeFirst() }
        return bytes
    }

    /// The start of a file: the EBML header, the Segment's (`segmentSize` of data, which the bytes here are the first of),
    /// `Info` with its `TimecodeScale` and `Duration` (ticks).
    static func header(
        timecodeScale: UInt64? = 1_000_000, duration: Double? = 12000, segmentSize: UInt64 = 5000,
        unknownSize: Bool = false
    ) -> (data: Data, segmentStart: Int64) {
        var info: [UInt8] = []
        if let timecodeScale { info += element([0x2A, 0xD7, 0xB1], unsigned(timecodeScale)) }
        if let duration {
            let bits = duration.bitPattern
            info += element([0x44, 0x89], (0..<8).map { UInt8(truncatingIfNeeded: bits >> UInt64(56 - 8 * $0)) })
        }
        let ebml = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("webm".utf8)))
        let segmentHeader = element([0x18, 0x53, 0x80, 0x67], [], size: segmentSize, unknownSize: unknownSize)
        let bytes = ebml + segmentHeader + element([0x15, 0x49, 0xA9, 0x66], info)
        return (Data(bytes), Int64(ebml.count + segmentHeader.count))
    }

    /// A `Cues` element: a cue of (time, cluster position) each, as a track 1's.
    static func cues(_ points: [(time: UInt64, position: UInt64)]) -> Data {
        let cues = points.flatMap { point in
            element(
                [0xBB],
                element([0xB3], unsigned(point.time))
                    + element(
                        [0xB7], element([0xF7], [1]) + element([0xF1], unsigned(point.position))))
        }
        return Data(element([0x1C, 0x53, 0xBB, 0x6B], cues))
    }

    static let points: [(time: UInt64, position: UInt64)] = [(0, 300), (4000, 1300), (8000, 3000)]

    static func reason(_ header: Data, _ cues: Data) -> String? {
        do {
            _ = try MatroskaCues.read(header: header, cues: cues)
            return nil
        } catch {
            guard case .unreadable(let reason) = error else { return "\(error)" }
            return reason
        }
    }

    // MARK: Tests

    @Test(
        "Each cue's cluster is a segment: from the Segment's data, to the next cluster, the last to the Segment's end")
    func readsSegments() throws {
        let (header, start) = Self.header()
        let index = try MatroskaCues.read(header: header, cues: Self.cues(Self.points))
        #expect(index.timescale == 1000 && index.startsWithSAP)
        #expect(index.segments.map(\.offset) == [start + 300, start + 1300, start + 3000])
        #expect(index.segments.map(\.size) == [1000, 1700, 5000 - 3000])
        #expect(index.segments.map(\.time) == [0, 4000, 8000])
        #expect(index.segments.map(\.duration) == [4000, 4000, 4000])
    }

    @Test("A cluster several cues point to is one segment, whatever the order of the cues")
    func clustersOnce() throws {
        let (header, _) = Self.header()
        let cues = Self.cues([(8000, 3000), (0, 300), (2000, 300), (4000, 1300)])
        let index = try MatroskaCues.read(header: header, cues: cues)
        #expect(index.segments.map(\.time) == [0, 4000, 8000])
    }

    @Test("A file that tells no duration ends with the last interval over again")
    func noDuration() throws {
        let (header, _) = Self.header(duration: nil)
        let index = try MatroskaCues.read(header: header, cues: Self.cues(Self.points))
        #expect(index.segments.last?.duration == 4000)
    }

    @Test("The clock is the file's TimecodeScale: a scale of a whole division of a second keeps its ticks")
    func timecodeScale() throws {
        // 100 µs ticks: 10 000 to the second.
        let (fine, _) = Self.header(timecodeScale: 100_000, duration: 120_000)
        let index = try MatroskaCues.read(header: fine, cues: Self.cues([(0, 300), (40_000, 1300)]))
        #expect(index.timescale == 10_000)
        #expect(index.segments.map(\.duration) == [40_000, 80_000])
        // 3 ms ticks do not divide a second: counted in nanoseconds.
        let (odd, _) = Self.header(timecodeScale: 3_000_000, duration: 4000)
        let nanoseconds = try MatroskaCues.read(header: odd, cues: Self.cues([(0, 300), (1000, 1300)]))
        #expect(nanoseconds.timescale == 1_000_000_000)
        #expect(nanoseconds.segments.map(\.time) == [0, 3_000_000_000])
        // Without a TimecodeScale: a millisecond.
        let (none, _) = Self.header(timecodeScale: nil)
        #expect(try MatroskaCues.read(header: none, cues: Self.cues(Self.points)).timescale == 1000)
    }

    @Test("Cues after the last cluster end it: they are no media")
    func cuesEndTheLastCluster() throws {
        let (header, start) = Self.header()
        let index = try MatroskaCues.read(header: header, cues: Self.cues(Self.points), cuesOffset: start + 4000)
        #expect(index.segments.last?.size == 1000)
        // Cues before the clusters change nothing.
        let before = try MatroskaCues.read(header: header, cues: Self.cues(Self.points), cuesOffset: start + 100)
        #expect(before.segments.last?.size == 2000)
    }

    @Test("A TimecodeScale past a second is counted in nanoseconds")
    func largeScale() throws {
        let (header, _) = Self.header(timecodeScale: 2_000_000_000, duration: 5)
        let index = try MatroskaCues.read(header: header, cues: Self.cues([(0, 300), (2, 1300)]))
        #expect(index.timescale == 1_000_000_000)
        #expect(index.segments.map(\.time) == [0, 4_000_000_000])
    }

    @Test("A start that holds a cluster, and a cue of no time or position, are refused")
    func holdsAndGaps() {
        let (header, _) = Self.header()
        let withCluster = header + Data(Self.element([0x1F, 0x43, 0xB6, 0x75], [1, 2, 3]))
        #expect(Self.reason(withCluster, Self.cues(Self.points)) == "a start that holds a Cluster")
        let noTime = Data(
            Self.element(
                [0x1C, 0x53, 0xBB, 0x6B],
                Self.element([0xBB], Self.element([0xB7], Self.element([0xF1], Self.unsigned(300))))))
        #expect(Self.reason(header, noTime) == "a CuePoint of no time or position")
    }

    @Test("What is not an index it reads is refused with its reason")
    func refusals() {
        let (header, _) = Self.header()
        let cues = Self.cues(Self.points)
        #expect(Self.reason(Data("not a file".utf8), cues) == "not a Matroska file")
        #expect(Self.reason(header, Data("not cues".utf8)) == "no Cues in the index range")
        #expect(Self.reason(header, cues.dropLast(3)) == "Cues cut short")
        #expect(Self.reason(header, Self.cues([])) == "Cues of no clusters")
        // Times that go back along the file.
        #expect(
            Self.reason(header, Self.cues([(0, 300), (8000, 1300), (4000, 3000)]))
                == "clusters whose times do not follow their positions")
        #expect(Self.reason(Self.header(unknownSize: true).data, cues) == "a Segment of unknown size")
        // A cluster the Segment's end is not past.
        #expect(
            Self.reason(header, Self.cues([(0, 300), (4000, 6000)])) == "a cluster that starts past the Segment's end")
        #expect(Self.reason(Self.header(duration: nil).data, Self.cues([(0, 300)])) == "a file of no duration")
        #expect(Self.reason(Self.header(timecodeScale: 0).data, cues) == "a TimecodeScale out of range")
    }
}
