import CFFmpeg
import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// A DASH ladder (the `dashLadder` preset: three rungs with B-frames, a keyframe at each second) played from
/// `TestHTTPServer` as the resolver's manifest of it: FFmpeg's DASH demuxer lists the rungs as variants, and the
/// demuxer switches between them without losing or repeating a picture. Need FFmpeg built with libxml2, else they do
/// nothing.
@Suite("DASH ladder", .serialized, .hostDependent, .networkServer)
struct DASHLadderTests {
    private static var count: Int { SyntheticTestMediaFactory.dashLadderSegmentCount }
    private static var pictures: Int { 25 * count }

    /// A server of the preset's segments; nil when FFmpeg can't make them or can't read DASH.
    static func server() throws -> TestHTTPServer? {
        guard av_find_input_format("dash") != nil,
            let first = SyntheticTestMediaFactory.ensureMedia(preset: .dashLadder)
        else { return nil }
        let root = URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent()
        return try TestHTTPServer(root: root)
    }

    /// The manifest the resolver builds for the ladder.
    static func manifest(for server: TestHTTPServer, rungs only: [Int]? = nil) -> String {
        var streams = SyntheticTestMediaFactory.dashLadderRungs.enumerated().filter {
            only?.contains($0.offset) ?? true
        }.map {
            index, rung in
            SegmentedDASHManifest.Stream(
                kind: .video, id: "v\(index)", container: "mp4", codecs: "avc1.64001e", bandwidth: rung.bitrate,
                width: rung.width, height: rung.height, url: server.url("video\(index)"))
        }
        streams.append(.init(kind: .audio, id: "a", container: "mp4", url: server.url("audio")))
        return MediaURL.inlineDASHManifest(
            SegmentedDASHManifest(streams: streams, segmentDuration: 1, segmentCount: count).text())
    }

    /// Reads the demuxer's pictures to its end, in decode order, as their presentation times (seconds).
    private static func presentationTimes(of demuxer: MediaDemuxer, upTo limit: Int = .max) -> [Double] {
        var times: [Double] = []
        while times.count < limit, let sample = demuxer.nextVideoSample() {
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        return times
    }

    /// Every switch cuts the pictures at its keyframe (a second a group of 25): the pictures come as the old rung's plain
    /// run has them up to it, and as the new one's from it on, in the order they decode (the rungs are encoded alike but
    /// not identically: B-frames fall in other places). Not a picture handed on before one that decodes earlier.
    private static func expectOrderOfSwitches(
        _ times: [Double], from first: Int, switches: [(rung: Int, seconds: Double)], server: TestHTTPServer,
        _ comment: Comment
    ) throws {
        var expected: [Double] = []
        var rung = first
        var position = 0
        for next in switches + [(rung: first, seconds: Double(count))] {
            let plain = try #require(MediaDemuxer(url: manifest(for: server, rungs: [rung])))
            let reference = presentationTimes(of: plain)
            let boundary = next.seconds == Double(count) ? reference.count : Int(next.seconds.rounded()) * 25
            expected += reference[min(position, reference.count)..<min(boundary, reference.count)]
            position = boundary
            rung = next.rung
        }
        #expect(times == expected, "\(comment): not the order the pictures decode in; \(switches)")
    }

    /// Every picture once, at the frame rate: no gap and no repeat, whatever the order they are handed on in.
    private static func expectEveryPictureOnce(_ times: [Double], count expected: Int, _ comment: Comment) {
        let sorted = times.sorted()
        let steps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
        #expect(times.count == expected, "\(comment): \(times.count) pictures of \(expected)")
        let irregular = steps.enumerated().filter { abs($0.element - 0.04) > 0.002 }
        #expect(
            irregular.isEmpty,
            "\(comment): irregular steps \(irregular.prefix(5).map { "\($0.offset): \($0.element)" })")
    }

