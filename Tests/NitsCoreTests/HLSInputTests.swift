import CFFmpeg
import CoreMedia
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

    @Test("Only the top variant is probed; the others are described as it, by their RESOLUTION, and download nothing")
    func onlyTheTopIsProbed() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let candidates = try #require(input.variantCandidates()).sorted { $0.bandwidth > $1.bandwidth }
        #expect(candidates.count == 3)
        #expect(candidates.allSatisfy { $0.streams.video != nil && $0.streams.audio.count == 1 })
        let widths = candidates.compactMap { candidate in
            candidate.streams.video.flatMap { input.stream($0)?.pointee.codecpar.pointee.width }
        }
        #expect(widths == [640, 480, 320])
        #expect(candidates.map { input.variantDescription(id: $0.id) } == [.described, .pending, .pending])
        let (_, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let paths = stand.server.requests.map(\.path)
        // The rungs below were never asked for a segment.
        #expect(!paths.contains { ($0.hasPrefix("v0_") || $0.hasPrefix("v1_")) && $0.hasSuffix(".ts") }, "\(paths)")
        // The first segment of the one read: asked for once, whole, by the probe, whose download goes on as the play's.
        let first = stand.server.requests.filter { $0.path == "v2_000.ts" }
        #expect(first.count == 1 && first.first?.range == nil, "\(first.map(\.range))")
    }

    @Test("A top that doesn't answer in time has the next rung down probed beside it; the first to answer describes")
    func slowTopRacesTheNextRung() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        var slow = TestHTTPServer.Behavior()
        slow.delay = .seconds(3)
        stand.server.setBehavior(slow, forPaths: { $0 == "v2_000.ts" })
        let began = ContinuousClock.now
        let input = try #require(
            HLSInput(
                url: stand.server.url("master.m3u8"), headers: [:], interrupt: FFmpegInterrupt(),
                answerLimit: .milliseconds(300)))
        defer { input.close() }
        // The top's request was stopped once the rung below answered, not waited for.
        #expect(ContinuousClock.now - began < .seconds(2))
        let candidates = try #require(input.variantCandidates()).sorted { $0.bandwidth > $1.bandwidth }
        #expect(candidates.map { input.variantDescription(id: $0.id) } == [.pending, .described, .pending])
        let widths = candidates.compactMap { candidate in
            candidate.streams.video.flatMap { input.stream($0)?.pointee.codecpar.pointee.width }
        }
        #expect(widths == [640, 480, 320])
        let paths = stand.server.requests.map(\.path)
        #expect(paths.contains("v1_000.ts") && !paths.contains("v0_000.ts"), "\(paths)")
    }

    @Test("A top that fails on its own while the next rung is probed beside it is left out, not taken for a clone")
    func slowTopThatFailsIsLeftOut() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        var failing = TestHTTPServer.Behavior()
        failing.delay = .milliseconds(600)
        failing.failure = .status(404)
        stand.server.setBehavior(failing, forPaths: { $0 == "v2_000.ts" })
        // The rung below answers after the top has failed.
        var slow = TestHTTPServer.Behavior()
        slow.delay = .milliseconds(1500)
        stand.server.setBehavior(slow, forPaths: { $0 == "v1_000.ts" })
        let input = try #require(
            HLSInput(
                url: stand.server.url("master.m3u8"), headers: [:], interrupt: FFmpegInterrupt(),
                answerLimit: .milliseconds(300)))
        defer { input.close() }
        let candidates = try #require(input.variantCandidates()).sorted { $0.bandwidth > $1.bandwidth }
        #expect(candidates.count == 2)
        #expect(candidates.map { input.variantDescription(id: $0.id) } == [.described, .pending])
        #expect(
            candidates.first.flatMap { $0.streams.video }.flatMap { input.stream($0)?.pointee.codecpar.pointee.width }
                == 480)
    }

    @Test("A rung whose CODECS tell other sound muxed into it is probed itself, not described as the top")
    func otherSoundToldIsProbed() throws {
        guard let stand = try Self.stand(.hlsMixedSoundLadder) else { return }
        defer { stand.server.stop() }
        let master = try String(contentsOf: stand.directory.appendingPathComponent("master.m3u8"), encoding: .utf8)
        stand.server.setResponder(forPath: "master.m3u8") {
            Data(
                master.replacingOccurrences(
                    of: "RESOLUTION=320x180,CODECS=\"avc1.64001e,mp4a.40.2\"",
                    with: "RESOLUTION=320x180,CODECS=\"avc1.64001e\""
                ).utf8)
        }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let candidates = try #require(input.variantCandidates()).sorted { $0.bandwidth > $1.bandwidth }
        #expect(candidates.map { input.variantDescription(id: $0.id) } == [.described, .pending, .described])
        #expect(candidates.map(\.streams.audio.count) == [1, 1, 0])
        let paths = stand.server.requests.map(\.path)
        #expect(paths.contains("v0_000.ts") && !paths.contains("v1_000.ts"), "\(paths)")
    }

    @Test("Which ladders are described from one rung: one codec, range and groups, and the sound the top's")
    func cloneCandidates() throws {
        func candidates(_ lines: String) throws -> [Int] {
            let text = "#EXTM3U\n" + lines
            guard
                case .master(let master) = try HLSPlaylist.parse(Data(text.utf8), url: URL(string: "http://h/m.m3u8")!)
            else { return [] }
            let listed = HLSInput.ladder(of: master)
            let plan = listed.enumerated().map {
                (bandwidth: $1.bandwidth, video: $0, audio: [Int](), subtitles: [Int]())
            }
            let top = try #require(plan.max { $0.bandwidth < $1.bandwidth }).video
            return HLSInput.cloneCandidates(plan: plan, listed: listed, top: top) { _ in true }
        }
        let avc = { (bandwidth: Int, codecs: String) in
            "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"\(codecs)\"\nv\(bandwidth).m3u8\n"
        }
        // One codec: the top first, then down.
        #expect(
            try candidates(
                avc(1, "avc1.64001e,mp4a.40.2") + avc(3, "avc1.640028,mp4a.40.2") + avc(2, "avc1.64001f,mp4a.40.2"))
                == [1, 2, 0])
        // Codecs mixed: `ladder(of:)` keeps the top's, the others are no rungs.
        #expect(
            try candidates(
                avc(1, "avc1.64001e,mp4a.40.2") + avc(3, "hvc1.2.4.L120.B0,mp4a.40.2") + avc(2, "avc1.64001f,mp4a.40.2")
            )
                == [])
        // A rung that tells no codecs: every rung is kept, and probed.
        #expect(try candidates(avc(1, "avc1.64001e,mp4a.40.2") + "#EXT-X-STREAM-INF:BANDWIDTH=3\nv3.m3u8\n") == [])
        // Another sound muxed: probed apart.
        #expect(
            try candidates(avc(1, "avc1.64001e") + avc(3, "avc1.640028,mp4a.40.2") + avc(2, "avc1.64001f,mp4a.40.2"))
                == [1, 2])
        // Sound only besides pictures: no rung of the ladder.
        #expect(
            try candidates(
                avc(1, "mp4a.40.2") + avc(3, "avc1.640028,mp4a.40.2") + avc(2, "avc1.64001f,mp4a.40.2")) == [0, 1])
    }

    @Test(
        "A rung found at its first read to have other streams than described, or sound that doesn't switch, is left out"
    )
    func untoldOtherStreamsAreLeftOut() throws {
        guard let stand = try Self.stand(.hlsMixedSoundLadder) else { return }
        defer { stand.server.stop() }
        let demuxer = try #require(MediaDemuxer(url: stand.server.url("master.m3u8")))
        let byWidth = Dictionary(uniqueKeysWithValues: demuxer.variants.map { ($0.width, $0.id) })
        let top = try #require(byWidth[640])
        #expect(demuxer.selectedVariantId == top)
        let changes = OSAllocatedUnfairLock(initialState: [Int]())
        demuxer.onVariantChanged = { change in changes.withLock { $0.append(change.variant.id) } }
        var widths: [Int32] = []
        var times: [Double] = []
        while let sample = demuxer.nextVideoSample() {
            widths.append(
                CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?.width ?? 0)
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            // No sound at all, then sound at 44.1 kHz (the top's is at 48 kHz).
            if widths.count == 20, let id = byWidth[320] { demuxer.selectVariant(id: id) }
            if widths.count == 90, let id = byWidth[480] { demuxer.selectVariant(id: id) }
        }
        // A switch given up reports the variant that plays on.
        #expect(changes.withLock { $0 }.allSatisfy { $0 == top })
        #expect(demuxer.selectedVariantId == top)
        #expect(widths.count == 180 && widths.allSatisfy { $0 == 640 })
        #expect(Set(times.map { ($0 * 30).rounded() }).count == 180)
        let paths = stand.server.requests.map(\.path)
        #expect(paths.contains { $0.hasPrefix("v0_") } && paths.contains { $0.hasPrefix("v1_") }, "\(paths)")
        // Neither is asked for again.
        demuxer.selectVariant(id: byWidth[320] ?? 0)
        #expect(demuxer.variantSelection.withLock { $0.requested } == nil)
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

    @Test("A variant read for a switch joins at a segment after the picture's, at a keyframe, described by that read")
    func switchedVariantJoinsAtTheNextSegment() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let candidates = try #require(input.variantCandidates())
        let low = try #require(candidates.min { $0.bandwidth < $1.bandwidth })
        let lowVideo = try #require(low.streams.video)
        let (before, _) = Self.drain(input, limit: 60)
        let reached = try #require(before.filter(\.isVideo).last).dts
        #expect(input.variantDescription(id: low.id) == .pending)
        for index in low.streams.all { input.setReading(true, stream: index) }
        let (after, _) = Self.drain(input, limit: 400)
        let joined = try #require(after.first { $0.stream == lowVideo })
        #expect(joined.isKey)
        #expect(joined.dts >= reached, "joined at \(joined.dts), the picture was at \(reached)")
        #expect(joined.dts - reached < 2.1)
        // The segment the picture was in, of the lowest variant, was not downloaded to be dropped.
        let paths = stand.server.requests.map(\.path).filter { $0.hasPrefix("v0_") }
        #expect(!paths.contains("v0_000.ts"), "\(paths)")
        // Described as the top until then; its own read describes it.
        #expect(input.variantDescription(id: low.id) == .described)
        #expect(input.stream(lowVideo)?.pointee.codecpar.pointee.width == 320)
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

    @Test("A lane that takes over a segment given up starts at it, whichever stream is switched first")
    func joinsAtTheSegmentGivenUp() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        // Segments of 2 s: sequence 6 starts at 12 s. The picture is read to about 5 s, the lane given up is in segment 6.
        for oldFirst in [true, false] {
            let input = try #require(Self.open(stand, "master.m3u8"))
            let candidates = try #require(input.variantCandidates())
            let top = try #require(candidates.max { $0.bandwidth < $1.bandwidth })
            let low = try #require(candidates.min { $0.bandwidth < $1.bandwidth })
            while let packet = Self.drain(input, limit: 1).packets.first, !(packet.isVideo && packet.dts > 5) {}
            let old = Set(top.streams.all).subtracting(low.streams.all)
            let new = Set(low.streams.all)
            // As `applyStreamSelection` does, in an order that a `Set` leaves to chance.
            input.joinNext(atSequence: 6)
            if oldFirst {
                for index in old { input.setReading(false, stream: index) }
                for index in new { input.setReading(true, stream: index) }
            } else {
                for index in new { input.setReading(true, stream: index) }
                for index in old { input.setReading(false, stream: index) }
            }
            input.joinNext(atSequence: nil)
            let lowVideo = try #require(low.streams.video)
            var first: Packet?
            while first == nil, let packet = Self.drain(input, limit: 1).packets.first {
                if packet.stream == lowVideo { first = packet }
            }
            let start = try #require(first)
            #expect(
                start.pts >= 11.5, "Started at \(start.pts) s, not in segment 6 (12 s); old stream first: \(oldFirst)")
            input.close()
        }
    }

    @Test("A lane read again from a segment's start with a landing drops what comes before the keyframe it lands on")
    func restartsAtAKeyframeInsideTheSegment() throws {
        guard let stand = try Self.stand(.hlsLadder) else { return }
        defer { stand.server.stop() }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let candidates = try #require(input.variantCandidates())
        let top = try #require(candidates.max { $0.bandwidth < $1.bandwidth })
        while let packet = Self.drain(input, limit: 1).packets.first, !(packet.isVideo && packet.dts > 3) {}
        // Segments of 2 s, a keyframe each second: segment 3 is 6…8 s and has keyframes at 6 and 7. What is queued of it,
        // from 6 to 7 s, is not read again.
        input.restartDownload(ofVariant: top.id, atSequence: 3, landingSeconds: 7.0)
        let first = try #require(Self.drain(input, limit: 40).packets.first { $0.isVideo })
        #expect(abs(first.pts - 7.0) < 0.01 && first.isKey, "Landed at \(first.pts) s")
        // Without a landing it starts at the segment's start.
        let again = try #require(Self.open(stand, "master.m3u8"))
        while let packet = Self.drain(again, limit: 1).packets.first, !(packet.isVideo && packet.dts > 3) {}
        again.restartDownload(ofVariant: top.id, atSequence: 3, landingSeconds: nil)
        let start = try #require(Self.drain(again, limit: 40).packets.first { $0.isVideo })
        #expect(abs(start.pts - 6.0) < 0.01, "Started at \(start.pts) s")
    }

    @Test("A subtitle rendition without cues for a stretch is read no further ahead than the picture")
    func sparseSubtitlesDoNotHoldTheRead() throws {
        guard let stand = try Self.stand(.hlsRenditions) else { return }
        defer { stand.server.stop() }
        // No cues in the first two segments (0…4 s), one in the last.
        for name in ["v00", "v01", "v10", "v11"] {
            stand.server.setResponder(forPath: "\(name).vtt") { Data("WEBVTT\n".utf8) }
        }
        for name in ["v02", "v12"] {
            stand.server.setResponder(forPath: "\(name).vtt") {
                Data("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:132000,LOCAL:00:00.000\n\n00:04.500 --> 00:05.000\nlate\n".utf8)
            }
        }
        let input = try #require(
            HLSInput(url: stand.server.url("master.m3u8"), headers: [:], interrupt: FFmpegInterrupt()))
        let top = try #require(input.variantCandidates()?.max { $0.bandwidth < $1.bandwidth })
        let subtitle = try #require(top.streams.subtitles.first)
        let kept = Set(top.streams.all).subtracting(top.streams.subtitles).union([subtitle])
        for index in 0..<input.streamCount where !kept.contains(index) { input.setReading(false, stream: index) }
        let cueFiles = { stand.server.requests.map(\.path).filter { $0.hasSuffix(".vtt") } }

        // The first packet comes with the first cue file at most, not the ones that the picture has not reached.
        let (first, _) = Self.drain(input, limit: 1)
        #expect(first.count == 1)
        #expect(cueFiles().allSatisfy { $0.hasSuffix("0.vtt") }, "\(cueFiles())")
        // Read on to 3 s of the picture: the last segment (4…6 s) is not asked for yet.
        while let packet = Self.drain(input, limit: 1).packets.first, !(packet.isVideo && packet.dts > 3) {}
        #expect(!cueFiles().contains { $0.hasSuffix("2.vtt") }, "\(cueFiles())")

        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let cues = packets.filter { $0.stream == subtitle }
        #expect(cues.count == 1 && abs((cues.first?.pts ?? 0) - 4.5) < 0.15, "\(cues.map(\.pts))")
    }

    @Test("Cues after a break wait for the picture to anchor it, even when its old run goes past the break")
    func cuesAfterABreakWaitForTheAnchor() throws {
        guard let stand = try Self.stand(.hlsDiscontinuityFMP4AudioRendition) else { return }
        defer { stand.server.stop() }
        // The picture alone, with a subtitle rendition; its first stretch (4 s) listed as 3 s: the break is at 3 s on the
        // timeline, and the old run's packets go on to 4 s past it.
        stand.server.setResponder(forPath: "master.m3u8") {
            Data(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Text",LANGUAGE="uk",URI="s.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=320x180,CODECS="avc1.640015",SUBTITLES="subs"
                short.m3u8

                """.utf8)
        }
        let listed = try String(contentsOf: stand.directory.appendingPathComponent("v.m3u8"), encoding: .utf8)
        let short = listed.replacingOccurrences(of: "#EXTINF:4.0,\nvseg0_0", with: "#EXTINF:3.0,\nvseg0_0")
        #expect(short != listed)
        stand.server.setResponder(forPath: "short.m3u8") { Data(short.utf8) }
        stand.server.setResponder(forPath: "s.m3u8") {
            Data(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-PLAYLIST-TYPE:VOD
                #EXTINF:3.0,
                s0.vtt
                #EXT-X-DISCONTINUITY
                #EXTINF:4.0,
                s1.vtt
                #EXT-X-ENDLIST

                """.utf8)
        }
        stand.server.setResponder(forPath: "s0.vtt") { Data("WEBVTT\n".utf8) }
        // Half a second into the second stretch's media.
        stand.server.setResponder(forPath: "s1.vtt") {
            Data("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00.000\n\n00:00.500 --> 00:01.000\nafter\n".utf8)
        }
        let input = try #require(
            HLSInput(url: stand.server.url("master.m3u8"), headers: [:], interrupt: FFmpegInterrupt()))
        let subtitle = try #require(
            (0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_SUBTITLE })
        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        // The second stretch's first picture (at 0.066 s of its media) anchors it at the break, 3 s: the cue, at 0.5 s of
        // that media, is at 3.434 s. Placed by the first stretch's offset it would be at 0.434 s.
        let cues = packets.filter { $0.stream == subtitle }.map(\.pts)
        #expect(cues.count == 1)
        #expect(abs((cues.first ?? 0) - 3.434) < 0.01, "cue at \(cues)")
    }

    /// An ID3v2.4 tag with Apple's `PRIV` transport stream timestamp (`ticks` at 90 kHz), as packed audio starts with.
    private static func id3(transportStreamTimestamp ticks: Int64) -> Data {
        func syncsafe(_ value: Int) -> [UInt8] { (0..<4).reversed().map { UInt8((value >> (7 * $0)) & 0x7F) } }
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
        let body = owner + (0..<8).reversed().map { UInt8((UInt64(ticks) >> (8 * UInt64($0))) & 0xFF) }
        let frame = Array("PRIV".utf8) + syncsafe(body.count) + [0, 0] + body
        return Data(Array("ID3".utf8) + [4, 0, 0] + syncsafe(frame.count) + frame)
    }

    /// `hlsPackedAudio`'s picture with its packed sound as an audio rendition (`alone`: the sound as the only variant),
    /// each segment served with an ID3 tag whose `PRIV` time is `firstTicks` and on by the playlist's durations, wrapping
    /// at 33 bits as MPEG-TS time does (nil: no tag).
    private static func packedAudioInput(_ stand: Stand, firstTicks: Int64?, alone: Bool = false) throws -> HLSInput {
        let master =
            alone
            ? "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"mp4a.40.2\"\np.m3u8\n"
            : """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Sound",DEFAULT=YES,URI="p.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=320x180,CODECS="avc1.640015,mp4a.40.2",AUDIO="aud"
            v.m3u8

            """
        stand.server.setResponder(forPath: "master.m3u8") { Data(master.utf8) }
        let listed = try String(contentsOf: stand.directory.appendingPathComponent("p.m3u8"), encoding: .utf8)
        let durations = listed.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }.compactMap {
            Double($0.dropFirst("#EXTINF:".count).prefix { $0 != "," })
        }
        var start = 0.0
        for (index, duration) in durations.enumerated() {
            let bytes = try Data(contentsOf: stand.directory.appendingPathComponent("p_\(index).aac"))
            let tag = firstTicks.map {
                Self.id3(transportStreamTimestamp: ($0 + Int64((start * 90_000).rounded())) & (Int64(1) << 33 - 1))
            }
            stand.server.setResponder(forPath: "p_\(index).aac") { (tag ?? Data()) + bytes }
            start += duration
        }
        return try #require(
            HLSInput(url: stand.server.url("master.m3u8"), headers: [:], interrupt: FFmpegInterrupt()))
    }

    @Test("Packed audio is placed by its ID3 PRIV time against the picture, after a seek too")
    func packedAudioTakesItsPRIVTime() throws {
        guard let stand = try Self.stand(.hlsPackedAudio) else { return }
        defer { stand.server.stop() }
        // The picture's first presentation time in its MPEG-TS is 1.4667 s (132000 ticks): the sound 0.5 s after it.
        let input = try Self.packedAudioInput(stand, firstTicks: 132_000 + 45_000)
        let firstAudio = { (packets: [Packet]) in packets.first { !$0.isVideo }?.pts }
        let (start, _) = Self.drain(input, limit: 80)
        #expect(start.first { $0.isVideo }.map { abs($0.pts) < 0.01 } == true)
        let audio = try #require(firstAudio(start))
        #expect(abs(audio - 0.5) < 0.01, "the sound starts at \(audio) s")

        // Its second segment, 2.0053 s later by the PRIV of its own run.
        let videoIndex = try #require(
            (0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_VIDEO })
        let base = input.stream(videoIndex)!.pointee.time_base
        #expect(
            input.seek(
                stream: videoIndex, to: Int64(3.0 * Double(base.den) / Double(base.num)), flags: AVSEEK_FLAG_BACKWARD)
                >= 0)
        let (after, _) = Self.drain(input, limit: 80)
        let seeked = try #require(firstAudio(after))
        #expect(abs(seeked - 2.5053) < 0.01, "after the seek the sound starts at \(seeked) s")
    }

    @Test("A packed run whose PRIV wrapped after its sequence was anchored is placed where the playlist puts it")
    func packedAudioAcrossTheWrap() throws {
        guard let stand = try Self.stand(.hlsPackedAudio) else { return }
        defer { stand.server.stop() }
        // The sound alone anchors its sequence a second before MPEG-TS time wraps; its second segment is past the wrap.
        let input = try Self.packedAudioInput(stand, firstTicks: (Int64(1) << 33) - 90_000, alone: true)
        let (start, _) = Self.drain(input, limit: 5)
        #expect(abs((start.first?.pts ?? 99) - 0) < 0.01)
        let audioIndex = try #require(
            (0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_AUDIO })
        let base = input.stream(audioIndex)!.pointee.time_base
        #expect(
            input.seek(
                stream: audioIndex, to: Int64(3.0 * Double(base.den) / Double(base.num)), flags: AVSEEK_FLAG_BACKWARD)
                >= 0)
        let (after, _) = Self.drain(input, limit: 5)
        let seeked = try #require(after.first?.pts)
        #expect(abs(seeked - 2.0053) < 0.01, "after the seek the sound starts at \(seeked) s")
    }

    @Test("Packed audio without a PRIV time is placed by its playlist and leaves the shared offsets alone")
    func packedAudioWithoutPRIV() throws {
        guard let stand = try Self.stand(.hlsPackedAudio) else { return }
        defer { stand.server.stop() }
        let input = try Self.packedAudioInput(stand, firstTicks: nil)
        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let audio = packets.filter { !$0.isVideo }
        let video = packets.filter(\.isVideo)
        #expect(abs((audio.first?.pts ?? 99) - 0) < 0.01, "the sound starts at \(audio.first?.pts ?? 99) s")
        // The picture keeps its own anchor: from 0, to its end at 6 s.
        #expect(abs((video.first?.pts ?? 99) - 0) < 0.01)
        #expect(abs((video.map(\.pts).max() ?? 0) - 6) < 0.1)
    }

    @Test("An audio rendition whose durations disagree with its media keeps its place against the picture after a seek")
    func audioRenditionSharesThePicturesOffset() throws {
        guard let stand = try Self.stand(.hlsRenditions) else { return }
        defer { stand.server.stop() }
        // Each segment listed 0.31 s longer than it is (half an AAC frame off its grid): the third starts 0.62 s late.
        let listed = try String(contentsOf: stand.directory.appendingPathComponent("vEnglish.m3u8"), encoding: .utf8)
        stand.server.setResponder(forPath: "vEnglish.m3u8") {
            Data(listed.replacingOccurrences(of: "#EXTINF:2.005333,", with: "#EXTINF:2.315333,").utf8)
        }
        let input = try #require(Self.open(stand, "master.m3u8"))
        let audioTimes = { (packets: [Packet]) in packets.filter { !$0.isVideo }.map(\.dts) }
        let (whole, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        let read = audioTimes(whole)
        #expect(!read.isEmpty)

        let videoIndex = try #require(
            (0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_VIDEO })
        let base = input.stream(videoIndex)!.pointee.time_base
        let target = Int64(4.5 * Double(base.den) / Double(base.num))
        #expect(input.seek(stream: videoIndex, to: target, flags: AVSEEK_FLAG_BACKWARD) >= 0)
        let (packets, _) = Self.drain(input, limit: 60)
        // Where the sound was when read from the start, not where its playlist puts its segment.
        let audio = try #require(audioTimes(packets).first)
        #expect(read.contains { abs($0 - audio) < 0.002 }, "audio after the seek at \(audio) s")
    }

    @Test("A seek into segments whose listed durations drift lands in the segment that holds it, by the media's times")
    func seekCorrectsTheTimelineFromTheMedia() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        // Every segment listed 25 % short (1.5 s of 2 s): the third starts at 3 s by the list, 4 s by the media.
        let listed = try String(contentsOf: stand.directory.appendingPathComponent("v0.m3u8"), encoding: .utf8)
        stand.server.setResponder(forPath: "short.m3u8") {
            Data(listed.replacingOccurrences(of: "#EXTINF:2.000000,", with: "#EXTINF:1.500000,").utf8)
        }
        stand.server.setResponder(forPath: "alone.m3u8") {
            Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=400000,CODECS=\"avc1.64000d,mp4a.40.2\"\nshort.m3u8\n".utf8)
        }
        let input = try #require(Self.open(stand, "alone.m3u8"))
        // Read from the start, which anchors the sequence where the media is.
        let (head, _) = Self.drain(input, limit: 20)
        #expect(abs((head.first?.pts ?? 99) - 0) < 0.1)
        let videoIndex = try #require(
            (0..<input.streamCount).first { Self.codecTypes(input)[$0] == AVMEDIA_TYPE_VIDEO })
        let base = input.stream(videoIndex)!.pointee.time_base
        // By the listed durations 3.5 s is in the third segment (3…4.5 s), which the media starts at 4 s.
        let target = 3.5
        #expect(
            input.seek(
                stream: videoIndex, to: Int64(target * Double(base.den) / Double(base.num)), flags: AVSEEK_FLAG_BACKWARD
            )
                >= 0)
        let (packets, _) = Self.drain(input, limit: 40)
        let video = packets.filter(\.isVideo)
        let first = try #require(video.first?.pts)
        // The segment before, from 2 s: the keyframe at or before the target, not the one of the third segment (4 s).
        #expect(first <= target + 0.001 && first > target - 2.1, "the picture after the seek starts at \(first) s")
        // And the times that follow are the media's.
        #expect(abs(first - 2) < 0.2, "the picture after the seek starts at \(first) s")
        // The sound of the segment dropped never came out: its times don't run back after the first (a rewind in the
        // sound would move the demuxer's search floor and feed the decoder twice).
        let audio = packets.filter { !$0.isVideo }.map(\.dts)
        #expect(!audio.isEmpty)
        #expect(zip(audio, audio.dropFirst()).allSatisfy { $1 >= $0 - 0.05 }, "sound times \(audio)")
        #expect((audio.first ?? 99) < 2.5, "the sound after the seek starts at \(audio.first ?? 99) s")
    }

    // MARK: Where the playlist is

    @Test("A saved playlist is read from its directory: the file is the master, its segments files")
    func readsSavedPlaylist() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let path = stand.directory.appendingPathComponent("master.m3u8").path
        #expect(HLSInput.applies(to: path))
        let input = try #require(HLSInput(url: path, headers: [:], interrupt: FFmpegInterrupt()))
        #expect(!input.isNetworkSource)
        #expect(input.network == nil)
        #expect(abs(input.durationSeconds - 6) < 0.5)
        let (packets, code) = Self.drain(input)
        #expect(code == MediaDemuxer.averrorEOF)
        #expect(packets.filter(\.isVideo).count > 100)
    }

    @Test("The length of a finished stream comes from its playlists, a live one has none")
    func finishedDuration() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        _ = Self.liveStand(stand) { _ in (2, false) }
        let interrupt = FFmpegInterrupt()
        let vod = HLSInput.finishedDuration(of: stand.server.url("master.m3u8"), headers: [:], interrupt: interrupt)
        #expect(abs((vod ?? 0) - 6) < 0.5)
        let saved = stand.directory.appendingPathComponent("master.m3u8").path
        #expect(abs((HLSInput.finishedDuration(of: saved, headers: [:], interrupt: interrupt) ?? 0) - 6) < 0.5)
        #expect(HLSInput.finishedDuration(of: stand.server.url("live.m3u8"), headers: [:], interrupt: interrupt) == nil)
    }

    @Test("Thumbnails read the cheapest variant of a finished stream, seek by time, and refuse a live one")
    func thumbnailSource() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        _ = Self.liveStand(stand) { _ in (2, false) }
        let interrupt = FFmpegInterrupt()
        #expect(ThumbnailSource.openHLS(url: stand.server.url("live.m3u8"), headers: [:], interrupt: interrupt) == nil)

        let source = try #require(
            ThumbnailSource.openHLS(url: stand.server.url("master.m3u8"), headers: [:], interrupt: interrupt))
        defer { source.close() }
        #expect(abs(source.containerDuration - 6) < 0.5)
        #expect(source.timelineOffset == 0)
        let packet = av_packet_alloc()!
        defer {
            var optional: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&optional)
        }
        for target in [4.0, 1.0, 0.0] {
            source.seek(toSeconds: target)
            var first: Double?
            while first == nil, source.read(packet) >= 0 {
                defer { av_packet_unref(packet) }
                guard packet.pointee.stream_index == source.streamIndex else { continue }
                let base = source.stream.pointee.time_base
                first = Double(packet.pointee.pts) * Double(base.num) / Double(base.den)
                #expect(packet.pointee.flags & AV_PKT_FLAG_KEY != 0)
            }
            let landed = try #require(first)
            #expect(landed <= target + 0.01 && landed > target - 3.1, "\(target) s landed at \(landed) s")
        }
        // The opening probes the start of every variant; only the cheapest is read on.
        let segments = stand.server.requests.map(\.path).filter { $0.hasSuffix(".ts") }
        #expect(Set(segments.filter { $0.hasPrefix("v1_") }).isSubset(of: ["v1_000.ts"]), "\(segments)")
        #expect(segments.contains("v0_002.ts"))
    }

    @Test("A playlist under a name that tells none plays: FFmpeg fails on it, or takes it for text (.txt, tty)")
    func playsPlaylistsUnderOtherNames() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let playlist = try Data(contentsOf: stand.directory.appendingPathComponent("master.m3u8"))
        for name in ["list.php", "list.txt", "stream"] {
            stand.server.setResponder(forPath: name) { playlist }
            let demuxer = try #require(MediaDemuxer(url: stand.server.url(name)), Comment(rawValue: name))
            #expect(demuxer.variants.count == 2, "\(name)")
            #expect(demuxer.nextVideoSample() != nil, "\(name)")
        }
    }

    @Test("A plain track list named .m3u8 is not an HLS manifest")
    func trackListIsNotHLS() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsTrackList-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let list = directory.appendingPathComponent("tracks.m3u8")
        try "#EXTM3U\n#EXTINF:10,Song\nsong.mp3\n".write(to: list, atomically: true, encoding: .utf8)
        #expect(!HLSInput.applies(to: list.path))
    }

    @Test("A playlist served over HTTP(S) never reads the disk, whatever it lists")
    func remotePlaylistDoesNotReadFiles() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let file = stand.directory.appendingPathComponent("master.m3u8")
        let listing = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n\(file.absoluteString)\n#EXT-X-ENDLIST\n"
        stand.server.setResponder(forPath: "escape.m3u8") { Data(listing.utf8) }
        #expect(HLSInput(url: stand.server.url("escape.m3u8"), headers: [:], interrupt: FFmpegInterrupt()) == nil)
    }

    @Test("An address without an extension is a playlist when its first bytes say so")
    func sniffsPlaylistsWithoutExtension() throws {
        guard let stand = try Self.stand(.hlsVariants) else { return }
        defer { stand.server.stop() }
        let playlist = try Data(contentsOf: stand.directory.appendingPathComponent("master.m3u8"))
        stand.server.setResponder(forPath: "stream") { playlist }
        stand.server.setResponder(forPath: "radio") { Data("ID3\u{3}\u{0}binary".utf8) }
        let interrupt = FFmpegInterrupt()
        #expect(HLSInput.sniffsAsPlaylist(stand.server.url("stream"), headers: [:], interrupt: interrupt))
        #expect(!HLSInput.sniffsAsPlaylist(stand.server.url("radio"), headers: [:], interrupt: interrupt))
        // Whatever the name: a playlist under another one is found by its bytes.
        stand.server.setResponder(forPath: "list.php") { playlist }
        #expect(HLSInput.sniffsAsPlaylist(stand.server.url("list.php"), headers: [:], interrupt: interrupt))
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
