import Foundation
import Testing

@testable import NitsCore

@Suite("HLS segments without an extension", .serialized, .hostDependent, .networkServer)
struct HLSSegmentExtensionTests {
    /// Google's ad server names segments `.../videoplayback/...` with no extension: FFmpeg's HLS demuxer refuses them
    /// unless `extension_picky` is off.
    @Test("A network playlist of segments with no extension opens and plays")
    func segmentsWithoutExtension() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsDiscontinuity) else { return }
        let source = URL(fileURLWithPath: path).deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NitsNoExtension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["seg0", "seg1"] {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent("\(name).ts"), to: directory.appendingPathComponent(name))
        }
        let playlist = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:8
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:4.0,
            seg0
            #EXTINF:8.0,
            seg1
            #EXT-X-ENDLIST

            """
        try Data(playlist.utf8).write(to: directory.appendingPathComponent("media.m3u8"))

        let server = try TestHTTPServer(root: directory)
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url("media.m3u8")), "The playlist must open")
        #expect(demuxer.hasVideo)
        let deadline = ContinuousClock.now + .seconds(10)
        var sample = demuxer.nextVideoSample()
        while sample == nil, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            sample = demuxer.nextVideoSample()
        }
        #expect(sample != nil)
    }
}
