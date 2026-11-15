import Foundation

/// Where the initialization and the index of a file are, found in the file itself: for a DASH representation that is one
/// file (`SegmentBase`) and tells no `indexRange` (what YouTube's formats are: yt-dlp lists the files, not where their
/// `sidx` or `Cues` are). Read from the file's first bytes, as dash.js does (`SegmentBaseLoader` asks for the first 1500
/// bytes and goes on to the box it finds, `WebmSegmentBaseLoader` follows the `SeekHead` to the `Cues`).
///
/// An MP4's is the `sidx` the walk of its top-level boxes reaches (`SegmentIndex.locate(in:)`) and the bytes before it,
/// a WebM's the `Cues` (`MatroskaCues.locate(in:)`) and the start up to them, or up to the first cluster when the cues
/// come after the media. A file this does not read is refused with the reason, as one whose index range is wrong is.
package enum SingleFileLayout {
    /// What the walk found.
    package struct Found: Equatable, Sendable {
        /// The file from its first byte up to the index (or the first cluster): the `ftyp` and `moov`, the EBML header up to
        /// `Tracks`.
        package var initialization: ByteRange
        /// The `sidx` box, the `Cues` element.
        package var index: ByteRange
    }

    package enum Reading: Equatable, Sendable {
        case found(Found)
        /// The bytes held end before the walk could tell: the file's first `upTo` bytes at least.
        case needsStart(upTo: Int64)
        /// A WebM whose `Cues` come after its clusters (its `SeekHead` says where): the bytes at `offset` hold the element's
        /// header (`MatroskaCues.cues(inHeaderAt:header:initialization:)`); the initialization ends at `initEnd`.
        case needsCuesHeader(offset: Int64, initEnd: Int64)
    }

    /// How much of the file's start is asked for first: dash.js's 1500 bytes. Both formats' headers fit it (an MP4's
    /// `ftyp` + `moov` of a fragmented file is 700 bytes, a WebM's start to the cues 300).
    package static let firstRead: Int64 = 1536
    /// The most of a file's start that is read to find its layout (`moov` of a few hundred kilobytes at most).
    package static let startLimit: Int64 = 1 << 20
}

extension SegmentIndex {
    /// The `sidx` of an MP4 file whose first bytes are `data`: the top-level boxes up to the first with that type, which
    /// must come after the `moov` (the bytes before it are the initialization) and before the first fragment.
    package static func locate(in data: Data) throws(Failure) -> SingleFileLayout.Reading {
        let bytes = [UInt8](data)
        var position: Int64 = 0
        var sawMoov = false
        while true {
            // A box's header is 8 bytes, 16 with a 64-bit size.
            let remaining = Int64(bytes.count) - position
            guard remaining >= 8 else { return .needsStart(upTo: position + 16) }
            if remaining < 16, Self.boxHeader(bytes, at: Int(position)).size == 1 {
                return .needsStart(upTo: position + 16)
            }
            if let reading = try Self.step(bytes, &position, &sawMoov) { return reading }
        }
    }

    /// One box: the `sidx` found, or nil and `position` moved past the box.
    private static func step(
        _ bytes: [UInt8], _ position: inout Int64, _ sawMoov: inout Bool
    ) throws(Failure) -> SingleFileLayout.Reading? {
        let (declared, type) = Self.boxHeader(bytes, at: Int(position))
        var size = Int64(declared)
        if declared == 1 {
            var wide: UInt64 = 0
            for byte in bytes[(Int(position) + 8)..<(Int(position) + 16)] { wide = wide << 8 | UInt64(byte) }
            guard wide < UInt64(Int64.max / 4) else { throw .unreadable("a box of a size out of range") }
            size = Int64(wide)
        }
        guard declared != 0 else { throw .unreadable("a box that runs to the end of the file before the sidx") }
        let header: Int64 = declared == 1 ? 16 : 8
        guard size >= header else { throw .unreadable("a box smaller than its header") }
        switch type {
        case "sidx":
            guard sawMoov else { throw .unreadable("a sidx before the moov") }
            guard let initialization = ByteRange(offset: 0, length: position), position > 0,
                let index = ByteRange(offset: position, length: size)
            else { throw .unreadable("a sidx out of range") }
            return .found(.init(initialization: initialization, index: index))
        case "moov":
            sawMoov = true
        case "moof", "mdat":
            throw .unreadable("no sidx before the first fragment")
        default: break
        }
        position += size
        guard position <= SingleFileLayout.startLimit else {
            throw .unreadable("no sidx in the first \(SingleFileLayout.startLimit) bytes")
        }
        return nil
    }

    private static func boxHeader(_ bytes: [UInt8], at offset: Int) -> (size: UInt32, type: String) {
        let size = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
        return (size, type)
    }
}
