import CFFmpeg
import CoreMedia
import Foundation
import Testing

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
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, let sample = demuxer.nextVideoSample() {
            times.append(Self.seconds(sample, demuxer))
        }
        #expect(times.count >= 350, "\(times.count) pictures of 12 s at 30 fps")
        let backwards = zip(times, times.dropFirst()).map { $0 - $1 }.max() ?? 0
        #expect(backwards < 0.3, "A picture came \(backwards) s before the one before it")
        #expect((times.max() ?? 0) > 11.5, "The pictures end at \(times.max() ?? 0) s of 12")
        #expect(
            times.filter { $0 > 3.95 && $0 < 4.05 }.count >= 1, "The second segment starts where the playlist puts it")
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
}