    @Test("A seek before the first read leaves the rungs not played alone: they are not moved to where it lands")
    func firstSeekClosesTheOthers() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: Self.manifest(for: server)))
        demuxer.startReadAhead(limits: .init(seconds: 30), held: true)
        let before = server.requests.count
        demuxer.prepareFirstSeek()
        demuxer.seek(to: 8.5, exact: true)
        let sample = try #require(demuxer.nextVideoSample())
        #expect(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) >= 8)
        // Rung 2 plays (the best); a segment of rung 0 or 1 past the first is a seek that moved them as well.
        let moved = server.requests.dropFirst(before).map(\.path).filter { path in
            ["video0/", "video1/"].contains { path.hasPrefix($0) }
                && Int(path.split(separator: "/").last ?? "") ?? 0 >= 5
        }
        #expect(moved.isEmpty, "Segments of the rungs not played: \(moved)")
    }

    @Test("The rungs of a ladder are the variants of the demuxer, the best selected")
    func listsTheRungs() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: Self.manifest(for: server)))
        let rungs = SyntheticTestMediaFactory.dashLadderRungs
        #expect(demuxer.variants.map(\.bandwidth) == rungs.reversed().map(\.bitrate), "\(demuxer.variants)")
        #expect(demuxer.variants.map(\.height) == [270, 180, 90])
        #expect(demuxer.variants.allSatisfy { $0.isSwitchable }, "\(demuxer.variants)")
        #expect(demuxer.selectedVariantId == demuxer.variants.first?.id)
        #expect(demuxer.hasAudio && demuxer.audioTracks.count == 1, "The sound is the manifest's, the same for all")
    }

    @Test("A switch in the middle of the stream, down and up, loses no picture and repeats none")
    func switchesWithoutLosingPictures() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: Self.manifest(for: server)))
        demuxer.setAdaptiveBitrate(false)
        // The read-ahead waits for the reader, a second and a half behind it at most: it cannot run to the end of the
        // stream before the switches are asked for, however the threads are scheduled.
        demuxer.startReadAhead(limits: .init(seconds: 1.5))
        let lowest = try #require(demuxer.variants.last)
        let highest = try #require(demuxer.variants.first)
        let switches = OSAllocatedUnfairLock<[(rung: Int, seconds: Double)]>(initialState: [])
        demuxer.onVariantChanged = { change in switches.withLock { $0.append((change.variant.id, change.seconds)) } }

        var times = Self.presentationTimes(of: demuxer, upTo: 50)
        demuxer.selectVariant(id: lowest.id)
        times += Self.presentationTimes(of: demuxer, upTo: 100)
        demuxer.selectVariant(id: highest.id)
        times += Self.presentationTimes(of: demuxer, upTo: 80)
        demuxer.selectVariant(id: lowest.id)
        times += Self.presentationTimes(of: demuxer)

        Self.expectEveryPictureOnce(times, count: Self.pictures, "down, up and down again")
        #expect(demuxer.selectedVariantId == lowest.id)
        #expect(switches.withLock { $0.count } == 3, "Three switches were made")
        try Self.expectOrderOfSwitches(
            times, from: highest.id, switches: switches.withLock { $0 }, server: server, "read ahead")
    }

    @Test(
        "Captions in the pictures are read across a switch: the keyframe it splices at, and what was held for it, too")
    func keepsCaptionsAcrossASwitch() throws {
        guard av_find_input_format("dash") != nil,
            let first = SyntheticTestMediaFactory.ensureMedia(preset: .dashLadderCaptions)
        else { return }
        let server = try TestHTTPServer(
            root: URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent())
        defer { server.stop() }
        let streams = [(100_000, 160, 90), (300_000, 320, 180)].enumerated().map { index, rung in
            SegmentedDASHManifest.Stream(
                kind: .video, id: "v\(index)", container: "mp4", bandwidth: rung.0, width: rung.1, height: rung.2,
                url: server.url("video\(index)"))
        }
        let manifest = MediaURL.inlineDASHManifest(
            SegmentedDASHManifest(streams: streams, segmentDuration: 1, segmentCount: 6).text())
        let demuxer = try #require(MediaDemuxer(url: manifest))
        let track = try #require(demuxer.subtitleTracks.first, "The captions of the pictures are a track")
        demuxer.selectSubtitleTrack(trackId: track.id)
        demuxer.setAdaptiveBitrate(false)
        // Read just ahead of the pictures taken, so that the switch is asked for before the first second ends: it
        // splices at the keyframe of the second, where the end of the first caption is.
        demuxer.startReadAhead(limits: .init(seconds: 0.3))
        let lowest = try #require(demuxer.variants.last)
        let splice = OSAllocatedUnfairLock<Double?>(initialState: nil)
        demuxer.onVariantChanged = { change in splice.withLock { $0 = change.seconds } }
        _ = Self.presentationTimes(of: demuxer, upTo: 10)
        demuxer.selectVariant(id: lowest.id)
        let times = Self.presentationTimes(of: demuxer)
        // The last segment of the preset holds two seconds (see `dashLadderCaptions`): 7 s of pictures in all.
        #expect(times.count == 7 * 30 - 10, "\(times.count) pictures")
        // At the keyframe of the first second, where the end of the first caption is.
        #expect(
            abs((splice.withLock { $0 } ?? -1) - 1.0) < 0.05, "Spliced at \(String(describing: splice.withLock { $0 }))"
        )
        #expect(demuxer.selectedVariantId == lowest.id, "The switch was made")

        let cues = demuxer.getLiveSubtitleDocument().cues.sorted { $0.startTime < $1.startTime }
        let script = SyntheticTestMediaFactory.dashCaptionScript
        #expect(cues.map(\.text) == script.map(\.text), "Cues: \(cues.map { ($0.startTime, $0.endTime, $0.text) })")
        for (cue, caption) in zip(cues, script) {
            #expect(abs(cue.startTime - caption.shown) < 0.05, "\(cue.text) from \(cue.startTime)")
            #expect(abs(cue.endTime - caption.cleared) < 0.05, "\(cue.text) to \(cue.endTime)")
        }
    }

    @Test("DASH manifests opened and read on several threads at once don't crash libxml2")
    func opensOnSeveralThreads() async throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let manifest = Self.manifest(for: server)
        let text = String(
            decoding: Data(base64Encoded: String(manifest.dropFirst("data:application/dash+xml;base64,".count)))!,
            as: UTF8.self)
        // Stock FFmpeg frees libxml2's global state after each manifest it reads, which crashed a parse going on in
        // another thread: the bundled one is patched not to (scripts/patches).
        let opened = await withTaskGroup(of: Int.self) { group in
            for index in 0..<8 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        return MediaDemuxer(url: manifest) == nil ? 0 : 1
                    }
                    return (0..<20).reduce(0) { count, _ in
                        count + (XMLTreeElement.parse(Data(text.utf8), limit: 1 << 20) == nil ? 0 : 1)
                    }
                }
            }
            return await group.reduce(0, +)
        }
        #expect(opened == 4 + 4 * 20)
    }

    @Test("Read on demand, with no read-ahead, a switch loses no picture, repeats none and keeps their order")
    func switchesReadingOnDemand() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: Self.manifest(for: server)))
        demuxer.setAdaptiveBitrate(false)
        let lowest = try #require(demuxer.variants.last)
        let highest = try #require(demuxer.variants.first)
        let switches = OSAllocatedUnfairLock<[(rung: Int, seconds: Double)]>(initialState: [])
        demuxer.onVariantChanged = { change in switches.withLock { $0.append((change.variant.id, change.seconds)) } }
        var times = Self.presentationTimes(of: demuxer, upTo: 40)
        demuxer.selectVariant(id: lowest.id)
        times += Self.presentationTimes(of: demuxer, upTo: 100)
        #expect(demuxer.selectedVariantId == lowest.id, "Down")
        demuxer.selectVariant(id: highest.id)
        times += Self.presentationTimes(of: demuxer)
        #expect(demuxer.selectedVariantId == highest.id, "Up")
        Self.expectEveryPictureOnce(times, count: Self.pictures, "on demand, down and up")
        try Self.expectOrderOfSwitches(
            times, from: highest.id, switches: switches.withLock { $0 }, server: server, "on demand")
    }

    @Test("A seek during a switch, and one after the end, play from the variant that plays")
    func seeksAroundASwitch() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: Self.manifest(for: server)))
        demuxer.setAdaptiveBitrate(false)
        // The read-ahead waits for the reader (see `switchesWithoutLosingPictures`).
        demuxer.startReadAhead(limits: .init(seconds: 1.5))
        let lowest = try #require(demuxer.variants.last)

        _ = Self.presentationTimes(of: demuxer, upTo: 40)
        demuxer.selectVariant(id: lowest.id)
        // The switch is asked for and has not reached its keyframe: the seek completes it at the target.
        demuxer.seek(to: 5.0, exact: false)
        var times = Self.presentationTimes(of: demuxer)
        Self.expectEveryPictureOnce(times, count: 25 * (Self.count - 5), "from the keyframe at 5 s")
        #expect(demuxer.selectedVariantId == lowest.id)

        // After the end: the streams read to it are enabled again.
        demuxer.seek(to: 2.0, exact: false)
        times = Self.presentationTimes(of: demuxer)
        Self.expectEveryPictureOnce(times, count: 25 * (Self.count - 2), "after the end, from 2 s")
    }
}

