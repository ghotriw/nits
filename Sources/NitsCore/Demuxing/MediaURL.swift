import CFFmpeg
import Foundation

/// Classifies media locations (HTTP, LAN, mounted remote volumes) and prepares FFmpeg options for network
/// input.
public enum MediaURL {
    public static func isNetworkURL(_ path: String) -> Bool {
        guard let url = URL(string: path), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// A saved HLS manifest whose media is on the network (`path` a file path, as `PlayerEngine.normalizeMediaPath`
    /// leaves it). FFmpeg opens its segments with the I/O options of the manifest's own input, so it is opened with the
    /// network options too, and read ahead as a network source. Only the file's own text is looked at: a master
    /// playlist of saved media playlists, whose segments are on the network, isn't recognised.
    public static func isHLSManifestWithRemoteMedia(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard !isNetworkURL(path), ["m3u8", "m3u"].contains(url.pathExtension.lowercased()),
            let data = try? Data(contentsOf: url), let text = TextFileEncoding.decode(data)?.text
        else { return false }
        return PlaylistParser.isHLSManifest(content: text) && (text.contains("http://") || text.contains("https://"))
    }

    /// Whether `path` is read over the network: a URL, or a saved HLS manifest of network media.
    public static func isNetworkSource(_ path: String) -> Bool {
        isNetworkURL(path) || isHLSManifestWithRemoteMedia(atPath: path)
    }

    /// Adds the options `path` is opened with when it is a network source (`isNetworkSource`), and tells whether it
    /// is: the network options, and for a saved manifest the HTTP protocols too. A file is allowed the file
    /// protocol's whitelist (file, crypto, data), so its segments on the network would be refused; the HLS demuxer
    /// still opens nothing but files and HTTP(S) from it.
    static func applySourceOptions(_ options: inout OpaquePointer?, path: String, headers: [String: String]) -> Bool {
        guard isNetworkSource(path) else { return false }
        applyNetworkOptions(&options, headers: headers)
        if !isNetworkURL(path) {
            _ = av_dict_set(&options, "protocol_whitelist", "file,crypto,data,http,https,tcp,tls", 0)
        }
        return true
    }

    /// Adds custom HTTP headers (CRLF-sanitized) plus reconnect and 10 s I/O timeout settings to
    /// `avformat_open_input` options for a network URL.
    static func applyNetworkOptions(_ options: inout OpaquePointer?, headers: [String: String]) {
        if !headers.isEmpty {
            var headerString = ""
            for (key, value) in headers {
                // Sanitize against CRLF injection
                let cleanKey = key.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                let cleanVal = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                guard !cleanKey.isEmpty else { continue }

                if cleanKey.lowercased() == "user-agent" {
                    _ = av_dict_set(&options, "user_agent", cleanVal, 0)
                } else {
                    headerString += "\(cleanKey): \(cleanVal)\r\n"
                }
            }
            if !headerString.isEmpty {
                _ = av_dict_set(&options, "headers", headerString, 0)
            }
        }

        _ = av_dict_set(&options, "reconnect", "1", 0)
        _ = av_dict_set(&options, "reconnect_streamed", "1", 0)
        _ = av_dict_set(&options, "reconnect_delay_max", "5", 0)
        // 10-second timeout in microseconds for network I/O
        _ = av_dict_set(&options, "rw_timeout", "10000000", 0)
        _ = av_dict_set(&options, "timeout", "10000000", 0)
        // HLS: one segment download at a time. By default FFmpeg opens the next segment while it reads one, to hide
        // the request's latency, which the read-ahead hides anyway; two downloads share the link, so the read-ahead
        // thread would measure half of it, and after a variant switch the prefetched segment is downloaded for
        // nothing. Other formats leave the option unused.
        _ = av_dict_set(&options, "http_multiple", "0", 0)
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
