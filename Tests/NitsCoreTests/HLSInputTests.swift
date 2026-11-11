import CFFmpeg
import Foundation
import Testing
import os

@testable import NitsCore

@Suite("HLS input", .serialized, .networkServer, .backstopTimeLimit)
struct HLSInputTests {
    // MARK: Helpers

    private struct Stand {
        let server: TestHTTPServer
        let directory: URL
    }

    private static func stand(_ preset: SyntheticTestMediaFactory.Preset) throws -> Stand? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return nil }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        return Stand(server: try TestHTTPServer(root: directory), directory: directory)
    }

    /// Opens the stream and reads what `MediaDemuxer` would: the top variant, its renditions, no subtitles (the demuxer
    /// disables the rest, `applyStreamSelection`).
    private static func open(
        _ stand: Stand, _ name: String, interrupt: FFmpegInterrupt = FFmpegInterrupt()
    ) -> HLSInput? {
        guard let input = HLSInput(url: stand.server.url(name), headers: [:], interrupt: interrupt) else { return nil }
        if let top = input.variantCandidates()?.max(by: { $0.bandwidth < $1.bandwidth }) {
            let kept = Set(top.streams.all).subtracting(top.streams.subtitles)
            for index in 0..<input.streamCount where !kept.contains(index) { input.setReading(false, stream: index) }
        }
        return input
    }

    private struct Packet {
        let stream: Int
        let isVideo: Bool
        let pts: Double
        let dts: Double
        let isKey: Bool
    }

    /// Reads up to `limit` packets (all, by default), and the code that ended the read.
    private static func drain(_ input: HLSInput, limit: Int = .max) -> (packets: [Packet], code: Int32) {
        let pointer = av_packet_alloc()!
        defer {
            var optional: UnsafeMutablePointer<AVPacket>? = pointer
            av_packet_free(&optional)
        }
        var packets: [Packet] = []
        while packets.count < limit {
            let code = input.read(&pointer.pointee)
            if code < 0 { return (packets, code) }
            let index = Int(pointer.pointee.stream_index)
            let stream = input.stream(index)!
            let base = Double(stream.pointee.time_base.num) / Double(stream.pointee.time_base.den)
            packets.append(
                Packet(
                    stream: index, isVideo: stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                    pts: Double(pointer.pointee.pts) * base, dts: Double(pointer.pointee.dts) * base,
                    isKey: pointer.pointee.flags & AV_PKT_FLAG_KEY != 0))
            av_packet_unref(pointer)
        }
        return (packets, 0)
    }

    private static func codecTypes(_ input: HLSInput) -> [AVMediaType] {
        (0..<input.streamCount).map { input.stream($0)!.pointee.codecpar.pointee.codec_type }
    }

    // MARK: Reading

    @Test("A variant with its sound muxed in is read to its end on a timeline from zero")
    func readsMuxedVariant() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        #expect(Self.codecTypes(input).contains(AVMEDIA_TYPE_VIDEO))
        #expect(Self.codecTypes(input).contains(AVMEDIA_TYPE_AUDIO))
        #expect(!input.isLivePlaylist)
        #expect(abs(input.durationSeconds - 6) < 0.5)

        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let video = packets.filter(\.isVideo)
        #expect(video.count > 100)
        #expect(abs((video.first?.pts ?? 99) - 0) < 0.5)
        #expect(abs((video.last?.pts ?? 0) - 6) < 0.6)
        // Decode time never goes back by more than a frame's reordering within a stream.
        for isVideo in [true, false] {
            let times = packets.filter { $0.isVideo == isVideo }.map(\.dts)
            #expect(zip(times, times.dropFirst()).allSatisfy { $1 >= $0 - 0.001 })
        }
    }

    @Test("An audio rendition with a playlist of its own is read beside the picture, interleaved by decode time")
    func readsAudioRendition() throws {
        guard let stand = try Self.stand(.hlsDiscontinuityFMP4AudioRendition) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        #expect(Self.codecTypes(input).filter { $0 == AVMEDIA_TYPE_AUDIO }.count == 1)
        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let video = packets.filter(\.isVideo)
        let audio = packets.filter { !$0.isVideo }
        #expect(!video.isEmpty && !audio.isEmpty)
        // Both renditions reach the end, and neither runs more than a segment ahead of the other while reading.
        #expect(abs((video.last?.dts ?? 0) - (audio.last?.dts ?? 99)) < 2)
        var lead = 0.0
        var latest = [true: 0.0, false: 0.0]
        for packet in packets {
            latest[packet.isVideo] = packet.dts
            lead = max(lead, abs(latest[true]! - latest[false]!))
        }
        #expect(lead < 5)
    }

    @Test("A stream without a stream read is not downloaded: a lane nothing reads is left alone")
    func unreadRenditionIsNotDownloaded() throws {
        guard let stand = try Self.stand(.hlsDiscontinuityFMP4AudioRendition) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let audio = try #require((0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_AUDIO })
        input.setReading(false, stream: audio)
        let before = stand.server.requests.count
        let (packets, _) = Self.drain(input)
        #expect(packets.allSatisfy { $0.isVideo })
        let paths = stand.server.requests.dropFirst(before).map(\.path)
        // Its media playlist and init section came with the opening; none of its segments after.
        #expect(!paths.contains { $0.contains("aseg") })
    }

    @Test("Each segment is requested once and decode time never goes back")
    func readsEachSegmentOnce() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        for isVideo in [true, false] {
            let times = packets.filter { $0.isVideo == isVideo }.map(\.dts)
            #expect(zip(times, times.dropFirst()).allSatisfy { $1 >= $0 })
        }
        // The first segment of each variant is probed at the opening (its start only); every other is requested once.
        let segments = stand.server.requests.map(\.path).filter { $0.hasSuffix(".ts") && !$0.hasSuffix("_000.ts") }
        #expect(segments.count == Set(segments).count)
        #expect(abs((packets.filter(\.isVideo).last?.pts ?? 0) - 40) < 1)
    }

    @Test("Segments shorter than the probing (half a second) are each read once, in one run")
    func readsShortSegmentsOnce() throws {
        // Probing the first run reads on into the next segments, asking the lane for them before the run has begun.
        guard let stand = try Self.stand(.hlsShortFragments) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "media.m3u8"))
        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let times = packets.filter(\.isVideo).map(\.dts)
        #expect(times.count == 30, "\(times.count) pictures of 3 s at 10 fps")
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
        let segments = stand.server.requests.map(\.path).filter { $0.hasSuffix(".m4s") }
        #expect(segments.count == 6, "\(segments)")
        #expect(Set(segments).count == 6)
    }

    @Test("A segment that fails is skipped, not asked for again; the stream goes on")
    func skipsASegmentThatKeepsFailing() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        var behavior = TestHTTPServer.Behavior()
        behavior.failure = .status(404)
        stand.server.setBehavior(behavior, forPaths: { $0.hasSuffix("_001.ts") })
        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let attempts = stand.server.requests.filter { $0.path.hasSuffix("_001.ts") }.count
        #expect(attempts == 1)
        let video = packets.filter(\.isVideo)
        #expect(video.contains { $0.pts < 2 } && video.contains { $0.pts > 4 })
        #expect(!video.contains { $0.pts > 2.2 && $0.pts < 3.8 })
    }

    // MARK: Variants

    @Test("Every variant is a candidate, probed by the start of its first segment, and only those read download more")
    func variantsAreProbedNotDownloaded() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let candidates = try #require(input.variantCandidates())
        #expect(candidates.count == 3)
        #expect(candidates.allSatisfy { $0.streams.video != nil })
        // Each has a picture of its own, described from the probe.
        let widths = candidates.sorted { $0.bandwidth > $1.bandwidth }.compactMap { candidate in
            candidate.streams.video.flatMap { input.stream($0)?.pointee.codecpar.pointee.width }
        }
        #expect(widths == [640, 480, 320])
        let (_, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let paths = stand.server.requests.map(\.path)
        // The variants not read were asked for the first segment only (probed), none of the rest.
        let lowest = try #require(candidates.min { $0.bandwidth < $1.bandwidth })
        #expect(lowest.streams.video != nil)
        #expect(paths.filter { $0.hasPrefix("v0_") && $0.hasSuffix(".ts") }.count == 1, "\(paths)")
        #expect(paths.filter { $0.hasPrefix("v1_") && $0.hasSuffix(".ts") }.count == 1, "\(paths)")
        // The first segment of the one read: the probe's piece (held to the opening's buffer, in ranges), and the play's,
        // once, whole.
        let playing = stand.server.requests.filter { $0.path == "v2_000.ts" && $0.range == nil }
        #expect(playing.count == 1, "\(stand.server.requests.filter { $0.path == "v2_000.ts" }.map(\.range))")
    }

    @Test("Variants that can't switch with the best, and renditions only they refer to, are neither loaded nor probed")
    func ladderOnly() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        // A HEVC variant and a variant with an audio group of its own, both below the AVC variants.
        let master = try String(contentsOf: stand.directory.appendingPathComponent("master.m3u8"), encoding: .utf8)
        stand.server.setResponder(forPath: "master.m3u8") {
            Data(
                (master + """
                    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="other",NAME="Other",URI="other_audio.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=200000,CODECS="hvc1.1.6.L93.B0,mp4a.40.2"
                    hevc.m3u8
                    #EXT-X-STREAM-INF:BANDWIDTH=300000,CODECS="avc1.64000d,mp4a.40.2",AUDIO="other"
                    v0.m3u8

                    """).utf8)
        }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let candidates = try #require(input.variantCandidates())
        #expect(candidates.map(\.bandwidth).sorted() == [393_296, 988_128])
        let paths = stand.server.requests.map(\.path)
        #expect(!paths.contains("hevc.m3u8") && !paths.contains("other_audio.m3u8"), "\(paths)")
        #expect(Self.drain(input, limit: 30).packets.contains { $0.isVideo })
    }

    @Test(
        "The demuxer's rewind to the start, after its first read, replays the first segment, which isn't asked for again"
    )
    func rewindReplaysTheFirstSegment() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let (before, _) = Self.drain(input, limit: 20)
        input.rewind()
        let (after, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        #expect(before.first?.dts == after.first?.dts, "the same packets again")
        let whole = stand.server.requests.filter { $0.path == "v2_000.ts" && $0.range == nil }
        #expect(whole.count == 1, "\(stand.server.requests.map(\.path))")
    }

    @Test("A variant read for a switch joins at a segment after the picture's, at a keyframe")
    func switchedVariantJoinsAtTheNextSegment() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let candidates = try #require(input.variantCandidates())
        let low = try #require(candidates.min { $0.bandwidth < $1.bandwidth })
        let lowVideo = try #require(low.streams.video)
        let (before, _) = Self.drain(input, limit: 60)
        let reached = try #require(before.filter(\.isVideo).last).dts
        for index in low.streams.all { input.setReading(true, stream: index) }
        let (after, _) = Self.drain(input, limit: 400)
        let joined = try #require(after.first { $0.stream == lowVideo })
        #expect(joined.isKey)
        #expect(joined.dts >= reached, "joined at \(joined.dts), the picture was at \(reached)")
        #expect(joined.dts - reached < 2.1)
        // The segment the picture was in, of the lowest variant, was not downloaded to be dropped.
        let paths = stand.server.requests.map(\.path).filter { $0.hasPrefix("v0_") }
        #expect(paths.filter { $0 == "v0_000.ts" }.count == 1, "\(paths)")
    }

    @Test("A subtitle rendition's cues are on the picture's timeline, whichever variant is read")
    func subtitleCuesFollowThePicture() throws {
        guard let stand = try Self.stand(.hlsRenditions) else { return }
        defer { stand.server.stop() }
        // The cue files carry no `X-TIMESTAMP-MAP`: the media's start (an MPEG-TS starts at 1.4667 s) is given.
        for name in ["v00", "v01", "v02", "v10", "v11", "v12"] {
            let text = try String(contentsOf: stand.directory.appendingPathComponent("\(name).vtt"), encoding: .utf8)
            stand.server.setResponder(forPath: "\(name).vtt") {
                Data(
                    text.replacingOccurrences(
                        of: "WEBVTT\n", with: "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:132000,LOCAL:00:00.000\n"
                    ).utf8)
            }
        }
        let input = try #require(
            HLSInput(url: stand.server.url("master.m3u8"), headers: [:], interrupt: FFmpegInterrupt()))
        let candidates = try #require(input.variantCandidates())
        // The master lists the lower variant first: its subtitle lane comes before the top variant's in the master.
        let top = try #require(candidates.max { $0.bandwidth < $1.bandwidth })
        let subtitle = try #require(top.streams.subtitles.first)
        let kept = Set(top.streams.all).subtracting(top.streams.subtitles).union([subtitle])
        for index in 0..<input.streamCount where !kept.contains(index) { input.setReading(false, stream: index) }
        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let cues = packets.filter { $0.stream == subtitle }
        #expect(!cues.isEmpty)
        // "Hello" is at 0.5 s and "World" at 3 s of the media, which an MPEG-TS starts a second and more in.
        #expect(cues.contains { abs($0.pts - 0.5) < 0.15 }, "\(cues.map(\.pts))")
        #expect(cues.contains { abs($0.pts - 3.0) < 0.15 }, "\(cues.map(\.pts))")
    }

    // MARK: Seeking

    @Test("A seek starts at the segment that holds the target; a forward seek past the end fails")
    func seeks() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let videoIndex = try #require(
            (0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_VIDEO })
        let base = input.stream(videoIndex)!.pointee.time_base
        let ticks = { (seconds: Double) in Int64(seconds * Double(base.den) / Double(base.num)) }
        let streams = (video: videoIndex, audio: -1)

        #expect(input.seek(to: ticks(3.1), flags: AVSEEK_FLAG_BACKWARD, streams: streams) >= 0)
        let (packets, _) = Self.drain(input, limit: 20)
        let first = try #require(packets.first { $0.isVideo })
        // The segment of 2…4 s, from its keyframe.
        #expect(first.pts >= 1.9 && first.pts <= 3.1)
        #expect(first.isKey)

        #expect(input.seek(to: ticks(60), flags: 0, streams: streams) < 0)
        // And back to the start, to be read whole again.
        input.rewind()
        let (again, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        #expect(again.filter(\.isVideo).count > 100)
    }

    @Test("A forward seek lands on the first keyframe at or after the target, nothing before it handed out")
    func forwardSeekLandsAfterTheTarget() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let videoIndex = try #require(
            (0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_VIDEO })
        let base = input.stream(videoIndex)!.pointee.time_base
        let target = Int64(1.0 * Double(base.den) / Double(base.num))
        #expect(input.seek(to: target, flags: 0, streams: (video: videoIndex, audio: -1)) >= 0)
        let (packets, _) = Self.drain(input, limit: 20)
        // The segment that holds 1 s starts at 0 with a keyframe: not that one.
        let first = try #require(packets.first)
        #expect(first.isVideo && first.isKey)
        #expect(first.pts >= 0.99, "landed at \(first.pts) s")
    }

    @Test("A seek of the picture alone moves an audio rendition too")
    func streamSeekMovesEveryLane() throws {
        guard let stand = try Self.stand(.hlsDiscontinuityFMP4AudioRendition) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let videoIndex = try #require(
            (0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_VIDEO })
        // Read on past 5 s, both renditions.
        while let packet = Self.drain(input, limit: 1).packets.first, !(packet.isVideo && packet.dts > 5) {}
        let base = input.stream(videoIndex)!.pointee.time_base
        let target = Int64(1.0 * Double(base.den) / Double(base.num))
        #expect(input.seek(stream: videoIndex, to: target, flags: AVSEEK_FLAG_BACKWARD) >= 0)
        let (packets, _) = Self.drain(input, limit: 60)
        let audio = try #require(packets.first { !$0.isVideo })
        #expect(audio.dts < 4, "audio went on at \(audio.dts) s")
    }

    // MARK: Live

    /// A live playlist over the first segments of `hlsVariants`' lowest variant: `listed(reload)` says how many are
    /// listed after the `reload`-th request of it, and whether it has ended.
    private static func liveStand(
        _ stand: Stand, listed: @escaping @Sendable (Int) -> (count: Int, ended: Bool)
    ) -> OSAllocatedUnfairLock<Int> {
        let requests = OSAllocatedUnfairLock(initialState: 0)
        stand.server.setResponder(forPath: "live.m3u8") {
            let reload = requests.withLock { value in
                defer { value += 1 }
                return value
            }
            let (count, ended) = listed(reload)
            var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:0"]
            for index in 0..<count { lines += ["#EXTINF:2.000000,", String(format: "v0_%03d.ts", index)] }
            if ended { lines.append("#EXT-X-ENDLIST") }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        return requests
    }

    @Test("A live playlist is waited on at its edge and reloaded until it lists the next segment and ends")
    func readsLivePlaylistToItsEnd() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        // 2 segments at the opening, a third from the second reload, the end with the fourth.
        let requests = Self.liveStand(stand) { reload in
            reload < 2 ? (2, false) : (3, true)
        }
        let input = try #require(Self.open(stand, "live.m3u8"))
        #expect(input.isLivePlaylist)
        // Joined a few target durations behind the edge: from the start of this short playlist.
        let window = try #require(input.liveWindow())
        #expect(window.end - window.start == 4)
        #expect(!window.hasEnded)

        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let video = packets.filter(\.isVideo)
        #expect(abs((video.last?.pts ?? 0) - 6) < 0.6)
        #expect(requests.withLock { $0 } >= 3)
        let ended = try #require(input.liveWindow())
        #expect(ended.hasEnded)
        #expect(ended.end - ended.start == 6)
    }

    @Test("A read that waits at the live edge gives way to an abort at once")
    func abortsAtTheEdge() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        _ = Self.liveStand(stand) { _ in (2, false) }
        let interrupt = FFmpegInterrupt()
        let input = try #require(Self.open(stand, "live.m3u8", interrupt: interrupt))
        let result = OSAllocatedUnfairLock<(packets: [Packet], code: Int32)?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let drained = Self.drain(input)
            result.withLock { $0 = drained }
            done.signal()
        }
        // Let it read the segments and wait for a third.
        Thread.sleep(forTimeInterval: 1.5)
        let began = ContinuousClock.now
        interrupt.cancel()
        #expect(done.wait(timeout: .now() + 5) == .success)
        let (packets, code) = try #require(result.withLock { $0 })
        #expect(code == HTTPSessionInput.averrorExit)
        #expect(!packets.isEmpty)
        #expect(ContinuousClock.now - began < .seconds(2))
    }

    @Test("A live stream rewinds to the start of its window")
    func liveRewindGoesToTheWindowStart() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        // Five segments of 2 s (the three again after a break): the timeline starts at the window's first segment.
        stand.server.setResponder(forPath: "window.m3u8") {
            var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:0"]
            for (index, name) in ["v0_000", "v0_001", "v0_002", "v0_000", "v0_001"].enumerated() {
                if index == 3 { lines.append("#EXT-X-DISCONTINUITY") }
                lines += ["#EXTINF:2.000000,", name + ".ts"]
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        let input = try #require(Self.open(stand, "window.m3u8"))
        #expect(input.timelineOrigin == 0)
        _ = Self.drain(input, limit: 30)
        input.rewind()
        let (packets, _) = Self.drain(input, limit: 30)
        let first = try #require(packets.first { $0.isVideo })
        #expect(abs(first.pts) < 0.2, "rewound to \(first.pts) s")
    }

    @Test("A live playlist that stops changing without ending is taken as stuck after 3.5 target durations")
    func stuckPlaylistEndsTheRead() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let requests = Self.liveStand(stand) { _ in (2, false) }
        let began = ContinuousClock.now
        let input = try #require(Self.open(stand, "live.m3u8"))
        let (packets, code) = Self.drain(input)
        let waited = (ContinuousClock.now - began) / .seconds(1)
        #expect(code == -ETIMEDOUT)
        #expect(!packets.isEmpty)
        // A target duration of 2 s: stuck once 7 s passed without a change, reloaded in between.
        #expect(waited >= 7 && waited < 11, "\(waited) s")
        #expect(requests.withLock { $0 } >= 4)
    }

}
