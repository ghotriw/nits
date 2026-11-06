import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import Testing
import os

@testable import NitsCore

/// Whether FFmpeg is the bundled build with `scripts/patches/ffmpeg-hls-timeline.patch` (its version string says so, see
/// `--extra-version` in `build_dependencies.sh`): on a Homebrew FFmpeg the timestamps of an HLS stream that restarts at a
/// discontinuity stay as they are.
private let hasHLSTimelinePatch = String(cString: av_version_info()).contains("nits-hls-timeline")

@Suite(
    "HLS discontinuities (bundled FFmpeg's timeline patch)",
    .serialized, .hostDependent, .enabled(if: hasHLSTimelinePatch, "needs ffmpeg-hls-timeline.patch"))
struct HLSDiscontinuityTests {
    private static func open(_ preset: SyntheticTestMediaFactory.Preset) throws -> (
        demuxer: MediaDemuxer, server: TestHTTPServer
    )? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return nil }
        let url = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: url.deletingLastPathComponent())
        let demuxer = try #require(MediaDemuxer(url: server.url(url.lastPathComponent)))
        return (demuxer, server)
    }

    private static func seconds(_ sample: CMSampleBuffer, _ demuxer: MediaDemuxer) -> Double {
        Double(CMSampleBufferGetPresentationTimeStamp(sample).value) * Double(demuxer.timebase.num)
            / Double(demuxer.timebase.den)
    }

    @Test("The timestamps go on across a discontinuity that restarts them")
    func timelineContinuesThroughTheBreak() throws {
        guard let (demuxer, server) = try Self.open(.hlsDiscontinuity) else { return }
        defer { server.stop() }
        var times: [Double] = []
        var audio: [(start: Double, end: Double)] = []
        let audioTimebase = demuxer.audioTimebase
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, let sample = demuxer.nextVideoSample() {
            times.append(Self.seconds(sample, demuxer))
            // The sound alongside, as the feeder takes it.
            while let packet = demuxer.nextAudioPacket() {
                let start = Double(packet.pts) * Double(audioTimebase.num) / Double(audioTimebase.den)
                let length = Double(packet.duration) * Double(audioTimebase.num) / Double(audioTimebase.den)
                audio.append((start, start + length))
                if start > (times.last ?? 0) + 0.5 { break }
            }
        }
        #expect(times.count >= 350, "\(times.count) pictures of 12 s at 30 fps")
        let backwards = zip(times, times.dropFirst()).map { $0 - $1 }.max() ?? 0
        #expect(backwards < 0.3, "A picture came \(backwards) s before the one before it")
        #expect((times.max() ?? 0) > 11.5, "The pictures end at \(times.max() ?? 0) s of 12")
        // One frame apart across the break too (30 fps): the segment is placed by its first picture's PTS, not its DTS.
        let step = zip(times.sorted(), times.sorted().dropFirst()).map { $1 - $0 }.max() ?? 0
        #expect(step < 0.05, "A step of \(step) s between pictures")
        #expect(
            times.filter { $0 > 3.95 && $0 < 4.05 }.count >= 1, "The second segment starts where the playlist puts it")

        // The audio of each segment restarts its timestamps too, and is moved the same way: one timeline, no packet
        // before the one before it, none missing (a gap of more than 100 ms), reaching the end.
        #expect(audio.count > 400, "\(audio.count) audio packets of 12 s")
        let worstGap = zip(audio, audio.dropFirst()).map { abs($1.start - $0.end) }.max() ?? 0
        #expect(worstGap < 0.1, "A gap or overlap of \(worstGap) s in the audio")
        #expect((audio.last?.end ?? 0) > 11.5, "The audio ends at \(audio.last?.end ?? 0) s of 12")
    }

    @Test("A seek past the discontinuity lands in the segment that holds the target")
    func seekPastTheBreak() throws {
        guard let (demuxer, server) = try Self.open(.hlsDiscontinuity) else { return }
        defer { server.stop() }
        for target in [6.0, 11.0] {
            demuxer.seek(to: target, exact: false)
            let sample = try #require(demuxer.nextVideoSample(), "A seek to \(target) s")
            let landed = Self.seconds(sample, demuxer)
            // The second segment is 4 to 12 s: a keyframe seek lands on a keyframe in it, not at the start of the file.
            #expect((3.9...target + 0.1).contains(landed), "A seek to \(target) s landed at \(landed) s")
        }
    }

    @Test("The picture follows the clock through a discontinuity", .realtimePlayback)
    @MainActor
    func enginePlaysThroughTheBreak() async throws {
        guard let (_, server) = try Self.open(.hlsDiscontinuity) else { return }
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: server.url("media.m3u8"))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        engine.seek(to: 2.5, exact: true)
        #expect(await engine.waitForSeekToSettle())
        engine.play()

        // From 2.5 s the break (at 4 s) is a second and a half on; watch to 7 s.
        let deadline = ContinuousClock.now + .seconds(15)
        var worst = 0.0
        while engine.currentTime < 7.0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if engine.currentTime > 4.8 { worst = max(worst, engine.currentTime - engine.currentFramePTS) }
        }
        #expect(engine.currentTime >= 7.0, "Playback reached \(engine.currentTime) s")
        #expect(worst < 0.6, "The picture trailed the clock by \(worst) s after the break")
        #expect(engine.droppedFramesCount < 20, "\(engine.droppedFramesCount) pictures dropped")
    }

    @Test("A variant switched to after a discontinuity plays on", .realtimePlayback)
    @MainActor
    func variantSwitchAfterTheBreak() async throws {
        guard let (_, server) = try Self.open(.hlsDiscontinuityLadder) else { return }
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: server.url("master.m3u8"))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        let lowest = try #require(engine.variants.min { $0.bandwidth < $1.bandwidth })
        engine.seek(to: 2.5, exact: true)
        #expect(await engine.waitForSeekToSettle())
        engine.play()

        let deadline = ContinuousClock.now + .seconds(20)
        while engine.currentTime < 4.8, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        engine.selectVariant(id: lowest.id)

        var worst = 0.0
        while engine.currentTime < 7.5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            // A seek to the current frame is under way for the switch: the picture is back within a second.
            if engine.currentTime > 5.8 { worst = max(worst, engine.currentTime - engine.currentFramePTS) }
        }
        #expect(engine.currentTime >= 7.5, "Playback reached \(engine.currentTime) s")
        #expect(worst < 0.8, "The picture trailed the clock by \(worst) s after the switch")
    }

    @Test(
        "The pictures of a segment in another size after a discontinuity play, drawn at their size", .realtimePlayback)
    @MainActor
    func sizeChangesAtTheBreak() async throws {
        guard let (_, server) = try Self.open(.hlsDiscontinuityResize) else { return }
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: server.url("media.m3u8"))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        #expect(engine.media.video.width == 320)
        engine.seek(to: 2.5, exact: true)
        #expect(await engine.waitForSeekToSettle())
        engine.play()

        // The second segment (from 4 s) is 640x360, its parameter sets other than the first's.
        let deadline = ContinuousClock.now + .seconds(15)
        var worst = 0.0
        while engine.currentTime < 7.0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if engine.currentTime > 4.8 { worst = max(worst, engine.currentTime - engine.currentFramePTS) }
        }
        #expect(engine.currentTime >= 7.0, "Playback reached \(engine.currentTime) s")
        #expect(worst < 0.6, "The picture trailed the clock by \(worst) s after the change of size")
        let buffer = try #require(engine.getLastRenderedBuffer())
        #expect(CVPixelBufferGetWidth(buffer) == 640 && CVPixelBufferGetHeight(buffer) == 360)
        #expect(engine.media.video.width == 640 && engine.media.video.height == 360, "\(engine.media.video.width)")
    }

    @Test("A start straight in the segment of another size plays at its size", .realtimePlayback)
    @MainActor
    func startInAnotherSize() async throws {
        guard let (_, server) = try Self.open(.hlsDiscontinuityResize) else { return }
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        // The first keyframe the demuxer reads after the open is in the 640x360 segment (a resumed start): the
        // description made at the open, from the first picture of the stream, is 320x180, not that of its sets.
        engine.load(MediaLoadRequest(path: server.url("media.m3u8"), startTime: 6.0))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        engine.play()

        let deadline = ContinuousClock.now + .seconds(10)
        while engine.currentTime < 7.5, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(engine.currentTime >= 7.5, "Playback reached \(engine.currentTime) s")
        #expect(engine.currentTime - engine.currentFramePTS < 0.6, "The picture stands at \(engine.currentFramePTS) s")
        let buffer = try #require(engine.getLastRenderedBuffer())
        #expect(CVPixelBufferGetWidth(buffer) == 640 && CVPixelBufferGetHeight(buffer) == 360)
        #expect(engine.media.video.width == 640, "\(engine.media.video.width)")
    }

    @Test("The player is told of a new size only when the size changes")
    func sizeEventsOnlyForASize() throws {
        for (preset, expected) in [
            (SyntheticTestMediaFactory.Preset.hlsDiscontinuityTiming, 0), (.hlsDiscontinuityResize, 2),
        ] {
            guard let (demuxer, server) = try Self.open(preset) else { return }
            defer { server.stop() }
            let events = OSAllocatedUnfairLock(initialState: [MediaDemuxer.VideoSizeChange]())
            demuxer.onVideoSizeChanged = { change in events.withLock { $0.append(change) } }
            let setsAtOpen = try #require(demuxer.lastSeenParameterSets)
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline, demuxer.nextVideoSample() != nil {}
            let setsAfter = try #require(demuxer.lastSeenParameterSets)
            #expect(MediaDemuxer.parameterSetsDiffer(setsAtOpen, setsAfter), "\(preset): the sets were the same")
            #expect(events.withLock { $0.count } == expected, "\(preset): \(events.withLock { $0 })")
        }
    }

    @Test("Other parameter sets for the same pictures are no new session and no new size", .realtimePlayback)
    @MainActor
    func sameSizeOtherSets() async throws {
        guard let (_, server) = try Self.open(.hlsDiscontinuityTiming) else { return }
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: server.url("media.m3u8"))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        let demuxer = try #require(engine.demuxer)
        engine.seek(to: 2.5, exact: true)
        #expect(await engine.waitForSeekToSettle())
        engine.play()

        // The second segment (from 4 s) has 1 reference frame against the first's 3: the same size, its SPS other (which
        // `sizeEventsOnlyForASize` checks of the same preset).
        let sizeBefore = (engine.media.video.width, engine.media.video.height)
        let deadline = ContinuousClock.now + .seconds(15)
        while engine.currentTime < 7.0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(engine.currentTime >= 7.0, "Playback reached \(engine.currentTime) s")
        #expect(engine.currentTime - engine.currentFramePTS < 0.6, "The picture stands at \(engine.currentFramePTS) s")
        #expect((engine.media.video.width, engine.media.video.height) == sizeBefore)
        let decoder = try #require(engine.decoder as? VTVideoDecoder, "The hardware decoder is the one under test")
        #expect(decoder.sessionsCreated == 1, "\(decoder.sessionsCreated) sessions")
    }

    @Test("A seek back to the first size, from an advertisement, shows the first size again", .realtimePlayback)
    @MainActor
    func sizeFollowsASeekBack() async throws {
        guard let (_, server) = try Self.open(.hlsDiscontinuityResize) else { return }
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        // Started at 5 s: the read-ahead is held until that first seek, which reads on the slow path and leaves no
        // history before 1 s, so the seek back below is not served from the packet cache.
        engine.load(MediaLoadRequest(path: server.url("media.m3u8"), startTime: 5.0))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        engine.play()

        // In the advertisement (4 to 8 s, 640x360) the reading, ahead, is in the third segment (320x180, from 8 s): the
        // demuxer's size is the first's again while the player's is the advertisement's.
        #expect(await engine.waitUntil { engine.currentTime > 5.5 && engine.media.video.width == 640 })
        // Back to the content before it: its parameter sets are those the demuxer has, so nothing in the stream says the
        // size changed, but the seek does.
        engine.seek(to: 1.0, exact: true)
        #expect(await engine.waitForSeekToSettle())
        engine.play()
        // Still in the first stretch (to 4 s): its size is on at once, not when the reading comes to the next change.
        #expect(await engine.waitUntil { engine.currentTime > 1.6 })
        #expect(engine.currentTime < 3.5, "Playback is at \(engine.currentTime) s")
        let buffer = try #require(engine.getLastRenderedBuffer())
        #expect(CVPixelBufferGetWidth(buffer) == 320, "\(CVPixelBufferGetWidth(buffer))")
        #expect(engine.media.video.width == 320 && engine.media.video.height == 180)
    }
}

