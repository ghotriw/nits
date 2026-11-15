import CoreMedia
import Foundation
import Testing

@testable import NitsCore
@testable import NitsStreaming

/// WebM files that are DASH representations (`SegmentBase`, `Cues` as the index), served as they are: the client's source
/// reads each file's cues, and a seek asks for the cluster it lands in.
@Suite("Single file WebM DASH", .serialized, .hostDependent, .networkServer)
struct WebMSingleFileDASHTests {
    struct File {
        let name: String
        let size: Int
        /// The file's start up to its `Cues`, and the `Cues` element.
        let initRange: ClosedRange<Int64>
        let indexRange: ClosedRange<Int64>
        /// Where the first cluster is.
        let firstCluster: Int64
    }

    struct Made {
        let directory: URL
        let video: File
        let audio: File
    }

    /// Reads the top-level elements of a Segment: where `Cues` and the first `Cluster` are.
    private static func layout(of data: Data, name: String) -> File? {
        let bytes = [UInt8](data)
        func element(at position: Int) -> (id: UInt32, content: Int, size: Int?)? {
            guard position < bytes.count else { return nil }
            let idLength = bytes[position].leadingZeroBitCount + 1
            guard idLength <= 4, position + idLength < bytes.count else { return nil }
            let id = bytes[position..<(position + idLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let sizeAt = position + idLength
            let sizeLength = bytes[sizeAt].leadingZeroBitCount + 1
            guard sizeLength <= 8, sizeAt + sizeLength <= bytes.count else { return nil }
            var value = UInt64(bytes[sizeAt]) & (0xFF >> UInt64(sizeLength))
            for byte in bytes[(sizeAt + 1)..<(sizeAt + sizeLength)] { value = value << 8 | UInt64(byte) }
            return (id, sizeAt + sizeLength, Int(value))
        }
        guard let ebml = element(at: 0), let size = ebml.size,
            let segment = element(at: ebml.content + size), segment.id == 0x1853_8067
        else { return nil }
        var position = segment.content
        var cues: ClosedRange<Int64>?
        while let top = element(at: position), let size = top.size {
            if top.id == 0x1F43_B675 {
                guard let cues else { return nil }
                return File(
                    name: name, size: data.count, initRange: 0...(cues.lowerBound - 1), indexRange: cues,
                    firstCluster: Int64(position))
            }
            if top.id == 0x1C53_BB6B { cues = Int64(position)...Int64(top.content + size - 1) }
            position = top.content + size
        }
        return nil
    }

    private static func run(_ ffmpeg: String, _ arguments: [String], into file: URL) -> File? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments =
            ["-hide_banner", "-loglevel", "error"] + arguments + ["-cues_to_front", "1", "-f", "webm", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: file) else { return nil }
        return layout(of: data, name: file.lastPathComponent)
    }

    /// 20 s of VP9 with a keyframe every 2 s, and of Opus, each with its cues before the clusters.
    static func make() -> Made? {
        guard let ffmpeg = SyntheticTestMediaFactory.ffmpegBinaryPath() else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsWebMDASH-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard
            let video = run(
                ffmpeg,
                [
                    "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=25:duration=20", "-c:v", "libvpx-vp9", "-b:v",
                    "100k", "-g", "50", "-keyint_min", "50",
                ], into: directory.appendingPathComponent("v.webm")),
            let audio = run(
                ffmpeg,
                ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=20", "-c:a", "libopus"],
                into: directory.appendingPathComponent("a.webm"))
        else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return Made(directory: directory, video: video, audio: audio)
    }

    static func manifest(_ made: Made) -> String {
        func representation(_ file: File, id: String, attributes: String) -> String {
            """
            <Representation id="\(id)" \(attributes)><BaseURL>\(file.name)</BaseURL>\
            <SegmentBase indexRange="\(file.indexRange.lowerBound)-\(file.indexRange.upperBound)">\
            <Initialization range="\(file.initRange.lowerBound)-\(file.initRange.upperBound)"/></SegmentBase>\
            </Representation>
            """
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT20S" \
            profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period><AdaptationSet contentType="video">\
            \(representation(made.video, id: "v", attributes: #"mimeType="video/webm" codecs="vp9" width="160" height="90" bandwidth="100000""#))\
            </AdaptationSet><AdaptationSet contentType="audio" lang="en">\
            \(representation(made.audio, id: "a", attributes: #"mimeType="audio/webm" codecs="opus" audioSamplingRate="48000" bandwidth="64000""#))\
            </AdaptationSet></Period></MPD>
            """
    }

    @Test("The source tells a WebM file's clusters as byte ranges, after its start")
    func playlistOfAFile() throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let address = made.directory.appendingPathComponent("dash.mpd")
        try Data(Self.manifest(made).utf8).write(to: address)
        let source = DASHPlaylists(address: address)
        let loader = SegmentLoader(
            transport: HTTPSessionTransport(source: address.absoluteString, headers: [:]) { false }, allowsFiles: true)
        guard
            case .multivariant(let multivariant) = try source.playlist(
                at: source.multivariantURL, variables: [:], loader: loader),
            let variant = multivariant.variants.first,
            case .media(let media) = try source.playlist(at: variant.url, variables: [:], loader: loader)
        else {
            Issue.record("No media playlist")
            return
        }
        #expect(media.segments.count == 10 && media.hasEnded)
        #expect(media.segments.allSatisfy { $0.url.lastPathComponent == "v.webm" })
        #expect(
            media.segments.first?.initSection?.byteRange
                == ByteRange(offset: 0, length: made.video.indexRange.lowerBound))
        #expect(media.segments.first?.byteRange?.offset == made.video.firstCluster)
        // End to end: each cluster ends where the next starts, the last with the file.
        let ranges = media.segments.compactMap(\.byteRange)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.range.upperBound == $1.offset })
        #expect(ranges.last?.range.upperBound == Int64(made.video.size))
        #expect(media.segments.allSatisfy { abs($0.duration - 2) < 0.05 }, "\(media.segments.map(\.duration))")
    }

    @Test("A WebM file plays by its cues: a seek asks for the cluster it lands in, the file is not read up to it")
    func seeks() async throws {
        guard let made = Self.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let server = try TestHTTPServer(root: made.directory)
        defer { server.stop() }
        let manifest = Self.manifest(made)
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        let url = try #require(URL(string: server.url("dash.mpd")))

        let media = try #require(try await DASHManifestResolver().resolve(url, headers: [:]))
        #expect(URL(string: media.path)?.path == url.path, "The manifest is the client's, not a file played as it is")
        let demuxer = try #require(MediaDemuxer(url: media.path, headers: media.headers))
        #expect(demuxer.input is StreamingInput)
        #expect(abs(demuxer.durationSeconds - 20) < 0.1)

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

        let video = server.requests.filter { $0.path == "v.webm" }.compactMap(\.range)
        let starts = video.compactMap { $0.dropFirst("bytes=".count).split(separator: "-").first.flatMap { Int($0) } }
        #expect(starts.contains { $0 > made.video.size / 2 }, "Asked for \(video)")
        #expect(!video.contains("bytes=\(made.video.firstCluster)-"), "Read from the first cluster on: \(video)")
    }
}
