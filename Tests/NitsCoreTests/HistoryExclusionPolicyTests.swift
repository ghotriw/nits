import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("HistoryExclusionPolicy Tests")
struct HistoryExclusionPolicyTests {

    @Test("Matches local folder and its descendants with proper boundary")
    func testLocalFolderMatching() {
        let folder = "/Users/test/Movies"
        let policy = HistoryExclusionPolicy(excludedPaths: [folder], excludedDomains: [])

        // Exact folder match
        #expect(policy.isExcluded(localPath: "/Users/test/Movies"))
        // Subdirectory file match
        #expect(policy.isExcluded(localPath: "/Users/test/Movies/film.mkv"))
        #expect(policy.isExcluded(localPath: "/Users/test/Movies/action/2024/film.mp4"))
        // Trailing slash in query
        #expect(policy.isExcluded(localPath: "/Users/test/Movies/"))

        // Sibling path with same prefix must NOT match
        #expect(!policy.isExcluded(localPath: "/Users/test/Movies_backup/film.mkv"))
        #expect(!policy.isExcluded(localPath: "/Users/test/MoviesArchive/film.mkv"))
        #expect(!policy.isExcluded(localPath: "/Users/test/Downloads/film.mkv"))
    }

    @Test("Matches local paths case-insensitively")
    func testCaseInsensitivePathMatching() {
        let folder = "/Users/test/PrivateMedia"
        let policy = HistoryExclusionPolicy(excludedPaths: [folder], excludedDomains: [])

        #expect(policy.isExcluded(localPath: "/users/test/privatemedia/clip.mov"))
        #expect(policy.isExcluded(localPath: "/USERS/TEST/PRIVATEMEDIA/SUB/CLIP.MOV"))
    }

    @Test("Matches network domains and subdomains")
    func testNetworkDomainMatching() {
        let policy = HistoryExclusionPolicy(excludedPaths: [], excludedDomains: ["example.com", "vimeo.com"])

        // Exact domain
        #expect(policy.isExcluded(networkURL: URL(string: "https://example.com/video.mp4")!))
        #expect(policy.isExcluded(networkURL: URL(string: "http://vimeo.com/12345")!))

        // Subdomain
        #expect(policy.isExcluded(networkURL: URL(string: "https://cdn.example.com/stream.m3u8")!))
        #expect(policy.isExcluded(networkURL: URL(string: "https://player.sub.vimeo.com/hls")!))

        // Different domain ending with same name must NOT match
        #expect(!policy.isExcluded(networkURL: URL(string: "https://fakeexample.com/video.mp4")!))
        #expect(!policy.isExcluded(networkURL: URL(string: "https://notvimeo.com/video.mp4")!))
        #expect(!policy.isExcluded(networkURL: URL(string: "https://youtube.com/watch?v=123")!))
    }

    @Test("Normalizes domain user input correctly")
    func testNormalizeDomain() {
        #expect(HistoryExclusionPolicy.normalizeDomain("example.com") == "example.com")
        #expect(HistoryExclusionPolicy.normalizeDomain("  EXAMPLE.COM  ") == "example.com")
        #expect(HistoryExclusionPolicy.normalizeDomain("https://youtube.com/watch?v=123") == "youtube.com")
        #expect(HistoryExclusionPolicy.normalizeDomain("http://vimeo.com:8080/path") == "vimeo.com")
        #expect(HistoryExclusionPolicy.normalizeDomain("*.twitch.tv") == "twitch.tv")
        #expect(HistoryExclusionPolicy.normalizeDomain(".sub.domain.org.") == "sub.domain.org")

        // Credentials and IPv6 normalization
        #expect(HistoryExclusionPolicy.normalizeDomain("https://user:pass@example.com:443/video") == "example.com")
        #expect(HistoryExclusionPolicy.normalizeDomain("[::1]:8080") == "::1")
        #expect(HistoryExclusionPolicy.normalizeDomain("http://[2001:db8::1]:80/path") == "2001:db8::1")

        // Invalid inputs
        #expect(HistoryExclusionPolicy.normalizeDomain("") == nil)
        #expect(HistoryExclusionPolicy.normalizeDomain("   ") == nil)
        #expect(HistoryExclusionPolicy.normalizeDomain("://") == nil)
        #expect(HistoryExclusionPolicy.normalizeDomain("*.") == nil)
    }

    @Test("Matches unescaped network URLs fail-safely")
    func testUnescapedNetworkURLMatching() {
        let policy = HistoryExclusionPolicy(excludedPaths: [], excludedDomains: ["stream.service.com", "::1"])

        // Unescaped space in path
        #expect(policy.isExcluded(pathOrURL: "https://stream.service.com/live stream with spaces.m3u8"))
        // Credentials in URL
        #expect(policy.isExcluded(pathOrURL: "https://user:secret@stream.service.com:8443/stream.m3u8"))
        // IPv6 URL
        #expect(policy.isExcluded(pathOrURL: "http://[::1]:8080/stream.m3u8"))
        // Non-HTTP network protocols (SMB, RTSP, NFS)
        #expect(policy.isExcluded(pathOrURL: "smb://stream.service.com/share/movie.mkv"))
        #expect(policy.isExcluded(pathOrURL: "rtsp://stream.service.com:554/camera"))
        #expect(policy.isExcluded(pathOrURL: "nfs://[::1]/export/video.mp4"))
    }

