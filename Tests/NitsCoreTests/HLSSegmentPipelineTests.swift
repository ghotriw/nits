import CFFmpeg
import CommonCrypto
import Foundation
import Testing

@testable import NitsCore

@Suite("HLS segment pipeline", .serialized, .networkServer, .backstopTimeLimit)
struct HLSSegmentPipelineTests {
    // MARK: Helpers

    private struct Stand {
        let server: TestHTTPServer
        let directory: URL
        let loader: HLSSegmentLoader
        let transport: HTTPSessionTransport

        func playlist(_ name: String) throws -> HLSMediaPlaylist {
            let url = try #require(URL(string: server.url(name)))
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard case .media(let media) = try HLSPlaylist.parse(data, url: url) else {
                throw TestError.notMedia
            }
            return media
        }
    }

    private enum TestError: Error { case notMedia }

    private static func stand(_ preset: SyntheticTestMediaFactory.Preset) throws -> Stand? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return nil }
        return try stand(directory: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    private static func stand(directory: URL) throws -> Stand {
        let server = try TestHTTPServer(root: directory)
        let transport = HTTPSessionTransport(source: server.url("x.m3u8"), headers: [:]) { false }
        return Stand(
            server: server, directory: directory, loader: HLSSegmentLoader(transport: transport), transport: transport)
    }

    /// Every packet of a run, as (stream kind, pts, dts) in seconds on the timeline.
    private struct Packet {
        let isVideo: Bool
        let pts: Double
        let dts: Double
    }

    private static func drain(_ reader: HLSSegmentReader) -> (packets: [Packet], code: Int32) {
        var packets: [Packet] = []
        let pointer = av_packet_alloc()!
        defer {
            var optional: UnsafeMutablePointer<AVPacket>? = pointer
            av_packet_free(&optional)
        }
        let streams = reader.streams
        while true {
            let code = reader.read(&pointer.pointee)
            if code < 0 { return (packets, code) }
            let stream = streams[Int(pointer.pointee.stream_index)]
            let base = Double(stream.pointee.time_base.num) / Double(stream.pointee.time_base.den)
            packets.append(
                Packet(
                    isVideo: stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                    pts: Double(pointer.pointee.pts) * base, dts: Double(pointer.pointee.dts) * base))
            av_packet_unref(pointer)
        }
    }

    /// A reader of the segments from `index` that share `playlist`'s first one's init section and discontinuity.
    private static func reader(
        _ stand: Stand, _ playlist: HLSMediaPlaylist, from index: Int = 0, start: Double
    ) throws(HLSSegmentReaderError) -> HLSSegmentReader {
        let first = playlist.segments[index]
        var cursor = index + 1
        let segments = playlist.segments
        return try HLSSegmentReader(loader: stand.loader, first: first, start: start) {
            guard cursor < segments.count, segments[cursor].initSection == first.initSection,
                segments[cursor].discontinuitySequence == first.discontinuitySequence
            else { return nil }
            defer { cursor += 1 }
            return segments[cursor]
        }
    }

    // MARK: Loader

    @Test("A segment comes whole; a byte range only its bytes, also from a server that answers it whole")
    func loadsSegmentsAndRanges() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let media = try stand.playlist("v0.m3u8")
        let segment = media.segments[0]
        let file = try Data(contentsOf: stand.directory.appendingPathComponent("v0_000.ts"))
        #expect(try stand.loader.segment(segment) == file)

        var ranged = segment
        ranged.byteRange = HLSByteRange(offset: 188, length: 376)
        #expect(try stand.loader.segment(ranged) == file.subdata(in: 188..<564))

        var behavior = TestHTTPServer.Behavior()
        behavior.ignoresRange = true
        stand.server.setDefaultBehavior(behavior)
        #expect(try stand.loader.segment(ranged) == file.subdata(in: 188..<564))
    }

    @Test("A server's refusal is the load's error")
    func reportsFailure() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        var behavior = TestHTTPServer.Behavior()
        behavior.failure = .status(404)
        stand.server.setDefaultBehavior(behavior)
        let segment = try stand.playlist("v0.m3u8").segments[0]
        #expect(throws: HLSSegmentLoadError.self) { try stand.loader.segment(segment) }
    }

    @Test("An AES-128 segment is decrypted with the key's bytes and the sequence number as IV; the key is fetched once")
    func decrypts() throws {
        guard let source = try Self.stand(.hlsVariants) else { return }
        source.server.stop()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-aes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data((0..<16).map { UInt8($0 * 7 + 1) })
        try key.write(to: directory.appendingPathComponent("key.bin"))
        var plain: [Data] = []
        for index in 0..<2 {
            let file = try Data(contentsOf: source.directory.appendingPathComponent("v0_00\(index).ts"))
            plain.append(file)
            let iv = HLSKey.initializationVector(sequence: 5 + index)
            try Self.encrypt(file, key: key, iv: iv).write(to: directory.appendingPathComponent("s\(index).ts"))
        }
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:5
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXTINF:2,
            s0.ts
            #EXTINF:2,
            s1.ts
            #EXT-X-ENDLIST
            """
        try text.write(to: directory.appendingPathComponent("p.m3u8"), atomically: true, encoding: .utf8)
        let stand = try Self.stand(directory: directory)
        defer { stand.server.stop() }
        let media = try stand.playlist("p.m3u8")
        #expect(try stand.loader.segment(media.segments[0]) == plain[0])
        #expect(try stand.loader.segment(media.segments[1]) == plain[1])
        #expect(stand.server.requests.filter { $0.path.hasSuffix("key.bin") }.count == 1)

        // The same bytes, read as a run, play.
        let reader = try Self.reader(stand, media, start: 0)
        #expect(Self.drain(reader).packets.count > 100)
    }

    private static func encrypt(_ data: Data, key: Data, iv: [UInt8]) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var produced = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count,
                            out.baseAddress, out.count, &produced)
                    }
                }
            }
        }
        #expect(status == kCCSuccess)
        output.removeSubrange(produced...)
        return output
    }

    @Test("An init section is fetched once for the segments that share it")
    func cachesInitSection() throws {
        guard let stand = try Self.stand(.hlsDiscontinuityFMP4) else { return }
        defer { stand.server.stop() }
        let media = try stand.playlist("media.m3u8")
        let section = try #require(media.segments[0].initSection)
        let first = try stand.loader.initSection(section)
        #expect(try stand.loader.initSection(section) == first)
        #expect(stand.server.requests.filter { $0.path.hasSuffix("minit0.mp4") }.count == 1)
    }

    // MARK: Reader

    @Test("MPEG-TS segments are one run on the playlist's timeline, from the start given")
    func readsTransportStream() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let media = try stand.playlist("v1.m3u8")
        for start in [0.0, 100.0] {
            let reader = try Self.reader(stand, media, start: start)
            let (packets, code) = Self.drain(reader)
            #expect(code == MediaDemuxer.averrorEOF)
            let video = packets.filter(\.isVideo)
            let audio = packets.filter { !$0.isVideo }
            #expect(video.count == 180, "\(video.count) pictures of 6 s at 30 fps")
            #expect(!audio.isEmpty)
            let first = try #require(video.map(\.pts).min())
            let last = try #require(video.map(\.pts).max())
            #expect(abs(first - start) < 0.05, "The first picture is at \(first - start) s into the run")
            #expect(abs(last - start - 5.97) < 0.1, "The last picture is at \(last - start) s")
            #expect(zip(video, video.dropFirst()).allSatisfy { $1.dts > $0.dts }, "Decode times grow")
            #expect(zip(audio, audio.dropFirst()).allSatisfy { $1.dts >= $0.dts })
            #expect((audio.map(\.pts).max() ?? 0) - start > 5.5, "The audio reaches the end")
        }
    }

    @Test("A run of a later segment is placed at the time given, whatever the media's own timestamps")
    func placesLaterSegment() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let media = try stand.playlist("v0.m3u8")
        let reader = try Self.reader(stand, media, from: 1, start: 2)
        let video = Self.drain(reader).packets.filter(\.isVideo)
        #expect(video.count == 120)
        #expect(abs((video.map(\.pts).min() ?? 0) - 2) < 0.05)
    }

    @Test("Fragmented MP4 runs split at the init section: each starts where the playlist puts it")
    func readsFragmentedMP4() throws {
        guard let stand = try Self.stand(.hlsDiscontinuityFMP4) else { return }
        defer { stand.server.stop() }
        let media = try stand.playlist("media.m3u8")
        #expect(media.segments[0].initSection != media.segments[1].initSection)
        let first = try Self.reader(stand, media, start: 0)
        let (firstPackets, firstCode) = Self.drain(first)
        #expect(firstCode == MediaDemuxer.averrorEOF)
        // The run stops at the second init section: one segment.
        let video = firstPackets.filter(\.isVideo)
        #expect(abs((video.map(\.pts).max() ?? 0) - 4) < 0.2)
        let second = try Self.reader(stand, media, from: 1, start: 4)
        let secondVideo = Self.drain(second).packets.filter(\.isVideo)
        #expect(abs((secondVideo.map(\.pts).min() ?? 0) - 4) < 0.05)
        #expect(abs((secondVideo.map(\.pts).max() ?? 0) - 8) < 0.2)
        let size = second.streams.first { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO }
        #expect(size?.pointee.codecpar.pointee.width == 640)
    }

    @Test(
        "A fragmented-MP4 run of several segments plays them all, also in byte ranges of one file",
        arguments: [
            (SyntheticTestMediaFactory.Preset.hlsVariantsFMP4, "v0.m3u8"), (.hlsVariantsSingleFile, "v0.m3u8"),
        ])
    func readsSeveralFragmentedSegments(preset: SyntheticTestMediaFactory.Preset, name: String) throws {
        guard let stand = try Self.stand(preset) else { return }
        defer { stand.server.stop() }
        let media = try stand.playlist(name)
        let reader = try Self.reader(stand, media, start: 0)
        let (packets, code) = Self.drain(reader)
        #expect(code == MediaDemuxer.averrorEOF)
        let video = packets.filter(\.isVideo)
        #expect(video.count == 180, "\(video.count) pictures of 6 s")
        #expect((video.map(\.pts).max() ?? 0) > 5.8)
    }

    @Test("Short fragments (half a second, five pictures) of one init section play through")
    func readsShortFragments() throws {
        guard let stand = try Self.stand(.hlsShortFragments) else { return }
        defer { stand.server.stop() }
        let media = try stand.playlist("media.m3u8")
        #expect(media.segments.count == 6)
        let reader = try Self.reader(stand, media, start: 0)
        let (packets, code) = Self.drain(reader)
        #expect(code == MediaDemuxer.averrorEOF)
        #expect(packets.count == 30, "\(packets.count) pictures of 3 s at 10 fps")
    }

    @Test("A segment that fails to load ends the run with its error, not as the end of the stream")
    func failedSegmentIsAnError() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        var behavior = TestHTTPServer.Behavior()
        behavior.failure = .status(404)
        stand.server.setBehavior(behavior) { $0.hasSuffix("v0_002.ts") }
        let media = try stand.playlist("v0.m3u8")
        let reader = try Self.reader(stand, media, start: 0)
        let (packets, code) = Self.drain(reader)
        #expect(code != MediaDemuxer.averrorEOF && code < 0)
        #expect(reader.failure != nil)
        #expect(packets.filter(\.isVideo).count >= 100, "The segments before it were read")
    }

    @Test("A first segment that doesn't load fails the opening")
    func failedOpening() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        var behavior = TestHTTPServer.Behavior()
        behavior.failure = .status(404)
        stand.server.setDefaultBehavior(behavior)
        let media = try stand.playlist("v0.m3u8")
        #expect(throws: HLSSegmentReaderError.self) { try Self.reader(stand, media, start: 0) }
    }

    @Test("WebVTT segments are placed by their X-TIMESTAMP-MAP and the media's shift")
    func readsWebVTT() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-vtt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:01.000 --> 00:02.000
        one
        """.write(to: directory.appendingPathComponent("a.vtt"), atomically: true, encoding: .utf8)
        try """
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:00:00:10.000,MPEGTS:1800000

        00:11.000 --> 00:12.000
        two
        """.write(to: directory.appendingPathComponent("b.vtt"), atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("c.vtt"))
        try """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXTINF:10,
        a.vtt
        #EXTINF:10,
        c.vtt
        #EXTINF:10,
        b.vtt
        #EXT-X-ENDLIST
        """.write(to: directory.appendingPathComponent("s.m3u8"), atomically: true, encoding: .utf8)
        let stand = try Self.stand(directory: directory)
        defer { stand.server.stop() }
        let media = try stand.playlist("s.m3u8")
        let segments = media.segments
        var cursor = 1
        var asked = 0
        let shift: () -> Double? = { -5 }
        let reader = try HLSSegmentReader(loader: stand.loader, first: segments[0], start: 0, timelineShift: shift) {
            asked += 1
            guard cursor < segments.count else { return nil }
            defer { cursor += 1 }
            return segments[cursor]
        }
        #expect(reader.isSegmentwise)
        var starts: [Double] = []
        let pointer = av_packet_alloc()!
        defer {
            var optional: UnsafeMutablePointer<AVPacket>? = pointer
            av_packet_free(&optional)
        }
        while reader.read(&pointer.pointee) >= 0 {
            starts.append(Double(pointer.pointee.pts) / 1000)
            av_packet_unref(pointer)
        }
        // Cue 1 s in at media time 10 s (900000 / 90000) → 11 s, less the shift 5; the second: 1 s past LOCAL 10 s at
        // 20 s → 21 s, less 5.
        // Read again after the end: the run is over, and asks for nothing more.
        let askedAtEnd = asked
        #expect(reader.read(&pointer.pointee) == MediaDemuxer.averrorEOF)
        #expect(asked == askedAtEnd)
        #expect(starts.count == 2 && abs(starts[0] - 6) < 0.01 && abs(starts[1] - 16) < 0.01, "\(starts)")
    }

    @Test("A WebVTT run that starts with an empty segment reads the ones after it")
    func readsWebVTTAfterEmptyFirstSegment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-vtt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("e.vtt"))
        try "WEBVTT\n\n00:01.000 --> 00:02.000\none\n".write(
            to: directory.appendingPathComponent("a.vtt"), atomically: true, encoding: .utf8)
        try "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\ne.vtt\n#EXTINF:10,\na.vtt\n#EXT-X-ENDLIST\n".write(
            to: directory.appendingPathComponent("s.m3u8"), atomically: true, encoding: .utf8)
        let stand = try Self.stand(directory: directory)
        defer { stand.server.stop() }
        let segments = try stand.playlist("s.m3u8").segments
        var cursor = 1
        let reader = try HLSSegmentReader(loader: stand.loader, first: segments[0], start: 0) {
            guard cursor < segments.count else { return nil }
            defer { cursor += 1 }
            return segments[cursor]
        }
        #expect(reader.isSegmentwise)
        let pointer = av_packet_alloc()!
        defer {
            var optional: UnsafeMutablePointer<AVPacket>? = pointer
            av_packet_free(&optional)
        }
        #expect(reader.read(&pointer.pointee) >= 0)
        #expect(pointer.pointee.pts == 1000)
        av_packet_unref(pointer)
        #expect(reader.read(&pointer.pointee) == MediaDemuxer.averrorEOF)
    }

    @Test("A WebVTT map written after the 33-bit wrap puts its cues beside media that began before it")
    func readsWebVTTAcrossTheWrap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-vtt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The media's clock stood at 2^33 - 90000 ticks (a second before the wrap) when the run began; the segment
        // is written after it: MPEGTS 90000 means a second past zero, 2 s later.
        try "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:90000,LOCAL:00:00:00.000\n\n00:00.500 --> 00:01.000\none\n".write(
            to: directory.appendingPathComponent("a.vtt"), atomically: true, encoding: .utf8)
        try "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\na.vtt\n#EXT-X-ENDLIST\n".write(
            to: directory.appendingPathComponent("s.m3u8"), atomically: true, encoding: .utf8)
        let stand = try Self.stand(directory: directory)
        defer { stand.server.stop() }
        let segment = try stand.playlist("s.m3u8").segments[0]
        let wrapSeconds = Double(Int64(1) << 33) / 90_000
        // timeline = media + shift, so the media's clock at `start` is `start - shift`.
        let shift: () -> Double? = { 100 - (wrapSeconds - 1) }
        let reader = try HLSSegmentReader(
            loader: stand.loader, first: segment, start: 100, timelineShift: shift
        ) { nil }
        let pointer = av_packet_alloc()!
        defer {
            var optional: UnsafeMutablePointer<AVPacket>? = pointer
            av_packet_free(&optional)
        }
        #expect(reader.read(&pointer.pointee) >= 0)
        // Media time 1.5 s past the wrap = wrapSeconds + 1.5, on the timeline 100 + 2.5 s.
        let seconds = Double(pointer.pointee.pts) / 1000
        #expect(abs(seconds - 102.5) < 0.01, "The cue is at \(seconds) s")
    }

    // MARK: Timestamps

    @Test("X-TIMESTAMP-MAP is read in either order, and absent means zero")
    func timestampMap() {
        let map = HLSTimestampMap.parse(
            webVTT: Data("WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:01.500,MPEGTS:180000\n\n".utf8))
        #expect(map == HLSTimestampMap(mpegts: 180_000, local: 1.5))
        #expect(map?.shift == 0.5)
        #expect(
            HLSTimestampMap.parse(
                webVTT: Data("WEBVTT\n\n00:01.000 --> 00:02.000\nX-TIMESTAMP-MAP=MPEGTS:1,LOCAL:0".utf8)) == nil)
        #expect(
            HLSTimestampMap.parse(webVTT: Data("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:abc,LOCAL:00:00:00.000\n".utf8)) == nil)
        #expect(HLSTimestampMap().shift == 0)
    }

    @Test("A 33-bit timestamp that wraps goes on growing, for the presentation time before the decode time too")
    func unwrapsTimestamps() throws {
        var unwrapper = try #require(TimestampUnwrapper(bits: 33))
        let wrap = Int64(1) << 33
        var last: Int64 = 0
        for value in stride(from: wrap - 5000, through: wrap + 5000, by: 1000) {
            let wrapped = value % wrap
            let placed = unwrapper.unwrap(pts: wrapped, dts: wrapped - 100 < 0 ? wrapped - 100 + wrap : wrapped - 100)
            #expect(placed.dts.map { $0 > last } ?? false || last == 0)
            last = placed.dts ?? last
        }
        #expect(last == wrap + 5000 - 100)
        #expect(TimestampUnwrapper(bits: 64) == nil)
    }
}
