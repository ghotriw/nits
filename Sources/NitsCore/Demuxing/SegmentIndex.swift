import Foundation

/// The segment index (`sidx`) of a representation that is one file (DASH's `SegmentBase` with an `indexRange`): where
/// each segment of the file is, which a manifest of the file's segments (`SegmentList`, `mediaRange`) says in place
/// of it. FFmpeg's DASH demuxer does not read `SegmentBase`: it reads such a file from its start, to seek in it as
/// well. FFmpeg seeks a `SegmentList` by one length for all its segments, or by a `SegmentTimeline` that only the
/// adaptation set's list (not the representation's) may hold: the lengths are said that way when they are not one.
package struct SegmentIndex: Equatable, Sendable {
    package struct Segment: Equatable, Sendable {
        /// Bytes, from the start of the file.
        package var offset: Int64
        package var size: Int64
    }

    /// Every segment is as long as the first, but for the last, which may be shorter: the demuxer seeks by one length
    /// for all (`SegmentList`'s `duration`). Else it is told them (`SegmentTimeline`).
    package var isRegular: Bool {
        durations.dropLast().allSatisfy { $0 == durations[0] } && (durations.last ?? 0) <= durations[0]
    }

    /// The lengths as a `SegmentTimeline` has them: a run of equal ones is one `S` with its repeats.
    package var runs: [(duration: UInt32, repeats: Int)] {
        var result: [(duration: UInt32, repeats: Int)] = []
        for duration in durations {
            if let last = result.last, last.duration == duration {
                result[result.count - 1].repeats += 1
            } else {
                result.append((duration, 0))
            }
        }
        return result
    }

    package var timescale: UInt32
    /// Every segment starts with a stream access point (a keyframe): a seek to one decodes from its start. Said by
    /// the index, which a sound's may leave unsaid (every frame of it is one).
    package var startsWithSAP = true
    /// The length of each segment in `timescale` units.
    package var durations: [UInt32]
    package var segments: [Segment]

    /// The index in `data`, which came from byte `start` of the file (the `indexRange`). Nil for an index the demuxer
    /// could not be given as a list: more than one `sidx`, an index of indexes, or a presentation that starts well
    /// after zero (a tenth of the first segment): the demuxer seeks by the lengths of the segments from zero.
    package static func parse(_ data: Data, at start: Int64) -> SegmentIndex? {
        let bytes = [UInt8](data)
        var position = 0
        var index: SegmentIndex?
        while position + 8 <= bytes.count {
            let size = Int(readUInt32(bytes, position))
            let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            // A box of 64-bit size, or one that runs to the end of the file: not what an index range holds.
            guard size >= 8, position + size <= bytes.count else { return nil }
            if type == "sidx" {
                // The offsets count from the first byte after the box.
                guard index == nil,
                    let parsed = parseBox(
                        bytes, from: position + 8, to: position + size, boxEnd: start + Int64(position + size))
                else { return nil }
                index = parsed
            }
            position += size
        }
        return index
    }

    private static func parseBox(_ bytes: [UInt8], from begin: Int, to end: Int, boxEnd: Int64) -> SegmentIndex? {
        var position = begin
        func take(_ count: Int) -> Int? {
            guard position + count <= end else { return nil }
            defer { position += count }
            return position
        }
        guard let versionAt = take(4) else { return nil }
        let version = bytes[versionAt]
        guard version <= 1, take(4) != nil, let timescaleAt = take(4) else { return nil }
        let timescale = readUInt32(bytes, timescaleAt)
        let earliest: UInt64
        let firstOffset: UInt64
        if version == 0 {
            guard let at = take(8) else { return nil }
            earliest = UInt64(readUInt32(bytes, at))
            firstOffset = UInt64(readUInt32(bytes, at + 4))
        } else {
            guard let at = take(16) else { return nil }
            earliest = readUInt64(bytes, at)
            firstOffset = readUInt64(bytes, at + 8)
        }
        guard timescale > 0, firstOffset < UInt64(Int32.max), let countAt = take(4) else { return nil }
        let count = Int(bytes[countAt + 2]) << 8 | Int(bytes[countAt + 3])
        guard count > 0, take(count * 12) != nil else { return nil }
        var offset = boxEnd + Int64(firstOffset)
        var segments: [Segment] = []
        var startsWithSAP = true
        var durations: [UInt32] = []
        for n in 0..<count {
            let at = position - count * 12 + n * 12
            let reference = readUInt32(bytes, at)
            startsWithSAP = startsWithSAP && readUInt32(bytes, at + 8) & 0x8000_0000 != 0
            let isIndex = reference & 0x8000_0000 != 0
            let size = Int64(reference & 0x7fff_ffff)
            let duration = readUInt32(bytes, at + 4)
            guard !isIndex, size > 0, duration > 0 else { return nil }
            segments.append(Segment(offset: offset, size: size))
            durations.append(duration)
            offset += size
        }
        let regular = durations[0]

        // The presentation may start a little late (the delay of B-frames: a tenth of a segment at most), as the
        // demuxer seeks by the length of a segment from zero: a seek just past a boundary lands that late.
        guard earliest <= UInt64(regular / 10) else { return nil }
        return SegmentIndex(
            timescale: timescale, startsWithSAP: startsWithSAP, durations: durations, segments: segments)
    }

    private static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