/// Adaptive bitrate on a DASH ladder against `TestHTTPServer` throttled, as HLS's (`AdaptiveBitrateTests`): the demuxer
/// reads ahead and a stand-in for playback takes pictures in real time.
@Suite("DASH adaptive bitrate", .serialized, .realtimePlayback, .backstopTimeLimit)
struct DASHAdaptiveBitrateTests {
    @Test("A slow network brings the picture down to the rung it carries, and not below it, without stalling")
    func followsTheNetwork() async throws {
        guard let server = try DASHLadderTests.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: DASHLadderTests.manifest(for: server)))
        #expect(demuxer.variants.map(\.width) == [480, 320, 160])
        #expect(demuxer.isAdaptiveBitrateEnabled)
        demuxer.adaptiveBitrateConfig = AdaptiveBitrateTests.config(readAhead: 3)

        // Opening reads the start of every rung (FFmpeg's DASH demuxer opens them all), unthrottled here: those
        // transfers say nothing of the network playback meets.
        _ = demuxer.network?.transferMeter?.take()
        // 0.5 Mbit/s carries the 0.35 Mbit/s rung (80 % of it is 0.4), not the 0.8 one it starts on.
        server.setLinkRate(500_000 / 8)
        demuxer.startReadAhead(limits: .init(seconds: 3))
        let consumer = AdaptiveBitrateTests.RealtimeConsumer(demuxer, startAhead: 2.5)
        defer { consumer.stop() }

        #expect(
            await AdaptiveBitrateTests.waitUntil(timeout: .seconds(20)) { consumer.playedWidth == 320 },
            "Playing \(String(describing: consumer.playedWidth)); the variant is \(String(describing: demuxer.selectedVariantId))"
        )
        #expect(consumer.stalled < 1.5, "Stalled \(consumer.stalled) s")
        #expect(!consumer.pictures.contains { $0.width == 160 }, "Went below the rung the network carries")
        #expect(demuxer.isAdaptiveBitrateEnabled, "The network chose, not the viewer")
    }
}
