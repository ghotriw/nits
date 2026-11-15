/// FFmpeg's error codes whose macros do not import into Swift.
package enum FFmpegErrorCode {
    /// `AVERROR_EOF` (`-MKTAG('E', 'O', 'F', ' ')`).
    package static let eof: Int32 = -0x2046_4F45
    /// `AVERROR_INVALIDDATA` (`-MKTAG('I', 'N', 'D', 'A')`): the input is of no format FFmpeg knows.
    package static let invalidData: Int32 = -0x4144_4E49
    /// `AVERROR_EXIT` (`-MKTAG('E', 'X', 'I', 'T')`), FFmpeg's error for an interrupted call.
    package static let exit: Int32 = -0x5449_5845
    /// `AVERROR_HTTP_FORBIDDEN`: the server's 403.
    package static let httpForbidden = tag(0xF8, "4", "0", "3")
    /// `AVERROR_HTTP_NOT_FOUND`: the server's 404.
    package static let httpNotFound = tag(0xF8, "4", "0", "4")

    /// `FFERRTAG(a, b, c, d)`: FFmpeg's `AVERROR_HTTP_*` and the like.
    package static func tag(_ a: UInt8, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
        let tag =
            UInt32(a) | UInt32(b.asciiValue ?? 0) << 8 | UInt32(c.asciiValue ?? 0) << 16
            | UInt32(d.asciiValue ?? 0) << 24
        return -Int32(bitPattern: tag)
    }
}
