import Foundation
import Testing

@testable import NitsCore

@Suite("MediaURLResolver Tests")
struct MediaURLResolverTests {
    /// A scratch folder with `files` (empty) and `folders`, removed when the test ends.
    private final class Sandbox {
        let root: URL

        init(files: [String], folders: [String] = []) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaURLResolverTests-\(UUID().uuidString)", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for folder in folders {
                try fm.createDirectory(at: url(folder), withIntermediateDirectories: true)
            }
            for file in files {
                #expect(fm.createFile(atPath: url(file).path, contents: Data()))
            }
        }

        func url(_ relativePath: String) -> URL {
            root.appendingPathComponent(relativePath)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("A folder dropped first is replaced by its media, not loaded")
    func folderFirst() throws {
        let box = try Sandbox(
            files: ["Show/ep10.mkv", "Show/ep2.mkv", "Show/notes.txt", "movie.mkv"], folders: ["Show"])
        let result = MediaURLResolver.resolve([box.url("Show"), box.url("movie.mkv")])
        #expect(result.urls.map(\.lastPathComponent) == ["ep2.mkv", "ep10.mkv", "movie.mkv"])
        #expect(result.skippedCount == 0)
    }

    @Test("A folder without media and hidden items are skipped")
    func hiddenAndEmptyFolderFirst() throws {
        let box = try Sandbox(
            files: [".zsh_sessions/a.session", ".hidden.mkv", "movie.mkv"], folders: [".zsh_sessions", "Empty"])
        let result = MediaURLResolver.resolve([
            box.url(".zsh_sessions"), box.url("Empty"), box.url(".hidden.mkv"), box.url("movie.mkv"),
        ])
        #expect(result.urls == [box.url("movie.mkv")])
        #expect(result.skippedCount == 3)
    }

    @Test("Unknown extensions are dropped next to recognised media and playlists")
    func unknownExtensionNextToMedia() throws {
        let box = try Sandbox(files: ["notes.txt", "list.m3u", "song.flac", "missing-is-not-created.mkv"])
        try FileManager.default.removeItem(at: box.url("missing-is-not-created.mkv"))
        let remote = try #require(URL(string: "https://example.com/live.m3u8"))
        let result = MediaURLResolver.resolve([
            box.url("notes.txt"), box.url("missing-is-not-created.mkv"), box.url("list.m3u"), remote,
            box.url("song.flac"),
        ])
        #expect(result.urls == [box.url("list.m3u"), remote, box.url("song.flac")])
        #expect(result.skippedCount == 2)
    }

    @Test("Files with unknown extensions are kept when nothing else is playable")
    func unknownExtensionAlone() throws {
        let box = try Sandbox(files: ["clip.y4m"])
        let result = MediaURLResolver.resolve([box.url("clip.y4m")])
        #expect(result.urls == [box.url("clip.y4m")])
        #expect(result.skippedCount == 0)
    }

    @Test("Nothing playable resolves to an empty list")
    func nothingPlayable() throws {
        let box = try Sandbox(files: [".DS_Store", "Docs/readme.md"], folders: ["Docs"])
        let result = MediaURLResolver.resolve([box.url(".DS_Store"), box.url("Docs")])
        #expect(result.urls.isEmpty)
        #expect(result.skippedCount == 2)
    }
}
