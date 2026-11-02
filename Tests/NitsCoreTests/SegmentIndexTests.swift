import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// The `sidx` of a file that is a DASH representation (`SegmentBase`), read for the manifest to say its segments.
@Suite("Segment index")
struct SegmentIndexTests {
    /// A `sidx` box (version 0) of segments: (size, duration) each, after the box.
    static func sidx(
        _ references: [(size: UInt32, duration: UInt32)], timescale: UInt32 = 1000, earliest: UInt32 = 0,
        firstOffset: UInt32 = 0, isIndex: Bool = false, version: UInt8 = 0, startsWithSAP: Bool = true
    ) -> Data {
        func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * $0)) } }
        var body: [UInt8] = [version, 0, 0, 0] + be(1) + be(timescale)
        if version == 0 {
            body += be(earliest) + be(firstOffset)
        } else {
            body += be(0) + be(earliest) + be(0) + be(firstOffset)
        }
        body += [0, 0, UInt8(references.count >> 8), UInt8(references.count & 0xff)]
        for reference in references {
            body +=
                be(reference.size | (isIndex ? 0x8000_0000 : 0)) + be(reference.duration)
                + be(startsWithSAP ? 0x9000_0000 : 0)
        }
        return Data(be(UInt32(body.count + 8)) + Array("sidx".utf8) + body)
    }

    @Test("The segments are where the index says, from the first byte after the box; their length is the regular one")
    func readsSegments() throws {
        let data = Self.sidx([(1000, 4000), (2000, 4000), (500, 2500)], timescale: 1000, firstOffset: 10)
        let index = try #require(SegmentIndex.parse(data, at: 800))
        #expect(index.timescale == 1000 && index.durations == [4000, 4000, 2500] && index.isRegular)
        // The box is 68 bytes from 800: 868, and the first offset of 10.
        #expect(index.segments.map(\.offset) == [878, 1878, 3878])
        #expect(index.segments.map(\.size) == [1000, 2000, 500])
        // Version 1 says the same.
        #expect(SegmentIndex.parse(Self.sidx([(1000, 4000)], version: 1), at: 0)?.segments.count == 1)
    }

    @Test("Segments of lengths that differ are not regular, and their runs are told as a timeline has them")
    func irregularLengths() throws {
        let index = try #require(
            SegmentIndex.parse(Self.sidx([(10, 4000), (10, 4000), (10, 3000), (10, 4000), (10, 5000)]), at: 0))
        #expect(!index.isRegular)
        #expect(index.runs.map(\.duration) == [4000, 3000, 4000, 5000] && index.runs.map(\.repeats) == [1, 0, 0, 0])
        // The last one longer than the first is not regular, either.
        #expect(try #require(SegmentIndex.parse(Self.sidx([(10, 4000), (10, 5000)]), at: 0)).isRegular == false)
    }

    @Test("An index the demuxer cannot be given as a list is left alone")
    func refusesWhatItCannotSay() {
        #expect(SegmentIndex.parse(Self.sidx([(10, 4000)], earliest: 500), at: 0) == nil, "Starts late")
        #expect(SegmentIndex.parse(Self.sidx([(10, 4000)], earliest: 300), at: 0) != nil, "A little late")
        #expect(SegmentIndex.parse(Self.sidx([(10, 4000)], isIndex: true), at: 0) == nil, "An index of indexes")
        #expect(SegmentIndex.parse(Self.sidx([]), at: 0) == nil)
        #expect(SegmentIndex.parse(Data("not an index".utf8), at: 0) == nil)
        #expect(SegmentIndex.parse(Self.sidx([(10, 1)]) + Self.sidx([(10, 1)]), at: 0) == nil, "Two")
        #expect(SegmentIndex.parse(Self.sidx([(10, 4000)]).dropLast(3), at: 0) == nil, "Cut short")
    }

    private static let singleFile = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT12S" \
        profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period>
        <AdaptationSet contentType="video"><Representation id="v" mimeType="video/mp4" codecs="avc1.64000c" \
        width="320" height="180" bandwidth="250000"><BaseURL>media/v.mp4</BaseURL>\
        <SegmentBase indexRange="800-851"><Initialization range="0-799"/></SegmentBase></Representation>\
        </AdaptationSet></Period></MPD>
        """

    @Test("A single file asks for its index, and says its segments once it has it; the profile stays")
    func manifestSaysTheSegments() throws {
        var manifest = try #require(
            DASHManifest(
                data: Data(Self.singleFile.utf8), url: URL(string: "https://cdn.example/show/manifest.mpd")!))
        let request = try #require(manifest.indexRequests.first)
        #expect(manifest.indexRequests.count == 1)
        #expect(request.url.absoluteString == "https://cdn.example/show/media/v.mp4")
        #expect(request.range == 800...851)
        // Without the index the file is what it was.
        #expect(try #require(manifest.text()).contains("SegmentBase"))

        let index = try #require(
            SegmentIndex.parse(Self.sidx([(1000, 4000), (2000, 4000), (500, 2000)], timescale: 1000), at: 800))
        manifest.setIndex(index, for: request)
        let text = try #require(manifest.text())
        #expect(!text.contains("SegmentBase"))
        #expect(text.contains(#"<SegmentList timescale="1000" duration="4000">"#))
        #expect(text.contains(#"<Initialization range="0-799"/>"#))
        #expect(text.contains(#"mediaRange="868-1867""#) && text.contains(#"mediaRange="3868-4367""#))
        #expect(text.contains("profiles="), "FFmpeg opens no manifest without the profile")
        // Still a picture of its own, not a ladder: a switch to a single file reads it from its start.
        #expect(manifest.videos.first?.isSegmented == false)
    }

    @Test("Pictures with segments of their own, and files with no index range, ask for nothing")
    func asksForSingleFilesOnly() throws {
        let segmented = DASHManifestTests.manifest(
            """
            <AdaptationSet contentType="video"><SegmentTemplate media="s/$Number$" timescale="1" duration="1"/>
            \(DASHManifestTests.video("a", 640, 360, bandwidth: 1))</AdaptationSet>
            """)
        let segmentedManifest = try #require(segmented)
        #expect(segmentedManifest.indexRequests.isEmpty)
        let noIndex = DASHManifestTests.manifest(
            """
            <AdaptationSet contentType="video">\(DASHManifestTests.video("a", 640, 360, bandwidth: 1))</AdaptationSet>
            """)
        let noIndexManifest = try #require(noIndex)
        #expect(noIndexManifest.indexRequests.isEmpty)
    }
}

/// Files that are DASH representations, served as they are: the manifest's `SegmentBase` becomes their segments, and a
/// seek asks for the one it lands in, in the picture and in the sound.
@Suite("Single file DASH", .serialized)
struct SingleFileDASHTests {
    struct Made {
        let directory: URL
        let videoSize: Int
        let videoIndex: ClosedRange<Int64>
        let audioIndex: ClosedRange<Int64>
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

    /// 20 s of H.264 in fragments of 2 s with an index of them at the start (`global_sidx`), and of AAC in fragments of
    /// about as long, whose lengths differ (a frame is 1024 samples).
    static func make() -> Made? {
        guard av_find_input_format("dash") != nil, let ffmpeg = SyntheticTestMediaFactory.ffmpegBinaryPath() else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsSingleFile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard
            let video = run(
                ffmpeg,
                [
                    "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=20", "-c:v", "libx264", "-g", "50",
                    "-keyint_min", "50", "-sc_threshold", "0", "-pix_fmt", "yuv420p",
                ], into: directory.appendingPathComponent("v.mp4")),
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
        // Its fragments are of whole frames, all as long: one is made a sample shorter in the index, as a muxer that
        // cuts at a time would have it, so that the lengths differ.
        let audioFile = directory.appendingPathComponent("a.mp4")
        if var bytes = try? Data(contentsOf: audioFile) {
            let box = Int(audio.1.lowerBound)
            let references = box + (bytes[box + 8] == 0 ? 32 : 40)
            let duration = references + 2 * 12 + 4
            bytes[duration + 3] = bytes[duration + 3] &- 1
            try? bytes.write(to: audioFile)
        }
        return Made(directory: directory, videoSize: video.0, videoIndex: video.1, audioIndex: audio.1)
    }

    static func manifest(_ made: Made) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT20S" \
        profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period><AdaptationSet contentType="video">\
        <Representation id="v" mimeType="video/mp4" codecs="avc1.64000c" width="320" height="180" \
        bandwidth="250000"><BaseURL>v.mp4</BaseURL><SegmentBase indexRange="\(made.videoIndex.lowerBound)-\(made.videoIndex.upperBound)">\
        <Initialization range="0-\(made.videoIndex.lowerBound - 1)"/></SegmentBase></Representation></AdaptationSet>\
        <AdaptationSet contentType="audio" lang="en"><Representation id="a" mimeType="audio/mp4" codecs="mp4a.40.2" \
        audioSamplingRate="44100" bandwidth="128000"><BaseURL>a.mp4</BaseURL>\
        <SegmentBase indexRange="\(made.audioIndex.lowerBound)-\(made.audioIndex.upperBound)">\
        <Initialization range="0-\(made.audioIndex.lowerBound - 1)"/></SegmentBase></Representation></AdaptationSet>\
        </Period></MPD>
        """
    }

    private static func startOffsets(_ ranges: [String]) -> [Int] {
        ranges.compactMap { $0.dropFirst("bytes=".count).split(separator: "-").first.flatMap { Int($0) } }
    }

    @Test("Resuming late in files with an index asks for the segment there, not for the file from its start")
    func seeksBySegment() async throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let server = try TestHTTPServer(root: made.directory)
        defer { server.stop() }
        let manifest = Self.manifest(made)
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        let manifestURL = try #require(URL(string: server.url("dash.mpd")))
        let media = try #require(try await DASHManifestResolver().resolve(manifestURL, headers: [:]))
        let encoded = try #require(media.path.split(separator: ",").last)
        let decoded = try #require(Data(base64Encoded: String(encoded)))
        let text = String(decoding: decoded, as: UTF8.self)
        #expect(text.contains("SegmentList") && !text.contains("SegmentBase"))
        // The sound's segments differ in length: told by a timeline, before the representation that is read after.
        let timeline = try #require(text.range(of: "<SegmentTimeline"))
        let audio = try #require(text.range(of: #"<Representation audioSamplingRate"#))
        #expect(timeline.lowerBound < audio.lowerBound, "The demuxer reads a set's list only if it comes first")

        let demuxer = try #require(MediaDemuxer(url: media.path, headers: media.headers))
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

        // The segments of the second 16 were asked for by their bytes, and the files were not read up to them.
        let video = Self.startOffsets(server.requests.filter { $0.path == "v.mp4" }.compactMap(\.range))
        #expect(video.contains { $0 > made.videoSize / 2 }, "Asked for \(video)")
        let sound = server.requests.filter { $0.path == "a.mp4" }.compactMap(\.range)
        #expect(sound.count < 12, "The sound was read from its start: \(sound)")
        #expect(!sound.contains("bytes=0-"))
    }
}

