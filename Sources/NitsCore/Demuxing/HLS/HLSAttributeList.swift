import Foundation

/// A tag's attribute list (RFC 8216 4.2): `NAME=value` pairs separated by commas, a value being a decimal or
/// hexadecimal integer, a decimal float, a quoted string (which may hold commas), an enumerated string or a resolution.
///
/// Read leniently, as players read real playlists: a name is matched case-sensitively but anywhere a pair starts (not
/// inside `SUPPLEMENTAL-CODECS` for `CODECS`), whitespace around pairs is skipped, a quoted string that never closes
/// runs to the end of the line, and a word without `=` is dropped.
struct HLSAttributeList: Sendable, Equatable {
    private(set) var values: [String: String] = [:]
    /// The names whose value was quoted: an enumerated string (`TYPE=AUDIO`) and a quoted one (`URI="…"`) are told
    /// apart where the RFC types them differently (`CLOSED-CAPTIONS=NONE` and `CLOSED-CAPTIONS="cc"`).
    private(set) var quoted: Set<String> = []

    init(_ text: Substring) {
        var rest = text[...]
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " || $0 == "\t" || $0 == "," }
            guard let equals = rest.firstIndex(of: "=") else { break }
            // A word without `=` before the name (`A=1,JUNK,B=2`) is dropped.
            let head = rest[..<equals]
            let name = head[(head.lastIndex(of: ",").map(head.index(after:)) ?? head.startIndex)...]
                .trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: equals)...].drop { $0 == " " || $0 == "\t" }
            let value: Substring
            if rest.first == "\"" {
                let body = rest.dropFirst()
                let close = body.firstIndex(of: "\"") ?? body.endIndex
                value = body[..<close]
                rest = close < body.endIndex ? body[body.index(after: close)...] : body[body.endIndex...]
                quoted.insert(name)
            } else {
                let comma = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<comma]
                rest = rest[comma...]
                quoted.remove(name)
            }
            guard !name.isEmpty else { continue }
            values[name] = value.trimmingCharacters(in: quoted.contains(name) ? [] : .whitespaces)
        }
    }

    /// A value as written, quoted or not: a quoted string's, an enumerated string's (`TYPE=AUDIO`), and one the RFC
    /// quotes written bare (`GROUP-ID=aac`, `URI=key.bin`, which FFmpeg reads too).
    subscript(name: String) -> String? { values[name] }

    /// Whether the value was quoted, where the RFC's types tell two meanings apart (`CLOSED-CAPTIONS`).
    func isQuoted(_ name: String) -> Bool { quoted.contains(name) }

    /// A decimal integer; nil for one absent or malformed.
    func integer(_ name: String) -> Int? { values[name].flatMap { Int($0) } }

    /// A decimal floating-point number, signed or not.
    func float(_ name: String) -> Double? { values[name].flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil } }

    /// `YES` (true), `NO` (false), else nil.
    func bool(_ name: String) -> Bool? {
        switch values[name] {
        case "YES": true
        case "NO": false
        default: nil
        }
    }

    /// A hexadecimal sequence (`0x…` or `0X…`) as bytes, the first padded to a whole byte; nil for one absent or
    /// malformed.
    func hexadecimal(_ name: String) -> [UInt8]? {
        guard let value = values[name], value.hasPrefix("0x") || value.hasPrefix("0X") else { return nil }
        var digits = Array(value.dropFirst(2))
        // Digits only: `UInt8(_:radix:)` would take a sign.
        guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count % 2 == 1 { digits.insert("0", at: 0) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    /// A decimal resolution, `<width>x<height>`.
    func resolution(_ name: String) -> HLSResolution? {
        guard let value = values[name] else { return nil }
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return nil
        }
        return HLSResolution(width: width, height: height)
    }
}

/// A byte range, `<length>[@<offset>]` (`EXT-X-BYTERANGE`, `EXT-X-MAP`'s `BYTERANGE`).
struct HLSByteRange: Sendable, Equatable, Hashable {
    var offset: Int64
    var length: Int64

    /// Nil for a range past `Int64.max`, which a playlist from the network may write.
    init?(offset: Int64, length: Int64) {
        guard offset >= 0, length >= 0, offset <= Int64.max - length else { return nil }
        self.offset = offset
        self.length = length
    }

    var range: Range<Int64> { offset..<(offset + length) }

    /// The length and the offset if one is given; nil for a malformed range.
    static func parse(_ text: some StringProtocol) -> (length: Int64, offset: Int64?)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, let length = Int64(parts[0]), length >= 0 else { return nil }
        guard parts.count == 2 else { return (length, nil) }
        guard let offset = Int64(parts[1]), offset >= 0, offset <= Int64.max - length else { return nil }
        return (length, offset)
    }
}
