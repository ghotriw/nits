import CFFmpeg
import Foundation

/// What the client needs of a media address, and the options of its HTTP requests. NitsCore's `MediaURL` classifies
/// locations for hosts and calls this for the parts the client shares.
package enum StreamingURL {
    package static func isNetworkURL(_ path: String) -> Bool {
        guard let url = URL(string: path), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The location of a DASH manifest given inline, as a `data:` URL (`inlineDASHManifest(_:)`): the DASH client
    /// reads the manifest from it, and the media segments it lists from the network.
    package static func isInlineDASHManifest(_ path: String) -> Bool {
        guard path.range(of: inlineDASHPrefix, options: [.anchored, .caseInsensitive]) != nil,
            let comma = path.firstIndex(of: ",")
        else { return false }
        return path[..<comma].lowercased().hasSuffix(";base64")
    }

    private static let inlineDASHPrefix = "data:application/dash+xml;"

    /// `manifest` (the text of an MPD) as a location the demuxer opens. For a manifest built here, e.g. from the
    /// segments a site's extractor lists, whose own file would have to be kept somewhere and cleaned up. Its addresses
    /// are absolute: it tells no address it came from.
    package static func inlineDASHManifest(_ manifest: String) -> String {
        inlineDASHPrefix + "base64," + Data(manifest.utf8).base64EncodedString()
    }

    /// The manifest an inline one holds (`inlineDASHManifest(_:)`). Nil for any other location, or one whose text can't
    /// be decoded.
    package static func inlineDASHManifestContents(_ path: String) -> Data? {
        guard isInlineDASHManifest(path), let comma = path.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(path[path.index(after: comma)...]))
    }

    /// `path` as written to the log: an inline manifest holds the streams' signed URLs, kilobytes of them.
    package static func loggable(_ path: String) -> String {
        // Nor the address it came from: a site's may be signed too.
        isInlineDASHManifest(path) ? "inline DASH manifest (\(path.utf8.count) bytes)" : path
    }

    /// Where `url` is read from, as told to the user: its host, or for an inline DASH manifest, which has none, that it is one.
    package static func displayHost(of url: URL) -> String {
        let text = url.absoluteString
        return isInlineDASHManifest(text) ? "an inline DASH manifest" : (url.host ?? text)
    }

    /// `headers` without CR and LF (against header injection), and without the ones whose name is left empty.
    package static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        let clean = { (text: String) in
            text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }
        var sanitized: [String: String] = [:]
        for (key, value) in headers where !clean(key).isEmpty {
            sanitized[clean(key)] = clean(value)
        }
        return sanitized
    }

    /// The options of an HTTP request: the custom headers (CRLF-sanitized; `User-Agent` as FFmpeg's own option), plus
    /// reconnect and 10 s I/O timeout settings. Given to the input FFmpeg opens.
    package static func requestOptions(headers: [String: String]) -> [(name: String, value: String)] {
        var options: [(name: String, value: String)] = []
        var headerString = ""
        for (key, value) in sanitizedHeaders(headers).sorted(by: { $0.key < $1.key }) {
            if key.lowercased() == "user-agent" {
                options.append(("user_agent", value))
            } else {
                headerString += "\(key): \(value)\r\n"
            }
        }
        if !headerString.isEmpty { options.append(("headers", headerString)) }
        options += [
            ("reconnect", "1"), ("reconnect_streamed", "1"), ("reconnect_delay_max", "5"),
            // 10-second timeout in microseconds for network I/O
            ("rw_timeout", "10000000"), ("timeout", "10000000"),
        ]
        return options
    }

    /// Adds custom HTTP headers (CRLF-sanitized) plus reconnect and 10 s I/O timeout settings to
    /// `avformat_open_input` options for a network URL, and the size of its HTTP requests
    /// (`MediaLoadRequest.httpRequestSize`).
    package static func applyNetworkOptions(
        _ options: inout OpaquePointer?, headers: [String: String], httpRequestSize: Int? = nil
    ) {
        // FFmpeg asks for `Range: bytes=off-(off+size-1)` and the next range once one ends, over a kept-alive
        // connection; a server that answers no range (200) streams on as without it.
        if let httpRequestSize, httpRequestSize > 0 {
            _ = av_dict_set_int(&options, "request_size", Int64(httpRequestSize), 0)
        }
        for (name, value) in requestOptions(headers: headers) {
            _ = av_dict_set(&options, name, value, 0)
        }
    }
}
