import Foundation

/// How subtitle text files are decoded: by their byte order mark, else the first of a few encodings that decodes them.
/// Windows-1251 decodes nearly any bytes, so a file that isn't UTF-8 is taken for Cyrillic; other single-byte code
/// pages (Windows-1250, Windows-1252 with characters 1251 also has) come out wrong.
enum SubtitleTextEncoding {
    /// Tried in order for a file without a byte order mark.
    static let candidates: [String.Encoding] = [.utf8, .windowsCP1251, .windowsCP1252, .isoLatin1]

    /// The encoding of `data`, the whole file or (`isPrefix`) its beginning, which may end inside a UTF-8 character.
    static func detect(_ data: Data, isPrefix: Bool = false) -> String.Encoding? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return .utf16 }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        return candidates.first { encoding in
            if encoding == .utf8, isPrefix {
                // A cut character takes up to three bytes at the end; something must be left to decode.
                return (0...max(0, min(3, data.count - 1))).contains {
                    String(data: data.dropLast($0), encoding: .utf8) != nil
                }
            }
            return String(data: data, encoding: encoding) != nil
        }
    }

    /// The text of a whole file, `nil` when no encoding decodes it.
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        guard let encoding = detect(data), let text = String(data: data, encoding: encoding) else { return nil }
        return (text, encoding)
    }

    /// Whether the beginning of a file is binary rather than text: zero bytes, which text has none of outside UTF-16
    /// (a VobSub `.sub` without its index is MPEG program stream).
    static func looksBinary(_ prefix: Data) -> Bool {
        detect(prefix, isPrefix: true) != .utf16 && prefix.contains(0)
    }

    /// `data` as UTF-8 without a byte order mark: decoded in its encoding (`detect`) and encoded again. For a prefix, a
    /// character cut at the end is left out. What FFmpeg's subtitle demuxers read: most of them look for ASCII in the
    /// bytes, so UTF-16 is lost on them, and its decoders drop lines that aren't UTF-8.
    static func utf8(_ data: Data, isPrefix: Bool = false) -> Data? {
        guard let encoding = detect(data, isPrefix: isPrefix) else { return nil }
        for cut in 0...(isPrefix ? min(3, data.count) : 0) {
            guard var text = String(data: data.dropLast(cut), encoding: encoding) else { continue }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return Data(text.utf8)
        }
        return nil
    }
}