extension SegmentIndexTests {
    @Test("Lengths that differ are told by a timeline in the set's list, for a set of one representation")
    func irregularIndexGetsATimeline() throws {
        var manifest = try #require(
            DASHManifest(
                data: Data(Self.singleFile.utf8), url: URL(string: "https://cdn.example/show/manifest.mpd")!))
        let request = try #require(manifest.indexRequests.first)
        let index = try #require(
            SegmentIndex.parse(Self.sidx([(1000, 4000), (2000, 4000), (500, 3000), (500, 4000)]), at: 800))
        manifest.setIndex(index, for: request)
        let text = try #require(manifest.text())
        // The representation's list has the segments and no length of one; the set's has their lengths.
        #expect(text.contains(#"<SegmentList timescale="1000"><Initialization"#), "\(text)")
        #expect(text.contains(#"<SegmentTimeline><S d="4000" r="1"/><S d="3000"/><S d="4000"/></SegmentTimeline>"#))
        #expect(!text.contains("SegmentBase"))
        let timelineAt = try #require(text.range(of: "<SegmentTimeline"))
        let representationAt = try #require(text.range(of: "<Representation"))
        #expect(
            timelineAt.lowerBound < representationAt.lowerBound, "The set's list first"
        )
    }
}

extension SegmentIndexTests {
    @Test("An index says whether its segments start at a keyframe; a picture's that do not are not used")
    func segmentsStartingAtKeyframes() throws {
        #expect(try #require(SegmentIndex.parse(Self.sidx([(10, 4000)]), at: 0)).startsWithSAP)
        #expect(
            try #require(SegmentIndex.parse(Self.sidx([(10, 4000)], startsWithSAP: false), at: 0)).startsWithSAP
                == false)
    }

    @Test("A file whose index range is large, or with a time offset of its own, is left as it is")
    func leavesOddFilesAlone() throws {
        let url = URL(string: "https://cdn.example/show/manifest.mpd")!
        let large = Self.singleFile.replacingOccurrences(
            of: #"indexRange="800-851""#, with: #"indexRange="800-9000000""#)
        #expect(try #require(DASHManifest(data: Data(large.utf8), url: url)).indexRequests.isEmpty)
        let offset = Self.singleFile.replacingOccurrences(
            of: #"<SegmentBase indexRange"#, with: #"<SegmentBase presentationTimeOffset="48000" indexRange"#)
        #expect(try #require(DASHManifest(data: Data(offset.utf8), url: url)).indexRequests.isEmpty)
        #expect(try #require(DASHManifest(data: Data(Self.singleFile.utf8), url: url)).indexRequests.count == 1)
    }
}

extension SingleFileDASHTests {
    private static func served(_ made: Made) throws -> (TestHTTPServer, URL) {
        let server = try TestHTTPServer(root: made.directory)
        let manifest = Self.manifest(made)
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        return (server, try #require(URL(string: server.url("dash.mpd"))))
    }

    @Test("A server that sends the file to a range request is not waited on: the file plays as it is")
    func serverIgnoringRanges() async throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let (server, url) = try Self.served(made)
        defer { server.stop() }
        server.setBehavior(.init(ignoresRange: true), forPaths: { $0 == "v.mp4" })
        let media = try #require(try await DASHManifestResolver().resolve(url, headers: [:]))
        let encoded = try #require(media.path.split(separator: ",").last)
        let text = String(decoding: try #require(Data(base64Encoded: String(encoded))), as: UTF8.self)
        // The picture stays a single file; the sound, answered as asked, is listed.
        #expect(text.contains("SegmentBase") && text.contains("SegmentList"))
    }

    @Test("Indexes that take too long are given up on, and the files play as they are")
    func indexesOverTheBudget() async throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let (server, url) = try Self.served(made)
        defer { server.stop() }
        server.setBehavior(.init(delay: .seconds(20)), forPaths: { $0 == "a.mp4" })
        var resolver = DASHManifestResolver()
        resolver.indexBudget = .seconds(1)
        let started = ContinuousClock.now
        let media = try #require(try await resolver.resolve(url, headers: [:]))
        #expect(ContinuousClock.now - started < .seconds(8), "Waited for the slow index")
        let encoded = try #require(media.path.split(separator: ",").last)
        let text = String(decoding: try #require(Data(base64Encoded: String(encoded))), as: UTF8.self)
        // The picture, answered in time, is listed; the sound, not.
        #expect(text.contains("SegmentList") && text.contains("SegmentBase"))
    }
}
