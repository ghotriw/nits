import Foundation
import Testing

@testable import NitsCore

/// Reads of a subtitle rendition outside playback (`EmbeddedSubtitleReader.readSubtitles(hls:in:interrupt:)`) over a
/// playlist with a discontinuity: cues are placed by their sequence's offset, which only the pictures anchor.
@Suite("HLS subtitle window reads", .serialized)
struct HLSSubtitleWindowTests {
    /// Three segments of 10 s, the last after a discontinuity (sequence 1); no cues in the second.
    private static func makeSource(directory: URL) throws -> (
        source: HLSSubtitleWindowSource, anchors: HLSTimestampAnchors
    ) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "WEBVTT\n\n00:01.000 --> 00:02.000\none\n".write(
            to: directory.appendingPathComponent("a.vtt"), atomically: true, encoding: .utf8)
        try "WEBVTT\n".write(to: directory.appendingPathComponent("b.vtt"), atomically: true, encoding: .utf8)
        try "WEBVTT\n\n00:01.000 --> 00:02.000\nthree\n".write(
            to: directory.appendingPathComponent("c.vtt"), atomically: true, encoding: .utf8)
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:10
            #EXTINF:10,
            a.vtt
            #EXTINF:10,
            b.vtt
            #EXT-X-DISCONTINUITY
            #EXTINF:10,
            c.vtt
            #EXT-X-ENDLIST
            """
        let url = directory.appendingPathComponent("s.m3u8")
        try text.write(to: url, atomically: true, encoding: .utf8)
        guard case .media(let playlist) = try HLSPlaylist.parse(text, url: url) else { throw CancellationError() }
        let anchors = HLSTimestampAnchors()
        let source = HLSSubtitleWindowSource(
            address: url.path, headers: [:], allowsFiles: true, url: url, timeline: HLSTimeline(playlist),
            variables: [:], anchors: anchors, cookies: { [] })
        return (source, anchors)
    }

    private static func anchor(_ anchors: HLSTimestampAnchors, sequence: Int, start: Double, offset: Double) {
        _ = anchors.offset(
            of: sequence, start: start, first: start - offset, tolerance: 10, role: .picture, nearest: { $0 })
    }

    @Test("A read stops at a discontinuity the pictures have not anchored, and covers up to it")
    func stopsAtUnanchoredBreak() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, anchors) = try Self.makeSource(directory: directory)
        Self.anchor(anchors, sequence: 0, start: 0, offset: 0)

        let window = try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 0...25))
        #expect(window.packets.cues.map(\.text) == ["one"])
        #expect(window.covered == 0...20)
        // The whole track is not known until the break is anchored.
        let whole = try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 0...Double.infinity))
        #expect(whole.covered?.upperBound == 20)
        // A window that starts at the break can't be placed at all.
        let after = try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 21...25))
        #expect(after.covered == nil)

        // Anchored by the pictures (the timeline's 20 s is 5 s into their clock), the cues past the break are placed.
        Self.anchor(anchors, sequence: 1, start: 20, offset: 5)
        let full = try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 0...Double.infinity))
        #expect(full.covered?.upperBound == .infinity)
        #expect(full.packets.cues.map(\.text) == ["one", "three"])
        #expect(abs((full.packets.cues.last?.startTime ?? 0) - 6) < 0.01, "\(full.packets.cues.map(\.startTime))")
    }

    @Test("Nothing is read before the pictures have anchored anything, even with a single sequence")
    func nothingBeforeAnyAnchor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, anchors) = try Self.makeSource(directory: directory)
        #expect(try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 0...5)).covered == nil)
        Self.anchor(anchors, sequence: 0, start: 0, offset: 0)
        #expect(try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 0...5)).covered == 0...5)
    }

    @Test("A window that ends where a break starts loads nothing of the segment after it")
    func windowEndingAtBreak() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, anchors) = try Self.makeSource(directory: directory)
        Self.anchor(anchors, sequence: 0, start: 0, offset: 0)
        let window = try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 10...20))
        #expect(window.covered == 10...20)
        #expect(window.packets.cues.isEmpty, "\(window.packets.cues.map(\.text))")
    }

    @Test("A window that starts in a sequence nobody anchored is read from the first one that is")
    func leadingUnanchoredStretch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, anchors) = try Self.makeSource(directory: directory)
        Self.anchor(anchors, sequence: 1, start: 20, offset: 0)
        let window = try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 5...25))
        #expect(window.covered == 20...25)
        #expect(window.packets.cues.map(\.text) == ["three"])
    }

    @Test("A window loads no segment past its end")
    func loadsNothingPastTheEnd() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, anchors) = try Self.makeSource(directory: directory)
        Self.anchor(anchors, sequence: 0, start: 0, offset: 0)
        Self.anchor(anchors, sequence: 1, start: 20, offset: 0)
        // The first segment holds the cue; deleting the others proves they are not asked for.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("b.vtt"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("c.vtt"))
        let window = try #require(EmbeddedSubtitleReader.readSubtitles(hls: source, in: 0...5))
        #expect(window.packets.cues.map(\.text) == ["one"])
        #expect(window.covered == 0...5)
    }
}
