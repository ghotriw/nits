import Foundation
import Testing

@testable import NitsCore

@Suite("Sidecar audio files")
struct SidecarAudioTests {
    @Test("Audio files named as the media are picked up, the media's own name and other names and kinds aren't")
    func findsFilesNamedAsMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in [
            "Movie.mkv", "Movie.mka", "Movie.uk.ac3", "Movie.Commentary.flac", "movie.EN.m4a", "Movie.mp4",
            "Movie.srt", "Movie 2.mka", "Other.mka",
        ] {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let found = SidecarAudio.urls(for: directory.appendingPathComponent("Movie.mkv")).map(\.lastPathComponent)
        #expect(found == ["Movie.Commentary.flac", "movie.EN.m4a", "Movie.mka", "Movie.uk.ac3"])
        // An audio file playing as the media isn't its own track.
        let forAudio = SidecarAudio.urls(for: directory.appendingPathComponent("Movie.mka")).map(\.lastPathComponent)
        #expect(!forAudio.contains("Movie.mka"))
        #expect(SidecarFiles.tags(of: directory.appendingPathComponent("Movie.uk.ac3")).language == "uk")
    }

    @Test("A file's tracks are named by their title or the file, numbered only where the list would show them alike")
    @MainActor
    func namesFileTracks() {
        func track(_ id: Int, title: String = "", language: String = "") -> MediaDemuxer.AudioTrack {
            MediaDemuxer.AudioTrack(
                id: id, streamIndex: id, title: title, language: language, codecName: "aac", channels: 2,
                sampleRate: 48_000, isDefault: true)
        }
        let url = URL(fileURLWithPath: "/dubs/Movie.uk.mka")
        let listed = PlaybackInputs.listedTracks(
            of: [track(0), track(1), track(2, language: "en"), track(3, title: "Director's Commentary")], from: url,
            firstId: 2000)
        #expect(
            listed.map(\.title) == [
                "Movie.uk #1 (External)", "Movie.uk #2 (External)", "Movie.uk (External)",
                "Director's Commentary (External)",
            ])
        // Untagged streams take the language the name tags.
        #expect(listed.map(\.language) == ["uk", "uk", "en", "uk"])
        #expect(listed.map(\.id) == [2000, 2001, 2002, 2003])
        #expect(listed.allSatisfy { !$0.isDefault && $0.externalURL == url })
    }
}
