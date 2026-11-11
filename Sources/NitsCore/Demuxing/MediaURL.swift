import CFFmpeg
import Foundation

/// Classifies media locations (HTTP, LAN, mounted remote volumes) and prepares FFmpeg options for network
/// input.
public enum MediaURL {
    public static func isNetworkURL(_ path: String) -> Bool {
        guard let url = URL(string: path), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Normalizes an input path: a `file://` URL becomes its decoded path; a plain path is already one and stays as is
    /// (a file may be named `a%41.mkv`).
    public static func normalizeMediaPath(_ path: String) -> String {
        if isNetworkURL(path) {
            return path
        }
        if path.lowercased().hasPrefix("file://") {
            return URL(string: path)?.path(percentEncoded: false) ?? String(path.dropFirst("file://".count))
        }
        return path
    }

    /// A saved HLS manifest whose media is on the network (`path` a file path, as `normalizeMediaPath`
    /// leaves it). It is read ahead as a network source. Only the file's own text is looked at: a master
    /// playlist of saved media playlists, whose segments are on the network, isn't recognised.
    public static func isHLSManifestWithRemoteMedia(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard !isNetworkURL(path), ["m3u8", "m3u"].contains(url.pathExtension.lowercased()),
            let data = try? Data(contentsOf: url), let text = TextFileEncoding.decode(data)?.text
        else { return false }
        return PlaylistParser.isHLSManifest(content: text) && (text.contains("http://") || text.contains("https://"))
    }

    /// The location of a DASH manifest given inline, as a `data:` URL (`inlineDASHManifest(_:)`): FFmpeg's DASH demuxer
    /// reads the manifest from it, and the media segments it lists from the network.
    public static func isInlineDASHManifest(_ path: String) -> Bool {
        path.range(of: inlineDASHPrefix, options: [.anchored, .caseInsensitive]) != nil
    }

    private static let inlineDASHPrefix = "data:application/dash+xml;base64,"

    /// `manifest` (the text of an MPD) as a location the demuxer opens. For a manifest built here, e.g. from the
    /// segments a site's extractor lists, whose own file would have to be kept somewhere and cleaned up.
    package static func inlineDASHManifest(_ manifest: String) -> String {
        inlineDASHPrefix + Data(manifest.utf8).base64EncodedString()
    }

    /// `path` as written to the log: an inline manifest holds the streams' signed URLs, kilobytes of them.
    public static func loggable(_ path: String) -> String {
        isInlineDASHManifest(path) ? "inline DASH manifest (\(path.utf8.count) bytes)" : path
    }

    /// Whether `path` is read over the network: a URL, an inline DASH manifest, or a saved HLS manifest of network
    /// media.
    public static func isNetworkSource(_ path: String) -> Bool {
        isNetworkURL(path) || isInlineDASHManifest(path) || isHLSManifestWithRemoteMedia(atPath: path)
    }

    /// Adds the options `path` is opened with when it is a network source (`isNetworkSource`), and tells whether it
    /// is: the network options, and for a saved manifest the HTTP protocols too. A file is allowed the file
    /// protocol's whitelist (file, crypto, data), so its segments on the network would be refused.
    static func applySourceOptions(
        _ options: inout OpaquePointer?, path: String, headers: [String: String], httpRequestSize: Int? = nil
    ) -> Bool {
        guard isNetworkSource(path) else { return false }
        applyNetworkOptions(&options, headers: headers, httpRequestSize: httpRequestSize)
        if isInlineDASHManifest(path) {
            // The DASH demuxer opens what the manifest lists: the whitelist keeps it to HTTP(S), no files.
            _ = av_dict_set(&options, "protocol_whitelist", "crypto,data,http,https,tcp,tls", 0)
        } else if !isNetworkURL(path) {
            _ = av_dict_set(&options, "protocol_whitelist", "file,crypto,data,http,https,tcp,tls", 0)
        }
        return true
    }

    /// `headers` without CR and LF (against header injection), and without the ones whose name is left empty.
    static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
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
    /// reconnect and 10 s I/O timeout settings. Given to the input, and to the requests of a demuxer that opens its own
    /// (DASH's segments, when its manifest is not an HTTP input they could be copied from).
    static func requestOptions(headers: [String: String]) -> [(name: String, value: String)] {
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
    static func applyNetworkOptions(
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

    /// Checks if a network URL points to a local area network (LAN) / private network address
    /// (e.g. 192.168.x.x, 10.x.x.x, 172.16-31.x.x, 127.0.0.1, localhost, .local, etc.)
    public static func isLocalNetworkURL(_ path: String) -> Bool {
        guard let url = URL(string: path), let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // Loopback and local domain suffixes
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") || host.hasSuffix(".localdomain")
        {
            return true
        }

        // IPv4 parsing (e.g. 192.168.1.83)
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 && parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) {
            let p0 = parts[0]
            let p1 = parts[1]
            // 10.0.0.0/8 (10.x.x.x)
            if p0 == 10 { return true }
            // 172.16.0.0/12 (172.16.x.x - 172.31.x.x)
            if p0 == 172 && (16...31).contains(p1) { return true }
            // 192.168.0.0/16 (192.168.x.x)
            if p0 == 192 && p1 == 168 { return true }
            // 169.254.0.0/16 (link-local)
            if p0 == 169 && p1 == 254 { return true }
            // 127.0.0.0/8 (loopback)
            if p0 == 127 { return true }
        }

        // IPv6 Link-Local (fe80::/10) or Unique Local (fc00::/7 - fc.. or fd..)
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }

        return false
    }

    /// Checks if a path points to a remote streaming resource or a mounted remote volume (e.g. NFS, SMB, AFP under /Volumes/).
    /// Opening such resources can incur network latency and must be performed asynchronously.
    public static func isRemoteOrMountedVolume(_ path: String) -> Bool {
        if isNetworkURL(path) {
            return true
        }
        // Network schemes
        if path.hasPrefix("nfs://") || path.hasPrefix("smb://") || path.hasPrefix("afp://") || path.hasPrefix("rtsp://")
        {
            return true
        }
        // Mounted volumes outside boot drive (e.g. /Volumes/Drive/...)
        if path.hasPrefix("/Volumes/") {
            let url = URL(fileURLWithPath: path)
            if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]), let isLocal = values.volumeIsLocal {
                return !isLocal
            }
            // If resourceValues cannot determine or path is under /Volumes/, treat as potentially remote
            return true
        }
        return false
    }
}