    @Test("Encodes and decodes list of strings correctly")
    func testEncodeDecodeList() {
        let original = ["/path/with, commas/folder", "example.com", "space dir"]
        let encoded = HistoryExclusionPolicy.encodeList(original)
        let decoded = HistoryExclusionPolicy.decodeList(from: encoded)
        #expect(decoded == original)

        #expect(HistoryExclusionPolicy.decodeList(from: "invalid json") == [])
    }

    @Test("Matches macOS /private system symlinks symmetrically without disk I/O")
    func testPrivateSystemSymlinks() {
        let policyA = HistoryExclusionPolicy(excludedPaths: ["/tmp/secret"], excludedDomains: [])
        #expect(policyA.isExcluded(localPath: "/tmp/secret/clip.mp4"))
        #expect(policyA.isExcluded(localPath: "/private/tmp/secret/clip.mp4"))

        let policyB = HistoryExclusionPolicy(excludedPaths: ["/private/var/log/media"], excludedDomains: [])
        #expect(policyB.isExcluded(localPath: "/var/log/media/clip.mp4"))
        #expect(policyB.isExcluded(localPath: "/private/var/log/media/clip.mp4"))

        // Non-system /private paths must NOT have /private stripped
        let policyC = HistoryExclusionPolicy(excludedPaths: ["/foo/secret"], excludedDomains: [])
        #expect(!policyC.isExcluded(localPath: "/private/foo/secret/clip.mp4"))
    }

    @Test("ExcludedFolder resolves filesystem symlink and HistoryExclusionPolicy matches both forms")
    func testExcludedFolderSymlinkResolution() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ExcludedFolderTest_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let realDir = tempDir.appendingPathComponent("RealMedia")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)

        let symlinkDir = tempDir.appendingPathComponent("SymlinkMedia")
        try fm.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)

        // Resolve from the symlink path
        let folder = ExcludedFolder.resolve(from: symlinkDir.path)
        #expect(folder.path == HistoryExclusionPolicy.lexicalStandardizePath(symlinkDir.path))
        #expect(folder.resolvedPath != nil)
        #expect(folder.resolvedPath == HistoryExclusionPolicy.standardizePath(symlinkDir.path))

        let policy = HistoryExclusionPolicy(excludedFolders: [folder])

        // Matches file through symlink
        #expect(policy.isExcluded(localPath: "\(symlinkDir.path)/video.mp4"))
        // Matches file through real target
        #expect(policy.isExcluded(localPath: "\(realDir.path)/video.mp4"))
    }

    @Test("ExcludedFolder encoding and decoding roundtrip")
    func testExcludedFolderCodable() throws {
        let folderA = ExcludedFolder(path: "/Users/test/Movies", resolvedPath: "/Volumes/Media/Movies")
        let folderB = ExcludedFolder(path: "/Users/test/Downloads")
        let encoded = HistoryExclusionPolicy.encodeFolders([folderA, folderB])

        let decoded = HistoryExclusionPolicy.decodeFolders(from: encoded)
        #expect(decoded.count == 2)
        #expect(decoded[0].path == "/Users/test/Movies")
        #expect(decoded[0].resolvedPath == "/Volumes/Media/Movies")
        #expect(decoded[1].path == "/Users/test/Downloads")
        #expect(decoded[1].resolvedPath == nil)
    }

    @Test("ExcludedFolder overlaps detects duplicate or cross-resolved entries")
    func testExcludedFolderOverlaps() {
        let folderA = ExcludedFolder(path: "/Users/test/Movies", resolvedPath: "/Volumes/Media/Movies")
        let folderB = ExcludedFolder(path: "/Volumes/Media/Movies")
        let folderC = ExcludedFolder(path: "/users/test/movies")
        let folderD = ExcludedFolder(path: "/Users/test/Downloads")

        #expect(folderA.overlaps(folderB))
        #expect(folderB.overlaps(folderA))
        #expect(folderA.overlaps(folderC))
        #expect(!folderA.overlaps(folderD))
        #expect(!folderB.overlaps(folderD))
    }

    @Test("PlayerConfiguration historyExcludedFolders roundtrip in UserDefaults")
    func testConfigurationRoundtrip() {
        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.historyExcludedFolders = [
            ExcludedFolder(path: "/Users/test/Movies", resolvedPath: "/Volumes/Media/Movies")
        ]
        config.historyExcludedDomains = ["example.com"]
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.historyExcludedFolders.count == 1)
        #expect(loaded.historyExcludedFolders[0].path == "/Users/test/Movies")
        #expect(loaded.historyExcludedFolders[0].resolvedPath == "/Volumes/Media/Movies")
        #expect(loaded.historyExcludedDomains == ["example.com"])

        let policy = PlayerConfiguration.loadHistoryExclusionPolicy(from: defaults)
        #expect(policy.excludedFolders.count == 1)
        #expect(policy.excludedDomains == ["example.com"])
    }
}
