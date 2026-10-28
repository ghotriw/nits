import Foundation

/// An excluded folder rule tracking both the lexical path and its canonical resolved target if symlinked.
public struct ExcludedFolder: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// The user-visible path as selected or entered (e.g. "~/Movies" or "/Users/me/Movies").
    public let path: String
    /// The resolved symlink path at addition time, if different from `path`.
    public let resolvedPath: String?

    public var id: String { path }

    public init(path: String, resolvedPath: String? = nil) {
        self.path = HistoryExclusionPolicy.lexicalStandardizePath(path)
        let resolved = resolvedPath.map(HistoryExclusionPolicy.lexicalStandardizePath)
        if let resolved, resolved.caseInsensitiveCompare(self.path) != .orderedSame {
            self.resolvedPath = resolved
        } else {
            self.resolvedPath = nil
        }
    }

    /// Resolves symlinks once using the filesystem (at addition time).
    public static func resolve(from rawPath: String) -> ExcludedFolder {
        let lexical = HistoryExclusionPolicy.lexicalStandardizePath(rawPath)
        let resolved = HistoryExclusionPolicy.standardizePath(rawPath)
        return ExcludedFolder(path: lexical, resolvedPath: resolved)
    }

    /// All standardized paths this folder matches against (both `path` and `resolvedPath`).
    public var matchingPaths: [String] {
        if let resolvedPath {
            return [path, resolvedPath]
        }
        return [path]
    }

    /// Checks whether this folder rule matches any of the same normalized paths as another folder rule.
    public func overlaps(_ other: ExcludedFolder) -> Bool {
        let otherPaths = Set(other.matchingPaths.map { $0.lowercased() })
        return matchingPaths.contains { otherPaths.contains($0.lowercased()) }
    }
}

/// Defines rules for paths and domains that must not be tracked in playback history or recent media.
public struct HistoryExclusionPolicy: Sendable, Equatable {
    /// List of excluded folder rules.
    public let excludedFolders: [ExcludedFolder]

    /// Flattened list of standardized directory paths (both lexical and resolved) checked for exclusions.
    public let excludedPaths: [String]

    /// List of normalized domain names (e.g. "youtube.com", "vimeo.com") whose streams are excluded.
    public let excludedDomains: [String]

    public init(excludedFolders: [ExcludedFolder] = [], excludedDomains: [String] = []) {
        self.excludedFolders = excludedFolders
        self.excludedPaths = excludedFolders.flatMap(\.matchingPaths)
        self.excludedDomains = excludedDomains.compactMap(Self.normalizeDomain)
    }

    public init(excludedPaths: [String], excludedDomains: [String] = []) {
        let folders = excludedPaths.map { ExcludedFolder(path: $0) }
        self.init(excludedFolders: folders, excludedDomains: excludedDomains)
    }

    /// Checks if a given media resource string (POSIX path, `file://` URL, or network stream URL) is excluded.
    public func isExcluded(pathOrURL: String) -> Bool {
        if Self.hasNonFileScheme(pathOrURL) {
            if let url = URL(string: pathOrURL) {
                return isExcluded(networkURL: url)
            }
            // Fallback for unescaped characters / spaces in network URLs (fail-safe for privacy)
            if let encoded = pathOrURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                let url = URL(string: encoded)
            {
                return isExcluded(networkURL: url)
            }
            if let host = Self.extractHost(from: pathOrURL) {
                return matchesDomain(host)
            }
            return false
        }

        // Resolver key (e.g. "youtube:dQw4w9WgXcQ") is not a local filesystem path
        if !pathOrURL.contains("/") && pathOrURL.contains(":") {
            return false
        }

        let normalized = MediaURL.normalizeMediaPath(pathOrURL)
        return isExcluded(localPath: normalized)
    }

