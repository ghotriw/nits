import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// The `sidx` of a file that is a DASH representation (`SegmentBase`), read by the client's source to tell the file's
/// segments: one box, a chain, a hierarchy whose boxes lie past the bytes read.
@Suite("Segment index")
struct SegmentIndexTests {
    /// A `sidx` box of segments, (size, duration) each, after the box (`firstOffset` past it); those at `indexes` are
    /// references to boxes.
    static func sidx(
        _ references: [(size: UInt32, duration: UInt32)], timescale: UInt32 = 1000, earliest: UInt32 = 0,
        firstOffset: UInt32 = 0, indexes: Set<Int> = [], version: UInt8 = 0, startsWithSAP: Bool = true
    ) -> Data {
        func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * $0)) } }
        var body: [UInt8] = [version, 0, 0, 0] + be(1) + be(timescale)
        if version == 0 {
            body += be(earliest) + be(firstOffset)
        } else {
            body += be(0) + be(earliest) + be(0) + be(firstOffset)
        }
        body += [0, 0, UInt8(references.count >> 8), UInt8(references.count & 0xff)]
        for (position, reference) in references.enumerated() {
            body +=
                be(reference.size | (indexes.contains(position) ? 0x8000_0000 : 0)) + be(reference.duration)
                + be(startsWithSAP ? 0x9000_0000 : 0)
        }
        return Data(be(UInt32(body.count + 8)) + Array("sidx".utf8) + body)
    }

    /// The size of a box of `count` references (version 0).
    static func boxSize(_ count: Int) -> Int64 { Int64(32 + 12 * count) }

    @Test("The segments are where and when the index says, from the first byte after the box")
    func readsSegments() throws {
        let data = Self.sidx([(1000, 4000), (2000, 4000), (500, 2500)], timescale: 1000, earliest: 80, firstOffset: 10)
        let index = try #require(SegmentIndex.parse(data, at: 800))
        #expect(index.timescale == 1000 && index.startsWithSAP)
        // The box is 68 bytes from 800: 868, and the first offset of 10.
        #expect(index.segments.map(\.offset) == [878, 1878, 3878])
        #expect(index.segments.map(\.size) == [1000, 2000, 500])
        // From the earliest presentation time (the delay of B-frames), which no longer has to be near zero.
        #expect(index.segments.map(\.time) == [80, 4080, 8080])
        #expect(index.segments.map(\.duration) == [4000, 4000, 2500])
        #expect(SegmentIndex.parse(Self.sidx([(10, 4000)], earliest: 90_000), at: 0)?.segments.first?.time == 90_000)
        // Version 1 says the same.
        #expect(SegmentIndex.parse(Self.sidx([(1000, 4000)], version: 1), at: 0)?.segments.count == 1)
        #expect(SegmentIndex.parse(Self.sidx([(10, 4000)], startsWithSAP: false), at: 0)?.startsWithSAP == false)
    }

    @Test("A chain: the box a reference points to past the range is asked for, then its segments follow on")
    func chain() throws {
        // A | its media (1000) | B | B's media (300 + 400).
        let a = Self.sidx([(1000, 4000), (UInt32(Self.boxSize(2)) + 700, 3000)], indexes: [1])
        let bAt = Int64(a.count) + 1000
        let b = Self.sidx([(300, 1000), (400, 2000)])
        guard case .needs(let offset, let length) = try SegmentIndex.read([(0, a)]) else {
            Issue.record("Read without B")
            return
        }
        #expect(offset == bAt && length == Self.boxSize(2) + 700)
        // B as the probe brings it: the box and the start of its media.
        guard case .index(let index) = try SegmentIndex.read([(0, a), (bAt, b + Data(count: 50))]) else {
            Issue.record("Not read with B")
            return
        }
        #expect(index.segments.map(\.offset) == [Int64(a.count), bAt + Int64(b.count), bAt + Int64(b.count) + 300])
        #expect(index.segments.map(\.time) == [0, 4000, 5000])
    }

    @Test("A hierarchy: boxes within the range are read from it, the first one outside it is asked for")
    func hierarchy() throws {
        // Root | C1 | C1's media (500) | C2 | C2's media (600).
        let c1 = Self.sidx([(200, 1000), (300, 1000)])
        let c2 = Self.sidx([(600, 2000)])
        let root = Self.sidx(
            [(UInt32(c1.count) + 500, 2000), (UInt32(c2.count) + 600, 2000)], earliest: 100, indexes: [0, 1])
        let c2At = Int64(root.count + c1.count + 500)
        guard case .needs(let offset, _) = try SegmentIndex.read([(0, root + c1)]) else {
            Issue.record("Read without C2")
            return
        }
        #expect(offset == c2At)
        guard case .index(let index) = try SegmentIndex.read([(0, root + c1), (c2At, c2)]) else {
            Issue.record("Not read with C2")
            return
        }
        let c1Media = Int64(root.count + c1.count)
        #expect(index.segments.map(\.offset) == [c1Media, c1Media + 200, c2At + Int64(c2.count)])
        #expect(index.segments.map(\.time) == [100, 1100, 2100])
        // The size of a box larger than the bytes asked for, from its header.
        #expect(SegmentIndex.boxSize(in: c2.prefix(20)) == Int64(c2.count))
        #expect(SegmentIndex.boxSize(in: c2) == nil)
    }

    @Test("An index in a file of its own counts its offsets from the start of the media file")
    func externalIndex() throws {
        guard
            case .index(let index) = try SegmentIndex.read(
                [(0, Self.sidx([(100, 1), (200, 1)], firstOffset: 900))], external: true)
        else {
            Issue.record("Not read")
            return
        }
        #expect(index.segments.map(\.offset) == [900, 1000])
    }

    @Test("What is no index it reads is refused with a reason")
    func refusals() {
        func reason(_ data: Data) -> String? {
            do {
                _ = try SegmentIndex.read([(0, data)])
                return nil
            } catch {
                guard case .unreadable(let reason) = error else { return "\(error)" }
                return reason
            }
        }
        #expect(reason(Data("not an index".utf8)) == "no sidx in the index range")
        #expect(reason(Self.sidx([])) == "a sidx of no references")
        #expect(reason(Self.sidx([(10, 4000)], timescale: 0)) == "a sidx of timescale 0")
        #expect(reason(Self.sidx([(10, 4000)]).dropLast(3)) == "a sidx cut short")
        #expect(reason(Self.sidx([(10, 0)])) == "a sidx reference of no size or length")
        #expect(reason(Self.sidx([(10, 4000)], version: 2)) == "a sidx of version 2")
        // A box of boxes of another timescale.
        let child = Self.sidx([(10, 4000)], timescale: 90_000)
        #expect(
            reason(Self.sidx([(UInt32(child.count) + 10, 4000)], indexes: [0]) + child)
                == "boxes of different timescales")
    }
}

