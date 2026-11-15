import Foundation

/// The segment index of a representation that is one WebM file (DASH's `SegmentBase` with `video/webm`, `audio/webm`):
/// the file's `Cues` (Matroska's seek index), read into the same `SegmentIndex` an MP4's `sidx` makes, so the client
/// tells the file's segments, each a `Cluster`, as byte ranges.
///
/// A cue says where a cluster starts (`CueClusterPosition`, from the first byte of the `Segment`'s data) and its time
/// (`CueTime`, in `TimecodeScale` ns); it says nothing of the cluster's size or length, so these are what is between
/// one cue and the next, and the last cluster ends with the `Segment` and the file's `Duration`. The file's start (the
/// EBML header, the `Segment`'s header, `Info`'s `TimecodeScale` and `Duration`) is the initialization range, which a
/// segment is played after anyway. dash.js (`WebmSegmentBaseLoader`) reads it the same way, and shaka-player's
/// `MatroskaIndexParser`: positions from the `Segment`'s data, the last cluster to the `Segment`'s end, a `Duration` the
/// file does not write is the last interval over again.
package enum MatroskaCues {
    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let info: UInt32 = 0x1549_A966
        static let cluster: UInt32 = 0x1F43_B675
        static let cues: UInt32 = 0x1C53_BB6B
        static let timecodeScale: UInt32 = 0x2A_D7B1
        static let duration: UInt32 = 0x4489
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueClusterPosition: UInt32 = 0xF1
    }

    /// Matroska's default `TimecodeScale`: a millisecond.
    private static let defaultTimecodeScale: Int64 = 1_000_000

    /// An EBML element's header: its id, where its content is and how long (`nil`: unknown, to the end of the parent).
    private struct Element {
        var id: UInt32
        var contentStart: Int
        var size: Int64?
    }

    private struct Reader {
        var bytes: [UInt8]

        /// The element whose header starts at `position`; nil when the bytes end inside it, or it is no element.
        func element(at position: Int) -> Element? {
            guard position < bytes.count else { return nil }
            let first = bytes[position]
            let idLength = first.leadingZeroBitCount + 1
            guard idLength <= 4, position + idLength < bytes.count else { return nil }
            let id = bytes[position..<(position + idLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let sizeAt = position + idLength
            let sizeFirst = bytes[sizeAt]
            let sizeLength = sizeFirst.leadingZeroBitCount + 1
            guard sizeLength <= 8, sizeAt + sizeLength <= bytes.count else { return nil }
            var value = UInt64(sizeFirst) & (0xFF >> UInt64(sizeLength))
            var isUnknown = value == (0xFF >> UInt64(sizeLength))
            for byte in bytes[(sizeAt + 1)..<(sizeAt + sizeLength)] {
                value = value << 8 | UInt64(byte)
                if byte != 0xFF { isUnknown = false }
            }
            guard isUnknown || value < UInt64(Int64.max / 4) else { return nil }
            return Element(id: id, contentStart: sizeAt + sizeLength, size: isUnknown ? nil : Int64(value))
        }

        /// The end of `element`'s content in the bytes held, and whether the bytes hold all of it.
        func end(of element: Element, within limit: Int) -> (end: Int, isWhole: Bool) {
            guard let size = element.size, size <= Int64(limit - element.contentStart) else { return (limit, false) }
            return (element.contentStart + Int(size), true)
        }

        func unsigned(_ element: Element, to end: Int) -> UInt64? {
            let count = end - element.contentStart
            guard (1...8).contains(count) else { return nil }
            return bytes[element.contentStart..<end].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        func float(_ element: Element, to end: Int) -> Double? {
            guard let bits = unsigned(element, to: end) else { return nil }
            switch end - element.contentStart {
            case 4: return Double(Float(bitPattern: UInt32(bits)))
            case 8: return Double(bitPattern: bits)
            default: return nil
            }
        }
    }

    /// The file's own numbers: where the `Segment`'s data starts and ends, the clock and the length of the file.
    private struct Header {
        var segmentStart: Int64
        var segmentEnd: Int64?
        var timecodeScale = MatroskaCues.defaultTimecodeScale
        /// In ticks of `timecodeScale`.
        var duration: Double?
    }

    /// The segments of the file whose first bytes are `header` (from its start: at least up to its `Info`) and whose
    /// `Cues` element is `cues` (the index range), which starts at byte `cuesOffset` of the file (nil: not told, a file of its
    /// own). Cues that come after the last cluster end it: what is past it (the `Cues` themselves) is no media.
    package static func read(
        header: Data, cues: Data, cuesOffset: Int64? = nil
    ) throws(SegmentIndex.Failure) -> SegmentIndex {
        let file = try Self.header(of: header)
        let points = try Self.cuePoints(in: cues)
        guard var segmentEnd = file.segmentEnd else { throw .unreadable("a Segment of unknown size") }
        if let cuesOffset, let last = points.last, cuesOffset > file.segmentStart + last.position {
            segmentEnd = min(segmentEnd, cuesOffset)
        }

        // Ticks to the index's units: a millisecond clock stays whole ticks; a scale that does not divide a second is
        // counted in nanoseconds.
        let isWhole = 1_000_000_000 % file.timecodeScale == 0
        let timescale = isWhole ? 1_000_000_000 / file.timecodeScale : 1_000_000_000
        let unitsPerTick = isWhole ? 1 : file.timecodeScale
        func units(_ ticks: Int64) throws(SegmentIndex.Failure) -> Int64 {
            let (value, overflow) = ticks.multipliedReportingOverflow(by: unitsPerTick)
            guard !overflow else { throw .unreadable("a cue time out of range") }
            return value
        }

        var lastDuration: Int64?
        if let total = file.duration, total.isFinite, total < Double(Int64.max / 4),
            let last = points.last, Int64(total) > last.time
        {
            lastDuration = Int64(total) - last.time
        } else if points.count > 1 {
            // A file that tells no length: the last cluster is as long as the one before.
            lastDuration = points[points.count - 1].time - points[points.count - 2].time
        }
        guard let lastDuration else { throw .unreadable("a file of no duration") }

        var segments: [SegmentIndex.Segment] = []
        segments.reserveCapacity(points.count)
        for (position, point) in points.enumerated() {
            let offset = file.segmentStart + point.position
            let isLast = position == points.count - 1
            let end = isLast ? segmentEnd : file.segmentStart + points[position + 1].position
            guard end > offset else { throw .unreadable("a cluster that starts past the Segment's end") }
            let duration = isLast ? lastDuration : points[position + 1].time - point.time
            segments.append(
                SegmentIndex.Segment(
                    offset: offset, size: end - offset, time: try units(point.time), duration: try units(duration)))
        }
        // A cluster that starts a segment starts at a keyframe: muxers cue the clusters they begin with one.
        return SegmentIndex(timescale: timescale, startsWithSAP: true, segments: segments)
    }

    /// The Segment's data from the EBML header on, and what `Info` tells.
    private static func header(of data: Data) throws(SegmentIndex.Failure) -> Header {
        let reader = Reader(bytes: [UInt8](data))
        guard let ebml = reader.element(at: 0), ebml.id == ID.ebml else { throw .unreadable("not a Matroska file") }
        let ebmlEnd = reader.end(of: ebml, within: reader.bytes.count)
        guard ebmlEnd.isWhole, let segment = reader.element(at: ebmlEnd.end), segment.id == ID.segment else {
            throw .unreadable("no Segment after the EBML header")
        }
        var header = Header(
            segmentStart: Int64(segment.contentStart),
            segmentEnd: segment.size.map { Int64(segment.contentStart) + $0 })
        var position = segment.contentStart
        while let element = reader.element(at: position), element.id != ID.cluster {
            let (end, isWhole) = reader.end(of: element, within: reader.bytes.count)
            guard isWhole else { break }
            if element.id == ID.info {
                var child = element.contentStart
                while child < end, let field = reader.element(at: child) {
                    let (fieldEnd, isFieldWhole) = reader.end(of: field, within: end)
                    guard isFieldWhole else { break }
                    switch field.id {
                    case ID.timecodeScale:
                        guard let scale = reader.unsigned(field, to: fieldEnd), scale > 0, scale < UInt64(Int64.max)
                        else { throw .unreadable("a TimecodeScale out of range") }
                        header.timecodeScale = Int64(scale)
                    case ID.duration:
                        header.duration = reader.float(field, to: fieldEnd)
                    default: break
                    }
                    child = fieldEnd
                }
            }
            position = end
        }
        // The start is the bytes before the clusters: one in them is a file whose index comes after its media, told
        // without its initialization (the bytes before the index are then all the file).
        if reader.element(at: position)?.id == ID.cluster { throw .unreadable("a start that holds a Cluster") }
        return header
    }

    /// The clusters the cues start, by their position (from the Segment's data), each with the time of its first cue
    /// (ticks); a cluster several cues point to (a keyframe a track has inside it) is one segment.
    private static func cuePoints(in data: Data) throws(SegmentIndex.Failure) -> [(position: Int64, time: Int64)] {
        let reader = Reader(bytes: [UInt8](data))
        guard let cues = reader.element(at: 0), cues.id == ID.cues else {
            throw .unreadable("no Cues in the index range")
        }
        let (cuesEnd, isWhole) = reader.end(of: cues, within: reader.bytes.count)
        guard isWhole else { throw .unreadable("Cues cut short") }
        var earliest: [Int64: Int64] = [:]
        var position = cues.contentStart
        while position < cuesEnd, let point = reader.element(at: position) {
            let (pointEnd, isPointWhole) = reader.end(of: point, within: cuesEnd)
            guard isPointWhole else { throw .unreadable("a CuePoint cut short") }
            defer { position = pointEnd }
            guard point.id == ID.cuePoint else { continue }
            var time: UInt64?
            var places: [UInt64] = []
            var child = point.contentStart
            while child < pointEnd, let field = reader.element(at: child) {
                let (fieldEnd, isFieldWhole) = reader.end(of: field, within: pointEnd)
                guard isFieldWhole else { throw .unreadable("a CuePoint cut short") }
                if field.id == ID.cueTime {
                    time = reader.unsigned(field, to: fieldEnd)
                } else if field.id == ID.cueTrackPositions {
                    var value = field.contentStart
                    while value < fieldEnd, let leaf = reader.element(at: value) {
                        let (leafEnd, isLeafWhole) = reader.end(of: leaf, within: fieldEnd)
                        guard isLeafWhole else { break }
                        if leaf.id == ID.cueClusterPosition, let cluster = reader.unsigned(leaf, to: leafEnd) {
                            places.append(cluster)
                        }
                        value = leafEnd
                    }
                }
                child = fieldEnd
            }
            // Past these sums of them could not be counted; no file is that large or that long.
            guard let time, time < UInt64(Int64.max / 4), !places.isEmpty,
                places.allSatisfy({ $0 < UInt64(Int64.max / 4) })
            else { throw .unreadable("a CuePoint of no time or position") }
            for place in places {
                let cluster = Int64(place)
                earliest[cluster] = min(earliest[cluster] ?? Int64(time), Int64(time))
            }
        }
        let points = earliest.map { (position: $0.key, time: $0.value) }.sorted { $0.position < $1.position }
        guard !points.isEmpty else { throw .unreadable("Cues of no clusters") }
        for (earlier, later) in zip(points, points.dropFirst()) where later.time <= earlier.time {
            throw .unreadable("clusters whose times do not follow their positions")
        }
        return points
    }
}
