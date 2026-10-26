import Foundation
import Testing

@testable import NitsCore

/// Picking another picture of a resolved page (`ResolvedMedia.selecting`, `ResolvedSource.switching`).
@Suite("Video format switch")
struct VideoFormatSwitchTests {
    static let formats = [
        VideoFormat(
            id: "hd", url: "https://media.example/hd", width: 1920, height: 1080, codec: "AV1",
            httpRequestSize: 10 << 20, headers: ["User-Agent": "hd"]),
        VideoFormat(id: "sd", url: "https://media.example/sd", width: 640, height: 360, codec: "H.264"),
    ]

    static var media: ResolvedMedia {
        ResolvedMedia(
            path: "https://media.example/hd", headers: ["User-Agent": "page"], title: "Page", historyKey: "site:1",
            httpRequestSize: 10 << 20, videoFormats: formats, selectedVideoFormatID: "hd")
    }

    @Test("A picture selected is the media, read with its own headers and request size, the page's otherwise")
    func selectsFormat() throws {
        let sd = try #require(Self.media.selecting(videoFormat: "sd"))
        #expect(sd.path == "https://media.example/sd" && sd.selectedVideoFormatID == "sd")
        #expect(sd.headers == ["User-Agent": "page"], "A format without headers keeps the page's")
        #expect(sd.httpRequestSize == nil)
        #expect(sd.title == "Page" && sd.historyKey == "site:1" && sd.videoFormats == Self.formats)

        let hd = try #require(sd.selecting(videoFormat: "hd"))
        #expect(hd.headers == ["User-Agent": "hd"] && hd.httpRequestSize == 10 << 20)
        #expect(Self.media.selecting(videoFormat: "4k") == nil)
    }

    @Test("Switching gives the request to load again at the position, with the track and title kept")
    func switchesRequest() throws {
        var request = MediaLoadRequest(path: "https://site.example/watch?v=1", audioTrack: "uk")
        request.startTime = 3
        let source = ResolvedSource(request: request, media: Self.media)
        let artwork = URL(string: "https://media.example/art")

        let (switched, media) = try #require(
            source.switching(
                to: "sd", startTime: 42.5, audioTrack: "2001", title: "Shown", artworkData: nil, artworkURL: artwork))
        #expect(switched.path == request.path)
        #expect(switched.startTime == 42.5 && switched.audioTrack == "2001")
        #expect(switched.title == "Shown" && switched.artworkURL == artwork)
        #expect(media.path == "https://media.example/sd")

        let automatic = try #require(
            source.switching(
                to: "sd", startTime: 0, audioTrack: nil, title: "", artworkData: nil, artworkURL: nil))
        #expect(automatic.request.audioTrack == nil, "A track chosen by the settings is chosen by them again")
    }

    @Test("There is nothing to switch to for the picture playing or one the page lacks")
    func refusesSamePictureAndUnknown() {
        let source = ResolvedSource(request: MediaLoadRequest(path: "https://site.example/watch"), media: Self.media)
        for id in ["hd", "4k"] {
            #expect(
                source.switching(to: id, startTime: 0, audioTrack: nil, title: "", artworkData: nil, artworkURL: nil)
                    == nil)
        }
    }
}
