import Foundation

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

    /// `AVERROR(ENETDOWN)`: the request found no way to the server (no connection, no route, its name not resolved), so
    /// no answer came. Told apart from `-EIO` (a body cut short, an error of the segment's own) by the transport.
    package static let networkDown: Int32 = -ENETDOWN

    /// A request that failed for the network, not for what it asked: no answer within the timeout (`-ETIMEDOUT`) or no
    /// way to the server (`networkDown`). Asking the same again later can succeed, which a 404 or a broken segment cannot.
    package static func isNetworkFailure(_ code: Int32) -> Bool {
        code == -ETIMEDOUT || code == networkDown
    }

    /// `FFERRTAG(a, b, c, d)`: FFmpeg's `AVERROR_HTTP_*` and the like.
    package static func tag(_ a: UInt8, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
        let tag =
            UInt32(a) | UInt32(b.asciiValue ?? 0) << 8 | UInt32(c.asciiValue ?? 0) << 16
            | UInt32(d.asciiValue ?? 0) << 24
        return -Int32(bitPattern: tag)
    }
}
