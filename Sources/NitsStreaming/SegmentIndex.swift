import Foundation

/// The segment index (`sidx`, ISO/IEC 14496-12 8.16.3) of a representation that is one file (DASH's `SegmentBase`):
/// where each segment of the file is and when it plays. Read by the client's source (`DASHPlaylists`) to tell the file's
/// segments as a playlist's byte ranges.
///
/// An index may be several boxes: a chain (each box's last reference is the next box, with the rest of the file) or a
/// hierarchy (a box whose references are boxes, each followed by its media). Those inside the bytes read are read from
/// them; one a reference points to outside them is asked for (`Reading.needs`), as few times as `requestLimit` allows.
/// shaka-player reads one box only and refuses a hierarchy; dash.js asks for each box a reference points to.
package struct SegmentIndex: Equatable, Sendable {
    package struct Segment: Equatable, Sendable {
        /// Bytes, from the start of the file.
        package var offset: Int64
        package var size: Int64
        /// When it starts, in `timescale` units (from the index's earliest presentation time on).
        package var time: Int64
        package var duration: Int64
    }

    package var timescale: Int64
    /// Every segment starts with a stream access point (a keyframe): a switch or a seek to one decodes from its start.
    /// Said by the index, which a sound's may leave unsaid (every frame of it is one).
    package var startsWithSAP: Bool
    package var segments: [Segment]

    /// The most an index's bytes may be, all its boxes together: a file of hours has one of a few dozen kilobytes.
    package static let sizeLimit: Int64 = 1 << 20
    /// The most requests a hierarchy may take past the index range.
    package static let requestLimit = 16
    /// How much is asked for a box a reference points to, whose size is not known before: the box, if it is not larger.
    package static let boxProbeSize: Int64 = 16 << 10

    /// What a read of an index has come to.
    package enum Reading: Equatable, Sendable {
        case index(SegmentIndex)
        /// A box a reference points to is not among the bytes read: these bytes of the file hold it (at least its start).
        case needs(offset: Int64, length: Int64)
    }

    package enum Failure: Error, Equatable, Sendable {
        /// Not an index it reads: the reason.
        case unreadable(String)
    }

    /// The index from `chunks` (the bytes read, each from its offset in the file; the first is the index range).
    /// - Parameter external: The index is a file of its own (`RepresentationIndex@sourceURL`): its offsets count from
    ///   the start of the media file (shaka-player reads it so), not from the end of the box.
    package static func read(
        _ chunks: [(offset: Int64, data: Data)], external: Bool = false
    ) throws(Failure) -> Reading {
        guard !chunks.isEmpty else { throw .unreadable("no index") }
        var boxes: [Int64: Box] = [:]
        var rootOffset: Int64?
        for (chunkIndex, chunk) in chunks.enumerated() {
            for (offset, box) in try Self.boxes(in: chunk.data, at: chunk.offset, isIndexRange: chunkIndex == 0) {
                boxes[offset] = box
                if chunkIndex == 0, rootOffset == nil { rootOffset = offset }
            }
        }
        guard let rootOffset, let root = boxes[rootOffset] else { throw .unreadable("no sidx in the index range") }

        var segments: [Segment] = []
        var startsWithSAP = true
        /// The boxes being read, the deepest last, each with where its next reference is: walked without recursion, as
        /// a chain of a range's boxes is thousands deep.
        var path: [(box: Box, next: Int, offset: Int64, time: Int64)] = []
        var visited: Set<Int64> = []
        func enter(_ box: Box, at offset: Int64, time: Int64) throws(Failure) {
            guard box.timescale == root.timescale else { throw .unreadable("boxes of different timescales") }
            // A box two references point to would tell its segments twice.
            guard visited.insert(offset).inserted else { throw .unreadable("a sidx referenced twice") }
            path.append((box, 0, (external ? 0 : box.end) + box.firstOffset, time))
        }
        try enter(root, at: rootOffset, time: root.earliest)
        while let top = path.last {
            guard top.next < top.box.references.count else {
                path.removeLast()
                continue
            }
            let reference = top.box.references[top.next]
            path[path.count - 1].next += 1
            path[path.count - 1].offset += reference.size
            path[path.count - 1].time += reference.duration
            if reference.isIndex {
                guard !external else { throw .unreadable("an index of indexes in a file of its own") }
                guard let child = boxes[top.offset] else {
                    return .needs(offset: top.offset, length: min(reference.size, boxProbeSize))
                }
                try enter(child, at: top.offset, time: top.time)
            } else {
                segments.append(
                    Segment(offset: top.offset, size: reference.size, time: top.time, duration: reference.duration))
                startsWithSAP = startsWithSAP && reference.startsWithSAP
            }
        }
        guard !segments.isEmpty else { throw .unreadable("an index of no segments") }
        return .index(SegmentIndex(timescale: root.timescale, startsWithSAP: startsWithSAP, segments: segments))
    }

    /// The index in `data`, from byte `start` of the file, when it needs no more bytes (tests, and an index range that
    /// holds every box).
    package static func parse(_ data: Data, at start: Int64) -> SegmentIndex? {
        guard case .index(let index) = try? read([(start, data)]) else { return nil }
        return index
    }

    /// The bytes a `needs` asks for are a box larger than asked: its size, read from its header, or nil when the bytes
    /// held are the whole box (or no box).
    package static func boxSize(in data: Data) -> Int64? {
        let bytes = [UInt8](data.prefix(8))
        guard bytes.count == 8 else { return nil }
        let size = Int64(readUInt32(bytes, 0))
        return size > Int64(data.count) ? size : nil
    }

    // MARK: - Boxes

    private struct Reference {
        var isIndex: Bool
        var size: Int64
        package var duration: Int64
        var startsWithSAP: Bool
    }

    private struct Box {
        var timescale: Int64
        var earliest: Int64
        var firstOffset: Int64
        /// The offset in the file of the first byte after it.
        var end: Int64
        var references: [Reference]
    }

    /// The `sidx` boxes of `data` (from `start` of the file), by their offset. Reading stops at a box that runs past the
    /// bytes held (the media after a box asked for) or that is no box; in the index range a `sidx` cut short is an error.
    private static func boxes(in data: Data, at start: Int64, isIndexRange: Bool) throws(Failure) -> [(Int64, Box)] {
        let bytes = [UInt8](data)
        var position = 0
        var found: [(Int64, Box)] = []
        while position + 8 <= bytes.count {
            let size = Int(readUInt32(bytes, position))
            let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            // A box of 64-bit size (1), or one that runs to the end of the file (0): not what an index is.
            guard size >= 8 else { break }
            guard position + size <= bytes.count else {
                if type == "sidx" && (isIndexRange || found.isEmpty) { throw .unreadable("a sidx cut short") }
                break
            }
            if type == "sidx" {
                let box = try parseBox(
                    bytes, from: position + 8, to: position + size, end: start + Int64(position + size))
                found.append((start + Int64(position), box))
            }
            position += size
        }
        return found
    }

    private static func parseBox(_ bytes: [UInt8], from begin: Int, to end: Int, end fileEnd: Int64) throws(Failure)
        -> Box
    {
        var position = begin
        func take(_ count: Int) throws(Failure) -> Int {
            guard position + count <= end else { throw .unreadable("a sidx cut short") }
            defer { position += count }
            return position
        }
        let version = bytes[try take(4)]
        guard version <= 1 else { throw .unreadable("a sidx of version \(version)") }
        _ = try take(4)  // reference_ID
        let timescale = Int64(readUInt32(bytes, try take(4)))
        let earliest: UInt64
        let firstOffset: UInt64
        if version == 0 {
            let at = try take(8)
            earliest = UInt64(readUInt32(bytes, at))
            firstOffset = UInt64(readUInt32(bytes, at + 4))
        } else {
            let at = try take(16)
            earliest = readUInt64(bytes, at)
            firstOffset = readUInt64(bytes, at + 8)
        }
        guard timescale > 0 else { throw .unreadable("a sidx of timescale 0") }
        // Past these, sums of them could not be counted; no file is that large or that long.
        guard earliest < UInt64(Int64.max / 4), firstOffset < UInt64(Int64(Int32.max)) else {
            throw .unreadable("a sidx of times or offsets out of range")
        }
        let countAt = try take(4)
        let count = Int(bytes[countAt + 2]) << 8 | Int(bytes[countAt + 3])
        guard count > 0 else { throw .unreadable("a sidx of no references") }
        let referencesAt = try take(count * 12)
        var references: [Reference] = []
        references.reserveCapacity(count)
        for n in 0..<count {
            let at = referencesAt + n * 12
            let reference = readUInt32(bytes, at)
            let size = Int64(reference & 0x7fff_ffff)
            let duration = Int64(readUInt32(bytes, at + 4))
            guard size > 0, duration > 0 else { throw .unreadable("a sidx reference of no size or length") }
            references.append(
                Reference(
                    isIndex: reference & 0x8000_0000 != 0, size: size, duration: duration,
                    startsWithSAP: readUInt32(bytes, at + 8) & 0x8000_0000 != 0))
        }
        return Box(
            timescale: timescale, earliest: Int64(earliest), firstOffset: Int64(firstOffset), end: fileEnd,
            references: references)
    }

    private static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