    /// Checks if a media item identity (history key, request path, or demuxer stream source URL) is excluded.
    public func isExcluded(media: MediaHistoryIdentity) -> Bool {
        if isExcluded(pathOrURL: media.historyKey) { return true }
        if let path = media.path, isExcluded(pathOrURL: path) { return true }
        if let sourcePath = media.sourcePath, isExcluded(pathOrURL: sourcePath) { return true }
        return false
    }

    /// Whether `pathOrURL` begins with a URI scheme (`scheme://`) other than `file://`.
    private static func hasNonFileScheme(_ pathOrURL: String) -> Bool {
        guard !pathOrURL.hasPrefix("/"), let schemeRange = pathOrURL.range(of: "://") else { return false }
        let scheme = pathOrURL[..<schemeRange.lowerBound]
        return !scheme.isEmpty && !scheme.contains("/") && scheme.lowercased() != "file"
    }

    /// Checks if a URL represents an excluded local file path or network domain.
    public func isExcluded(url: URL) -> Bool {
        if url.isFileURL {
            return isExcluded(localPath: url.path(percentEncoded: false))
        }
        return isExcluded(networkURL: url)
    }

    /// Checks if a local file path is inside any of the excluded directories.
    /// Uses purely lexical path normalization to ensure zero disk/network I/O (safe for SMB/network mounts).
    public func isExcluded(localPath: String) -> Bool {
        guard !excludedPaths.isEmpty else { return false }
        let target = Self.lexicalStandardizePath(localPath)
        for folder in excludedPaths {
            if matchesPath(target: target, folder: folder) {
                return true
            }
        }
        return false
    }

    /// Known macOS root directories located under /private
    private static let knownPrivateRoots = ["tmp", "var", "etc"]

    private static func isKnownPrivateRoot(_ pathWithoutPrivate: String) -> Bool {
        for root in knownPrivateRoots {
            if pathWithoutPrivate == root || pathWithoutPrivate.hasPrefix(root + "/") {
                return true
            }
        }
        return false
    }

    private func matchesPath(target: String, folder: String) -> Bool {
        if checkPathMatch(target: target, folder: folder) {
            return true
        }
        // Handle known macOS system /private prefix mismatches (specifically /private/tmp, /private/var, /private/etc)
        if target.hasPrefix("/private/") {
            let strippedTarget = String(target.dropFirst("/private/".count))
            if Self.isKnownPrivateRoot(strippedTarget) && checkPathMatch(target: "/" + strippedTarget, folder: folder) {
                return true
            }
        } else if folder.hasPrefix("/private/") {
            let strippedFolder = String(folder.dropFirst("/private/".count))
            if Self.isKnownPrivateRoot(strippedFolder) && checkPathMatch(target: target, folder: "/" + strippedFolder) {
                return true
            }
        }
        return false
    }

    private func checkPathMatch(target: String, folder: String) -> Bool {
        // Note: Case-insensitive comparison is intentional to prioritize privacy on macOS, even on case-sensitive APFS volumes.
        if target.caseInsensitiveCompare(folder) == .orderedSame {
            return true
        }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return target.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    /// Checks if a network URL matches any of the excluded domains.
    public func isExcluded(networkURL: URL) -> Bool {
        guard !excludedDomains.isEmpty, let host = networkURL.host?.lowercased() else { return false }
        return matchesDomain(host)
    }

    /// Checks if a normalized host matches any of the excluded domain patterns.
    public func matchesDomain(_ host: String) -> Bool {
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        for domain in excludedDomains {
            let cleanDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            if cleanHost == cleanDomain || cleanHost.hasSuffix("." + cleanDomain) {
                return true
            }
        }
        return false
    }

    /// Extracts the host portion of a network URL string even if invalid or unescaped.
    public static func extractHost(from urlString: String) -> String? {
        guard let schemeRange = urlString.range(of: "://") else { return nil }
        var remainder = String(urlString[schemeRange.upperBound...])
        if let slashIndex = remainder.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            remainder = String(remainder[..<slashIndex])
        }
        if let atIndex = remainder.lastIndex(of: "@") {
            remainder = String(remainder[remainder.index(after: atIndex)...])
        }
        if remainder.hasPrefix("["), let bracketEnd = remainder.firstIndex(of: "]") {
            let inside = String(remainder[remainder.index(after: remainder.startIndex)..<bracketEnd])
            return inside.isEmpty ? nil : inside
        }
        if let colonIndex = remainder.firstIndex(of: ":") {
            remainder = String(remainder[..<colonIndex])
        }
        return remainder.isEmpty ? nil : remainder
    }

