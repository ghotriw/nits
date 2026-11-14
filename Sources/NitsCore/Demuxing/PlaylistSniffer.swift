import Foundation

/// What the first bytes of an address say it is, whatever its name: an HLS playlist or a DASH manifest.
enum SniffedPlaylist: Equatable {
    case hls
    case dash

    /// How many bytes tell it: an HLS playlist starts with `#EXTM3U`; a manifest's root `<MPD` comes after an optional
    /// `<?xml …?>`, comments (a packager's licence, a banner) and a doctype, which a few KB hold. Still one request.
    static let headLength = 4096

    /// The kind of the text that starts with `head` (a byte-order mark is skipped); nil for any other. An HLS playlist
    /// must start with its tag on the first line, as the parser reads it (`HLSPlaylistParser`): spaces and tabs before it
    /// are trimmed, a blank line is not. A manifest's XML may have any white space before the prolog.
    static func classify(_ head: some Collection<UInt8>) -> SniffedPlaylist? {
        var bytes = Array(head)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        // Spaces and tabs before the tag: the parser trims its first line, but a blank line before it is not trimmed.
        let tag = bytes.drop { $0 == 0x20 || $0 == 0x09 }
        if tag.starts(with: Array("#EXTM3U".utf8)) { return .hls }
        // UTF-16 manifests are not told apart: the client reads UTF-8 only.
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            bytes = bytes.dropFirst()
        }
        guard bytes.first == UInt8(ascii: "<") else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        var rest = Substring(text)
        // The prolog: `<?xml …?>`, `<!-- … -->`, `<!DOCTYPE …>`, each skipped to its end. A doctype with an internal
        // subset (`[ <!ENTITY …> ]`) ends at its first `>` and is not told: an MPD has none.
        while rest.hasPrefix("<?") || rest.hasPrefix("<!") {
            let end = rest.hasPrefix("<!--") ? "-->" : (rest.hasPrefix("<?") ? "?>" : ">")
            guard let range = rest.range(of: end) else { return nil }
            rest = rest[range.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        }
        guard rest.hasPrefix("<") else { return nil }
        // The root's name, with a namespace prefix or without (`<MPD`, `<mpd:MPD`).
        let name = rest.dropFirst().prefix { !" \t\n\r>/".contains($0) }
        return name.split(separator: ":").last == "MPD" ? .dash : nil
    }

    /// The kind of what `url` serves, read from its first bytes: one request for a range of `headLength`, answered and
    /// dropped. Nil for a stream that is neither, one that is not served over HTTP(S), or a failed request. Asked only
    /// after FFmpeg failed to open the address, so a file never pays for it.
    static func sniff(_ url: String, headers: [String: String], interrupt: FFmpegInterrupt) -> SniffedPlaylist? {
        guard HTTPSessionTransport.serves(url) else { return nil }
        let transport = HTTPSessionTransport(source: url, headers: headers) { interrupt.shouldInterruptFFmpeg }
        guard
            case .input(let input) = transport.open(
                url, offset: 0, end: Int64(headLength), followsRedirects: true)
        else { return nil }
        defer { input.close() }
        var head = [UInt8](repeating: 0, count: headLength)
        var count = 0
        while count < headLength {
            let offset = count
            let read = head.withUnsafeMutableBufferPointer {
                input.read($0.baseAddress! + offset, Int32(headLength - offset))
            }
            if read <= 0 { break }
            count += Int(read)
        }
        return classify(head.prefix(count))
    }
}
