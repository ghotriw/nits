import Foundation

/// When a fragment of a fragmented MP4 starts in its stream, read from the start of the fragment's bytes (its `moov`
/// and `moof`, before the `mdat`): the track's timescale (`mdhd`) and the decode time of its first sample (`tfdt`).
///
/// YouTube's live stream gives its segments as numbered requests of one URL, each with its own initialization data,
/// whose lengths are not one (mostly 5 s, runs of 4.933 s, and the odd short one), so the time of a segment is not its
/// number times a length: it is read from the segment, with a `Range` request for its first kilobytes instead of its
/// body.
package enum FragmentStartTime {
    /// The start of the fragment in seconds, nil when `data` holds no `moov` timescale and `moof` decode time (it is
    /// too short, or not a fragment). `data` may end anywhere past the `moof`: the `mdat` is not read.
    package static func seconds(in data: Data) -> Double? {
        let bytes = [UInt8](data)
        var timescale: UInt32?
        var decodeTime: UInt64?

        // The boxes in `range`, each as (type, payload range). A box that runs past the end of the data is cut there.
        func boxes(in range: Range<Int>) -> [(type: String, payload: Range<Int>)] {
            var result: [(String, Range<Int>)] = []
            var position = range.lowerBound
            while position + 8 <= range.upperBound {
                var size = Int(readUInt32(bytes, position))
                let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
                var header = 8
                if size == 1 {
                    guard position + 16 <= range.upperBound else { break }
                    let large = readUInt64(bytes, position + 8)
                    guard large <= UInt64(Int.max) else { break }
                    size = Int(large)
                    header = 16
                } else if size == 0 {
                    size = range.upperBound - position
                }
                guard size >= header else { break }
                // (A size past the data, a corrupt `largesize` of nearly `Int.max` included, ends the walk: no sum of it.)
                let isCut = size > range.upperBound - position
                result.append((type, (position + header)..<(isCut ? range.upperBound : position + size)))
                if isCut { break }
                position += size
            }
            return result
        }

        func child(_ type: String, of range: Range<Int>) -> Range<Int>? {
            boxes(in: range).first { $0.type == type }?.payload
        }

        let top = 0..<bytes.count
        if let moov = child("moov", of: top),
            let mdhd = child("mdia", of: child("trak", of: moov) ?? 0..<0).flatMap({ child("mdhd", of: $0) }),
            mdhd.count >= 4
        {
            let version = bytes[mdhd.lowerBound]
            // version 0: creation, modification (4 bytes each); version 1: 8 bytes each.
            let offset = mdhd.lowerBound + 4 + (version == 1 ? 16 : 8)
            if offset + 4 <= mdhd.upperBound { timescale = readUInt32(bytes, offset) }
        }
        if let moof = child("moof", of: top), let tfdt = child("tfdt", of: child("traf", of: moof) ?? 0..<0),
            tfdt.count >= 4
        {
            let version = bytes[tfdt.lowerBound]
            let offset = tfdt.lowerBound + 4
            if version == 1, offset + 8 <= tfdt.upperBound {
                decodeTime = readUInt64(bytes, offset)
            } else if version == 0, offset + 4 <= tfdt.upperBound {
                decodeTime = UInt64(readUInt32(bytes, offset))
            }
        }
        guard let timescale, timescale > 0, let decodeTime else { return nil }
        return Double(decodeTime) / Double(timescale)
    }

    private static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at...(at + 3)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at...(at + 7)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
