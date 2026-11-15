import Foundation
import Testing

@testable import NitsStreaming

/// Where the initialization and the index of a file are, found from the file's first bytes (`SingleFileLayout`): an MP4's
/// `sidx` after its `moov`, a WebM's `Cues` before its clusters or where the `SeekHead` says.
@Suite("Single file layout")
struct SingleFileLayoutTests {
    // MARK: MP4

    static func box(_ type: String, size: Int, wide: Bool = false) -> Data {
        func be(_ value: UInt64, _ count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * (count - 1 - $0))) }
        }
        if wide {
            return Data(be(1, 4) + Array(type.utf8) + be(UInt64(size), 8) + [UInt8](repeating: 0, count: size - 16))
        }
        return Data(be(UInt64(size), 4) + Array(type.utf8) + [UInt8](repeating: 0, count: size - 8))
    }

    static func read(_ data: Data) throws(SegmentIndex.Failure) -> SingleFileLayout.Reading {
        try SegmentIndex.locate(in: data)
    }

    @Test("The sidx after the moov is the index, the bytes before it the initialization")
    func mp4Found() throws {
        let file =
            Self.box("ftyp", size: 28) + Self.box("moov", size: 714) + Self.box("sidx", size: 488)
            + Self.box("moof", size: 100)
        let range = try #require(ByteRange(offset: 742, length: 488))
        #expect(
            try Self.read(file)
                == .found(.init(initialization: ByteRange(offset: 0, length: 742)!, index: range)))
        // The index may lie past the bytes read: its header is enough to tell where it is and how long.
        #expect(
            try Self.read(file.prefix(742 + 8))
                == .found(.init(initialization: ByteRange(offset: 0, length: 742)!, index: range)))
    }

    @Test("A box whose header is not all there is asked for; a 64-bit size is read")
    func mp4Truncated() throws {
        let file = Self.box("ftyp", size: 28) + Self.box("moov", size: 714) + Self.box("sidx", size: 488)
        #expect(try Self.read(Data()) == .needsStart(upTo: 16))
        #expect(try Self.read(file.prefix(30)) == .needsStart(upTo: 44))
        // Inside the moov: the next box starts past what is held.
        #expect(try Self.read(file.prefix(500)) == .needsStart(upTo: 742 + 16))
        let wide = Self.box("ftyp", size: 28) + Self.box("moov", size: 40, wide: true) + Self.box("sidx", size: 60)
        #expect(try Self.read(wide.prefix(28 + 12)) == .needsStart(upTo: 28 + 16))
        #expect(
            try Self.read(wide)
                == .found(
                    .init(initialization: ByteRange(offset: 0, length: 68)!, index: ByteRange(offset: 68, length: 60)!))
        )
    }

    @Test("What has no sidx where the profile puts it is refused with the reason")
    func mp4Refusals() {
        func reason(_ data: Data) -> String? {
            do throws(SegmentIndex.Failure) {
                _ = try Self.read(data)
                return nil
            } catch {
                guard case .unreadable(let reason) = error else { return nil }
                return reason
            }
        }
        let ftyp = Self.box("ftyp", size: 28)
        let moov = Self.box("moov", size: 100)
        #expect(reason(ftyp + Self.box("sidx", size: 60) + moov) == "a sidx before the moov")
        #expect(reason(ftyp + moov + Self.box("moof", size: 60)) == "no sidx before the first fragment")
        #expect(reason(ftyp + moov + Self.box("mdat", size: 60)) == "no sidx before the first fragment")
        #expect(
            reason(ftyp + Data([0, 0, 0, 0]) + Array("mdat".utf8))
                == "a box that runs to the end of the file before the sidx")
        #expect(reason(ftyp + Data([0, 0, 0, 4]) + Array("free".utf8)) == "a box smaller than its header")
        // A moov past what a start may be.
        let huge = Data([0x00, 0x20, 0x00, 0x00]) + Array("moov".utf8) + Data(count: 100)
        #expect(reason(ftyp + huge) == "no sidx in the first \(SingleFileLayout.startLimit) bytes")
    }

    // MARK: WebM

    private static let cuesID: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
    private static let clusterID: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]

    /// A `Segment` with its children, and where its data starts. `unknownSize`: a live-style `Segment`.
    static func webm(_ children: [[UInt8]], unknownSize: Bool = false) -> (data: Data, segmentStart: Int) {
        let ebml = MatroskaCuesTests.element(
            [0x1A, 0x45, 0xDF, 0xA3], MatroskaCuesTests.element([0x42, 0x82], Array("webm".utf8)))
        let content = children.flatMap { $0 }
        let segment = MatroskaCuesTests.element([0x18, 0x53, 0x80, 0x67], content, unknownSize: unknownSize)
        return (Data(ebml + segment), ebml.count + (segment.count - content.count))
    }

    static let info = MatroskaCuesTests.element(
        [0x15, 0x49, 0xA9, 0x66], MatroskaCuesTests.element([0x2A, 0xD7, 0xB1], [0x0F, 0x42, 0x40]))
    static let tracks = MatroskaCuesTests.element([0x16, 0x54, 0xAE, 0x6B], [UInt8](repeating: 1, count: 20))
    static let cues = [UInt8](MatroskaCuesTests.cues([(0, 300), (4000, 1300)]))
    static let cluster = MatroskaCuesTests.element(clusterID, [UInt8](repeating: 2, count: 50))

    /// A `SeekHead` that says the cues are `position` from the Segment's data.
    static func seekHead(cuesAt position: UInt64) -> [UInt8] {
        let seek = MatroskaCuesTests.element(
            [0x4D, 0xBB],
            MatroskaCuesTests.element([0x53, 0xAB], cuesID)
                + MatroskaCuesTests.element([0x53, 0xAC], MatroskaCuesTests.unsigned(position)))
        return MatroskaCuesTests.element([0x11, 0x4D, 0x9B, 0x74], seek)
    }

    private static func locate(_ data: some DataProtocol) throws(SegmentIndex.Failure) -> SingleFileLayout.Reading {
        try MatroskaCues.locate(in: Data(data))
    }

    @Test("Cues before the clusters are the index, the start up to them the initialization")
    func webmCuesFirst() throws {
        let (file, segmentStart) = Self.webm([
            Self.seekHead(cuesAt: 0), Self.info, Self.tracks, Self.cues, Self.cluster,
        ])
        let cuesAt = segmentStart + Self.seekHead(cuesAt: 0).count + Self.info.count + Self.tracks.count
        let reading = try Self.locate(file)
        #expect(
            reading
                == .found(
                    .init(
                        initialization: ByteRange(offset: 0, length: Int64(cuesAt))!,
                        index: ByteRange(offset: Int64(cuesAt), length: Int64(Self.cues.count))!)))
        // Without a SeekHead, the walk finds them as well; with the bytes cut after the Cues' header too.
        let (plain, _) = Self.webm([Self.info, Self.tracks, Self.cues])
        guard case .found(let found) = try Self.locate(plain) else {
            Issue.record("Not found")
            return
        }
        #expect(found.index.length == Int64(Self.cues.count))
        guard case .found = try Self.locate(file.prefix(cuesAt + 12)) else {
            Issue.record("Header only")
            return
        }
    }

    @Test("A start cut short is asked for further, a SeekHead whole")
    func webmTruncated() throws {
        let head = Self.seekHead(cuesAt: 400)
        let (file, segmentStart) = Self.webm([head, Self.info, Self.tracks, Self.cluster])
        #expect(try Self.locate(Data()) == .needsStart(upTo: 16))
        #expect(try Self.locate(file.prefix(5)) == .needsStart(upTo: 16))
        // Inside the SeekHead: the whole element is needed, which tells where the cues are.
        #expect(
            try Self.locate(file.prefix(segmentStart + 12 + 5)) == .needsStart(upTo: Int64(segmentStart + head.count)))
        // Inside Tracks (skipped by its header): the next element's header is asked for.
        let tracksAt = segmentStart + head.count + Self.info.count
        #expect(
            try Self.locate(file.prefix(tracksAt + 20)) == .needsStart(upTo: Int64(tracksAt + Self.tracks.count + 16)))
    }

    @Test("Cues after the media are where the SeekHead says; the initialization ends at the first cluster")
    func webmCuesLast() throws {
        let cuesPosition = UInt64(Self.info.count + Self.tracks.count + Self.cluster.count * 3 + 40)
        let head = Self.seekHead(cuesAt: cuesPosition)
        // The SeekHead's own size does not move the position: it counts from the Segment's data, which it is the start of.
        let (file, segmentStart) = Self.webm([head, Self.info, Self.tracks, Self.cluster])
        let clusterAt = segmentStart + head.count + Self.info.count + Self.tracks.count
        guard case .needsCuesHeader(let offset, let initEnd) = try Self.locate(file) else {
            Issue.record("Not asked for the header")
            return
        }
        #expect(offset == Int64(segmentStart) + Int64(cuesPosition) && initEnd == Int64(clusterAt))
        let found = try MatroskaCues.cues(atHeader: Data(Self.cues.prefix(16)), offset: offset, initEnd: initEnd)
        #expect(found.initialization == ByteRange(offset: 0, length: initEnd))
        #expect(found.index == ByteRange(offset: offset, length: Int64(Self.cues.count)))
        #expect(throws: SegmentIndex.Failure.self) {
            try MatroskaCues.cues(atHeader: Data(Self.cluster.prefix(16)), offset: offset, initEnd: initEnd)
        }
    }

    @Test("What is not a file of this profile is refused with the reason")
    func webmRefusals() {
        func reason(_ data: Data) -> String? {
            do throws(SegmentIndex.Failure) {
                _ = try MatroskaCues.locate(in: data)
                return nil
            } catch {
                guard case .unreadable(let reason) = error else { return nil }
                return reason
            }
        }
        #expect(
            reason(Self.webm([Self.info, Self.tracks, Self.cues], unknownSize: true).data)
                == "a Segment of unknown size")
        #expect(reason(Self.webm([Self.info, Self.cues]).data) == "clusters or cues before Info and Tracks")
        #expect(
            reason(Self.webm([Self.info, Self.tracks, Self.cluster]).data)
                == "no Cues before the first cluster, none in the SeekHead")
        #expect(reason(Data(repeating: 0x20, count: 40)) == "not a Matroska file")
        #expect(
            reason(Self.webm([Self.info, Self.tracks, Self.seekHead(cuesAt: 1), Self.cluster]).data)
                == "a SeekHead whose Cues are inside the start")
    }
}