    /// Standardizes a directory path when configuring exclusions (expands tilde, resolves symlinks).
    public static func standardizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        return url.standardized.path
    }

    /// Lexically standardizes a path without accessing the filesystem or resolving symlinks.
    public static func lexicalStandardizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardized.path
    }

    /// Normalizes user input for domain exclusion: strips schemes, credentials, ports, wildcards, leading/trailing dots.
    public static func normalizeDomain(_ raw: String) -> String? {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !str.isEmpty else { return nil }

        // Strip leading wildcards (*. or .)
        while str.hasPrefix("*.") {
            str.removeFirst(2)
        }
        while str.hasPrefix(".") {
            str.removeFirst(1)
        }

        // Strip scheme if present
        if let schemeEnd = str.range(of: "://") {
            str = String(str[schemeEnd.upperBound...])
        }

        // If it's an unbracketed IPv6 literal (e.g. "::1" or "2001:db8::1"), return it directly
        if !str.contains("/") && !str.contains("@") && !str.hasPrefix("[")
            && (str.contains("::") || str.split(separator: ":").count >= 3)
        {
            return str
        }

        // Try parsing with URLComponents with a dummy scheme
        let parseable = "http://" + str
        if let components = URLComponents(string: parseable), let host = components.host, !host.isEmpty {
            var clean = host.lowercased()
            if clean.hasPrefix("[") && clean.hasSuffix("]") {
                clean.removeFirst()
                clean.removeLast()
            }
            while clean.hasPrefix("*.") { clean.removeFirst(2) }
            while clean.hasPrefix(".") { clean.removeFirst(1) }
            while clean.hasSuffix(".") { clean.removeLast(1) }
            return clean.isEmpty ? nil : clean
        }

        // Fallback robust manual parsing
        if let atIndex = str.lastIndex(of: "@") {
            str = String(str[str.index(after: atIndex)...])
        }
        if let pathOrQuery = str.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            str = String(str[..<pathOrQuery])
        }
        if str.hasPrefix("["), let bracketEnd = str.firstIndex(of: "]") {
            str = String(str[str.index(after: str.startIndex)..<bracketEnd])
        } else if let colonIndex = str.firstIndex(of: ":") {
            str = String(str[..<colonIndex])
        }

        if str.hasPrefix("[") && str.hasSuffix("]") {
            str.removeFirst()
            str.removeLast()
        }

        while str.hasPrefix("*.") { str.removeFirst(2) }
        while str.hasPrefix(".") { str.removeFirst(1) }
        while str.hasSuffix(".") { str.removeLast(1) }

        return str.isEmpty ? nil : str
    }

    /// Decodes a JSON-encoded array of ExcludedFolder, falling back to empty on failure.
    public static func decodeFolders(from string: String) -> [ExcludedFolder] {
        guard let data = string.data(using: .utf8),
            let folders = try? JSONDecoder().decode([ExcludedFolder].self, from: data)
        else {
            return []
        }
        return folders
    }

    /// Encodes an array of ExcludedFolder into a JSON string.
    public static func encodeFolders(_ folders: [ExcludedFolder]) -> String {
        guard let data = try? JSONEncoder().encode(folders),
            let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    /// Decodes a JSON-encoded array of strings, falling back to empty array on failure.
    public static func decodeList(from string: String) -> [String] {
        guard let data = string.data(using: .utf8),
            let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return array
    }

    /// Encodes an array of strings into a JSON string.
    public static func encodeList(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list),
            let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }
}