@Suite(
    "HLS discontinuities in fragmented MP4 (a new EXT-X-MAP)",
    .serialized, .hostDependent, .enabled(if: hasHLSTimelinePatch, "needs ffmpeg-hls-timeline.patch"))
struct HLSDiscontinuityFMP4Tests {
    @Test("The pictures of a segment with another init section play, drawn at their size", .realtimePlayback)
    @MainActor
    func sizeChangesWithTheInitSection() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsDiscontinuityFMP4) else { return }
        let url = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: url.deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: server.url(url.lastPathComponent))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        #expect(engine.media.video.width == 320)
        engine.seek(to: 2.5, exact: true)
        #expect(await engine.waitForSeekToSettle())
        engine.play()

        // The second segment (from 4 s) is 640x360 with an init section of its own.
        let deadline = ContinuousClock.now + .seconds(15)
        var worst = 0.0
        while engine.currentTime < 7.0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if engine.currentTime > 4.8 { worst = max(worst, engine.currentTime - engine.currentFramePTS) }
        }
        #expect(engine.currentTime >= 7.0, "Playback reached \(engine.currentTime) s")
        #expect(worst < 0.6, "The picture trailed the clock by \(worst) s after the change of init section")
        let buffer = try #require(engine.getLastRenderedBuffer())
        #expect(CVPixelBufferGetWidth(buffer) == 640 && CVPixelBufferGetHeight(buffer) == 360)
        #expect(engine.media.video.width == 640 && engine.media.video.height == 360, "\(engine.media.video.width)")
    }

    @Test("A separate audio rendition with breaks of its own meets the picture on one timeline")
    func audioRenditionMeetsThePicture() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsDiscontinuityFMP4AudioRendition) else {
            return
        }
        let url = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: url.deletingLastPathComponent())
        defer { server.stop() }
        let demuxer = try #require(MediaDemuxer(url: server.url(url.lastPathComponent)))
        var video: [(seconds: Double, width: Int32)] = []
        var audio: [(start: Double, end: Double)] = []
        let audioTimebase = demuxer.audioTimebase
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, let sample = demuxer.nextVideoSample() {
            let width = CMSampleBufferGetFormatDescription(sample).map {
                CMVideoFormatDescriptionGetDimensions($0).width
            }
            video.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, width ?? 0))
            while let packet = demuxer.nextAudioPacket() {
                let start = Double(packet.pts) * Double(audioTimebase.num) / Double(audioTimebase.den)
                let length = Double(packet.duration) * Double(audioTimebase.num) / Double(audioTimebase.den)
                audio.append((start, start + length))
                if start > (video.last?.seconds ?? 0) + 0.5 { break }
            }
        }
        let pictures = video.map(\.seconds).sorted()
        #expect(pictures.count >= 235, "\(pictures.count) pictures of 8 s at 30 fps")
        #expect((pictures.last ?? 0) > 7.8, "The pictures end at \(pictures.last ?? 0) s of 8")
        let pictureGap = zip(pictures, pictures.dropFirst()).map { $1 - $0 }.max() ?? 0
        #expect(
            pictureGap < 0.05,
            "A gap of \(pictureGap) s in the pictures: \(zip(pictures, pictures.dropFirst()).filter { $1 - $0 > 0.04 }.map { "\($0)->\($1)" })"
        )
        #expect(audio.count > 370, "\(audio.count) audio packets of 8 s")
        let worstGap = zip(audio, audio.dropFirst()).map { abs($1.start - $0.end) }.max() ?? 0
        #expect(worstGap < 0.1, "A gap or overlap of \(worstGap) s in the audio")
        #expect((audio.last?.end ?? 0) > 7.8, "The audio ends at \(audio.last?.end ?? 0) s of 8")
        // The first picture of the second stretch is the first of the larger size; its sound is the packet after the
        // last of the first stretch (the one that reaches 4 s). Both start where the playlists put the break (4 s).
        let firstPicture = try #require(video.filter { $0.width == 640 }.map(\.seconds).min())
        let lastOfFirst = try #require(audio.firstIndex { $0.end >= 3.99 })
        #expect(lastOfFirst + 1 < audio.count)
        let firstAudio = audio[lastOfFirst + 1].start
        // Each stretch of this synthetic stream starts with the picture a reordering delay (67 ms) after its sound (the
        // tracks are encoded apart, only the video is shifted). The second must keep the first's lead: that proves the
        // break keeps the positions to each other, not an absolute sync.
        let lead = try #require(pictures.first) - (audio.first?.start ?? 0)
        #expect(abs(firstPicture - 4.0 - lead) < 0.03, "The picture of the second stretch starts at \(firstPicture) s")
        #expect(abs(firstAudio - 4.0) < 0.03, "The sound of the second stretch starts at \(firstAudio) s")
        #expect(abs((firstPicture - firstAudio) - lead) < 0.02, "Lead \(firstPicture - firstAudio) s against \(lead) s")
    }

    @Test("A seek past the break reads the other init section: the size follows", .realtimePlayback)
    @MainActor
    func sizeFollowsSeeksAcrossTheBreak() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsDiscontinuityFMP4AudioRendition) else {
            return
        }
        let url = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: url.deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        // Started at 5.5 s (the read-ahead is held until that first seek): no history before 1 s for the seek back.
        engine.load(MediaLoadRequest(path: server.url(url.lastPathComponent), startTime: 5.5))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        engine.play()
        #expect(await engine.waitUntil { engine.currentTime > 6.2 })
        #expect(engine.currentTime - engine.currentFramePTS < 0.6, "The picture stands at \(engine.currentFramePTS) s")
        var buffer = try #require(engine.getLastRenderedBuffer())
        #expect(CVPixelBufferGetWidth(buffer) == 640, "\(CVPixelBufferGetWidth(buffer))")

        // Back into the first stretch: its init section is read again and its size is on at once.
        engine.seek(to: 1.0, exact: true)
        #expect(await engine.waitForSeekToSettle())
        engine.play()
        #expect(await engine.waitUntil { engine.currentTime > 1.6 })
        #expect(engine.currentTime - engine.currentFramePTS < 0.6, "The picture stands at \(engine.currentFramePTS) s")
        buffer = try #require(engine.getLastRenderedBuffer())
        #expect(CVPixelBufferGetWidth(buffer) == 320, "\(CVPixelBufferGetWidth(buffer))")
        #expect(engine.media.video.width == 320)
    }
}
