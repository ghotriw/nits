import Foundation

/// The ID3 tag packed audio segments (raw AAC, AC-3, E-AC-3, MP3) start with: its `PRIV` frame
/// `com.apple.streaming.transportStreamTimestamp` is the MPEG-TS time (90 kHz, 33 bits) of the segment's first sample
/// (RFC 8216 3.4), which the segment's own bytes carry no timestamps for.
package enum HLSPackedAudioTag {
    /// The length of the ID3v2 tag `data` starts with (its header and body, and footer); nil when it starts with none.
    package static func length(_ data: Data) -> Int? {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes.starts(with: Array("ID3".utf8)), bytes[3] != 0xFF, bytes[4] != 0xFF,
            bytes[6..<10].allSatisfy({ $0 < 0x80 })
        else { return nil }
        let footer = bytes[5] & 0x10 != 0 ? 10 : 0
        return 10 + syncsafe(bytes[6..<10]) + footer
    }

    /// The `PRIV` transport stream timestamp of the ID3 tag `data` starts with: 90 kHz ticks; nil without one.
    static func transportStreamTimestamp(_ data: Data) -> Int64? {
        guard let length = length(data), data.count >= 10 else { return nil }
        let bytes = [UInt8](data.prefix(min(length, data.count)))
        let major = bytes[3]
        var position = 10
        if bytes[5] & 0x40 != 0, bytes.count >= 14 {
            // An extended header: v2.4 counts itself in its syncsafe size, v2.3 doesn't count its own 4 bytes.
            let size = major >= 4 ? syncsafe(bytes[10..<14]) : plain(bytes[10..<14]) + 4
            position += size
        }
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
        while position + 10 <= bytes.count, bytes[position] != 0 {
            let id = bytes[position..<position + 4]
            let size =
                major >= 4 ? syncsafe(bytes[position + 4..<position + 8]) : plain(bytes[position + 4..<position + 8])
            let body = position + 10
            guard size >= 0, body + size <= bytes.count else { return nil }
            if id.elementsEqual("PRIV".utf8), size == owner.count + 8,
                bytes[body..<body + owner.count].elementsEqual(owner)
            {
                let value = bytes[(body + owner.count)..<(body + size)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                return Int64(value & ((UInt64(1) << 33) - 1))
            }
            position = body + size
        }
        return nil
    }

    private static func syncsafe(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    private static func plain(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 8 | Int($1) }
    }
}