/// Files that are DASH representations, served as they are (`SegmentBase`, an index at their start): the client's
/// source reads each file's index, numbers a ladder of them by time, and a seek asks for the segment it lands in.
@Suite("Single file DASH", .serialized, .hostDependent, .networkServer)
struct SingleFileDASHTests {
    struct File {
        let name: String
        let size: Int
        /// Where its index (the first `sidx`) is.
        let index: ClosedRange<Int64>
    }

    struct Made {
        let directory: URL
        /// The pictures, the best first: 320×180 and 160×90 in segments of 2 s, and 160×90 in segments of 1.6 s,
        /// whose boundaries are not the others'.
        let videos: [File]
        let audio: File
    }

    /// `arguments` made into `file` by FFmpeg: its size and where its index (the first `sidx`) is.
    private static func run(_ ffmpeg: String, _ arguments: [String], into file: URL) -> (Int, ClosedRange<Int64>)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments =
            ["-hide_banner", "-loglevel", "error"] + arguments + [
                "-movflags", "+frag_keyframe+empty_moov+default_base_moof+global_sidx", file.path,
            ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: file) else { return nil }
        var position = 0
        while position + 8 <= data.count {
            let size = data[position..<(position + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard size >= 8 else { return nil }
            if String(decoding: data[(position + 4)..<(position + 8)], as: UTF8.self) == "sidx" {
                return (data.count, Int64(position)...Int64(position + size - 1))
            }
            position += size
        }
        return nil
    }

    /// 20 s of H.264 at three sizes and keyframe intervals, each in fragments of one keyframe with an index of them at
    /// the start (`global_sidx`), and of AAC in fragments of 2 s.
    static func make() -> Made? {
        guard let ffmpeg = SyntheticTestMediaFactory.ffmpegBinaryPath() else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsSingleFile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func video(_ name: String, size: String, bitrate: String, gop: Int) -> File? {
            run(
                ffmpeg,
                [
                    "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25:duration=20", "-c:v", "libx264", "-b:v",
                    bitrate, "-g", "\(gop)", "-keyint_min", "\(gop)", "-sc_threshold", "0", "-pix_fmt", "yuv420p",
                ], into: directory.appendingPathComponent(name)
            ).map { File(name: name, size: $0.0, index: $0.1) }
        }
        guard let high = video("v.mp4", size: "320x180", bitrate: "250k", gop: 50),
            let low = video("v-low.mp4", size: "160x90", bitrate: "100k", gop: 50),
            let odd = video("v-odd.mp4", size: "160x90", bitrate: "90k", gop: 40),
            let audio = run(
                ffmpeg,
                [
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=20", "-c:a", "aac",
                    "-frag_duration", "2000000",
                ], into: directory.appendingPathComponent("a.mp4"))
        else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return Made(
            directory: directory, videos: [high, low, odd], audio: File(name: "a.mp4", size: audio.0, index: audio.1))
    }

    /// The manifest of `made`'s pictures at `videos` (positions in `made.videos`) and its sound. `brokenIndex`: the
    /// pictures' index ranges point to their `moov`, no index; `brokenAudioIndex`: the sound's.
    static func manifest(
        _ made: Made, videos: [Int] = [0], brokenIndex: Bool = false, brokenAudioIndex: Bool = false
    ) -> String {
        func representation(_ file: File, id: String, attributes: String) -> String {
            let isBroken = file.name == made.audio.name ? brokenAudioIndex : brokenIndex
            let range = isBroken ? 0...(file.index.lowerBound - 1) : file.index
            return """
                <Representation id="\(id)" \(attributes)><BaseURL>\(file.name)</BaseURL>\
                <SegmentBase indexRange="\(range.lowerBound)-\(range.upperBound)">\
                <Initialization range="0-\(file.index.lowerBound - 1)"/></SegmentBase></Representation>
                """
        }
        let sizes = [
            "width=\"320\" height=\"180\" bandwidth=\"250000\"", "width=\"160\" height=\"90\" bandwidth=\"100000\"",
            "width=\"160\" height=\"90\" bandwidth=\"90000\"",
        ]
        let pictures = videos.map {
            representation(
                made.videos[$0], id: "v\($0)", attributes: #"mimeType="video/mp4" codecs="avc1.64000c" "# + sizes[$0])
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT20S" \
            profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period><AdaptationSet contentType="video">\
            \(pictures)</AdaptationSet><AdaptationSet contentType="audio" lang="en">\
            \(representation(made.audio, id: "a", attributes: #"mimeType="audio/mp4" codecs="mp4a.40.2" audioSamplingRate="44100" bandwidth="128000""#))\
            </AdaptationSet></Period></MPD>
            """
    }

    private static func startOffsets(_ ranges: [String]) -> [Int] {
        ranges.compactMap { $0.dropFirst("bytes=".count).split(separator: "-").first.flatMap { Int($0) } }
    }

    private static func served(_ made: Made, videos: [Int]) throws -> (TestHTTPServer, URL) {
        let server = try TestHTTPServer(root: made.directory)
        let manifest = Self.manifest(made, videos: videos)
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        return (server, try #require(URL(string: server.url("dash.mpd"))))
    }

    /// The requests for `file`'s index.
    private static func indexRequests(_ server: TestHTTPServer, _ file: File) -> Int {
        server.requests.filter {
            $0.path == file.name && $0.range == "bytes=\(file.index.lowerBound)-\(file.index.upperBound)"
        }.count
    }

    @Test("A ladder of files plays by its indexes: a rung of other boundaries is left out, each index is read once")
    func ladder() async throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let (server, manifestURL) = try Self.served(made, videos: [0, 1, 2])
        defer { server.stop() }
        // The resolver hands the files as they are; their ladder is the client's.
        let media = try #require(try await DASHManifestResolver().resolve(manifestURL, headers: [:]))
        let encoded = try #require(media.path.split(separator: ",").last)
        let text = String(decoding: try #require(Data(base64Encoded: String(encoded))), as: UTF8.self)
        #expect(text.contains("SegmentBase") && !text.contains("SegmentList"))
        #expect(media.videoFormats.isEmpty, "One codec: the rungs are the ladder's, not formats")
        #expect(server.requests.filter { $0.path.hasSuffix(".mp4") }.isEmpty, "The resolver read no index")

        let demuxer = try #require(MediaDemuxer(url: media.path, headers: media.headers))
        #expect(demuxer.input is HLSInput)
        #expect(demuxer.variants.count == 2, "\(demuxer.variants)")
        #expect(abs(demuxer.durationSeconds - 20) < 0.1)
        for file in made.videos + [made.audio] {
            #expect(Self.indexRequests(server, file) == 1, "\(file.name)'s index")
        }

        demuxer.startReadAhead(limits: .init(seconds: 30), held: true)
        demuxer.seek(to: 16.5, exact: true)
        let sample = try #require(demuxer.nextVideoSample())
        let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        #expect((14.0...16.6).contains(start), "Landed at \(start) s")
        var packet = demuxer.nextAudioPacket()
        for _ in 0..<200 where packet == nil {
            try await Task.sleep(for: .milliseconds(20))
            packet = demuxer.nextAudioPacket()
        }
        let heard = try #require(packet)
        let heardAt = Double(heard.pts) * Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den)
        #expect((14.0...16.6).contains(heardAt), "The sound is at \(heardAt) s")

        // The segments of the 16th second were asked for by their bytes, and the files were not read up to them.
        let video = Self.startOffsets(server.requests.filter { $0.path == "v.mp4" }.compactMap(\.range))
        #expect(video.contains { $0 > made.videos[0].size / 2 }, "Asked for \(video)")
        let sound = server.requests.filter { $0.path == "a.mp4" }.compactMap(\.range)
        #expect(sound.count < 12, "The sound was read from its start: \(sound)")
        #expect(!sound.contains("bytes=0-"))
    }

    @Test("The source tells a file's segments as byte ranges, after its initialization")
    func playlistOfAFile() throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let text = Self.manifest(made, videos: [0, 1])
        let address = made.directory.appendingPathComponent("dash.mpd")
        try Data(text.utf8).write(to: address)
        let source = DASHPlaylists(address: address)
        let loader = HLSSegmentLoader(
            transport: HTTPSessionTransport(source: address.absoluteString, headers: [:]) { false }, allowsFiles: true)
        guard case .master(let master) = try source.playlist(at: source.masterURL, variables: [:], loader: loader)
        else {
            Issue.record("Not a master")
            return
        }
        #expect(master.variants.count == 2)
        var playlists: [HLSMediaPlaylist] = []
        for variant in master.variants {
            guard case .media(let media) = try source.playlist(at: variant.url, variables: [:], loader: loader) else {
                Issue.record("Not a media playlist")
                return
            }
            playlists.append(media)
        }
        let high = playlists[0]
        #expect(high.segments.count == 10 && high.hasEnded)
        #expect(high.segments.allSatisfy { $0.url.lastPathComponent == "v.mp4" })
        #expect(
            high.segments.first?.initSection?.byteRange
                == HLSByteRange(offset: 0, length: made.videos[0].index.lowerBound))
        #expect(high.segments.first?.byteRange?.offset == made.videos[0].index.upperBound + 1)
        // End to end, up to the boxes after the last fragment (`mfra`).
        let ranges = high.segments.compactMap(\.byteRange)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.range.upperBound == $1.offset })
        #expect((ranges.last?.range.upperBound ?? 0) > Int64(made.videos[0].size) - 1000)
        // The lower rung takes the numbers of the best one's segments that start where its own do.
        #expect(playlists[1].segments.map(\.sequence) == high.segments.map(\.sequence))
    }

    @Test("A server that answers a range with the whole file: the index is cut from it, and the ladder opens")
    func serverIgnoringRanges() throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let (server, url) = try Self.served(made, videos: [0, 1])
        defer { server.stop() }
        server.setBehavior(.init(ignoresRange: true), forPaths: { $0 == "v-low.mp4" })
        let demuxer = try #require(MediaDemuxer(url: url.absoluteString))
        #expect(demuxer.input is HLSInput)
        #expect(demuxer.variants.count == 2)
        #expect(demuxer.nextVideoSample() != nil)
    }
}

extension SegmentIndexTests {
    /// The playlist of `file` (its index at `range`, its initialization the bytes before it) as the source tells it, or
    /// the reason it refuses it.
    private static func playlist(of file: Data, indexRange range: ClosedRange<Int>) throws -> Result<
        HLSMediaPlaylist, HLSPlaylistSourceError
    > {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsSegmentIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try file.write(to: directory.appendingPathComponent("a.mp4"))
        let address = directory.appendingPathComponent("a.mpd")
        try Data(
            """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT40S"><Period>\
            <AdaptationSet contentType="audio"><Representation id="a" mimeType="audio/mp4" codecs="mp4a.40.2" \
            bandwidth="1"><BaseURL>a.mp4</BaseURL><SegmentBase indexRange="\(range.lowerBound)-\(range.upperBound)"/>\
            </Representation></AdaptationSet></Period></MPD>
            """.utf8
        ).write(to: address)
        let source = DASHPlaylists(address: address)
        let loader = HLSSegmentLoader(
            transport: HTTPSessionTransport(source: address.absoluteString, headers: [:]) { false }, allowsFiles: true)
        do throws(HLSPlaylistSourceError) {
            guard case .media(let media) = try source.playlist(at: source.masterURL, variables: [:], loader: loader)
            else {
                return .failure(.unsupported("a master"))
            }
            return .success(media)
        } catch {
            return .failure(error)
        }
    }

    @Test("The source asks for the boxes of a hierarchy past the index range, as many as its bound allows")
    func hierarchyThroughTheSource() throws {
        // An initialization of 100 bytes | Root | C1 | C1's media (500) | C2 | C2's media (1500). C2 is larger than the
        // probe (1500 references): its rest is asked for.
        let c1 = Self.sidx([(200, 1000), (300, 1000)])
        let c2 = Self.sidx(Array(repeating: (1, 1), count: 1500))
        #expect(Int64(c2.count) > SegmentIndex.boxProbeSize)
        let root = Self.sidx([(UInt32(c1.count) + 500, 2000), (UInt32(c2.count) + 1500, 1500)], indexes: [0, 1])
        let file = Data(count: 100) + root + c1 + Data(count: 500) + c2 + Data(count: 1500)
        let media = try Self.playlist(of: file, indexRange: 100...(100 + root.count + c1.count - 1)).get()
        #expect(media.segments.count == 1502)
        #expect(media.segments.prefix(2).map(\.duration) == [1, 1])
        let c2Media = Int64(100 + root.count + c1.count + 500 + c2.count)
        #expect(media.segments.compactMap(\.byteRange?.offset).last == c2Media + 1499)
        #expect(media.segments.first?.initSection?.byteRange == HLSByteRange(offset: 0, length: 100))

        // A chain of more boxes than the bound: each past the range is a request.
        let count = SegmentIndex.requestLimit + 3
        var tail = Data()
        for position in (0..<count).reversed() {
            let box =
                position == count - 1
                ? Self.sidx([(10, 1000)])
                : Self.sidx([(10, 1000), (UInt32(tail.count), 1000)], indexes: [1])
            tail = box + Data(count: 10) + tail
        }
        let first = Self.boxSize(2)
        let refused = try Self.playlist(of: Data(count: 100) + tail, indexRange: 100...(100 + Int(first) - 1))
        #expect(
            refused == .failure(.unsupported("an index of more than \(SegmentIndex.requestLimit) parts past its range"))
        )
    }
}

extension SingleFileDASHTests {
    @Test("A sound whose index is refused refuses the stream: not played silent")
    func refusedSoundRefusesTheStream() throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let server = try TestHTTPServer(root: made.directory)
        defer { server.stop() }
        let manifest = Self.manifest(made, videos: [0], brokenAudioIndex: true)
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        let source = DASHPlaylists(address: try #require(URL(string: server.url("dash.mpd"))))
        // The client alone opens the picture and goes on without the sound; the source tells why.
        let interrupt = FFmpegInterrupt()
        let input = HLSInput(
            master: source.masterURL, playlists: source, source: source.address.absoluteString, allowsFiles: false,
            headers: [:], interrupt: interrupt, streamingName: "DASH")
        #expect(input != nil)
        input?.close()
        #expect(source.refusal?.contains("no sidx") == true, "\(source.refusal ?? "nil")")

        let demuxer = MediaDemuxer(url: server.url("dash.mpd"))
        #expect(demuxer == nil, "A refusal is the opening's failure")
    }
}

extension SegmentIndexTests {
    @Test("Segments before the period (an offset past the index's start) are left out, one across its start begins it")
    func segmentsBeforeThePeriod() throws {
        let index = try #require(SegmentIndex.parse(Self.sidx([(10, 1000), (10, 1000), (10, 1000)]), at: 0))
        let location = DASHPresentation.IndexLocation(
            media: URL(string: "https://cdn.example/a.mp4")!, url: URL(string: "https://cdn.example/a.mp4")!,
            range: try #require(HLSByteRange(offset: 0, length: 1)))
        let representation = DASHPresentation.Representation(
            id: "a", kind: .audio, bandwidth: 1, roleRank: 1, set: 0, presentationTimeOffset: 1.5, segments: [],
            index: location)
        let segments = DASHPresentation.segments(from: index, of: representation, periodDuration: 10)
        #expect(segments.map(\.start) == [0, 0.5])
        #expect(segments.map(\.duration) == [0.5, 1])
        #expect(segments.compactMap(\.byteRange?.offset) == [Int64(Self.boxSize(3)) + 10, Int64(Self.boxSize(3)) + 20])
    }
}
