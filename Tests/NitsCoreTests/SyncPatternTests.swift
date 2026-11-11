import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import NitsCore

/// A/V sync on the `flashClick` pattern: a white frame and a click at every whole second.
///
/// What a test can see of sync, it checks: that the frame on screen is the one for the clock (the flash shows when the
/// clock is at its second, and only there), and that the audio handed to the renderer carries each click at its own
/// timestamp (cuts, seeks, the audio delay and an external track keep the timestamps true to the content). That the
/// synchronizer plays the audio at its timestamps, and the output's latency, is for the ear (`flashClick` in the bundle).
@Suite("A/V sync pattern", .serialized, .realtimePlayback, .hostDependent)
@MainActor
struct SyncPatternTests {
    /// How far from its second the clock may be when the flash is seen: the frame is picked for the next vsync and seen
    /// on the main actor's next poll, a frame (33 ms) and some.
    static let pictureTolerance = 0.06
    /// How far from its second a click may start in the audio fed: its rise takes a sample to pass the threshold; the
    /// rest (10 samples at 48 kHz) leaves room for rounding, not for a timestamp a millisecond off its audio.
    static let clickTolerance = 0.0002

    private static func load(external: Bool = false) async -> PlayerEngine? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .flashClick) else { return nil }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: path)
        guard await engine.waitForPlayback(advancingBy: 0.2) else {
            engine.stop()
            return nil
        }
        if external {
            guard let audio = SyntheticTestMediaFactory.ensureMedia(preset: .flashClickAudio),
                let track = await engine.attachExternalAudio(url: URL(fileURLWithPath: audio)).first
            else {
                engine.stop()
                return nil
            }
            engine.selectAudioTrack(id: track.id)
            guard await engine.waitForPlayback(advancingBy: 0.2), engine.inputs?.isAudioSeparate == true else {
                engine.stop()
                return nil
            }
        }
        return engine
    }

    // MARK: - Tests

    @Test("Playing from the start, the flash and the clicks are on their seconds")
    func fromStart() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        await Self.check(engine, "from the start")
    }

    @Test("After a keyframe seek forward (the renderer kept), the flash and the clicks are on their seconds")
    func seekForward() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.seek(to: 12.4)
        #expect(await engine.waitForPlayback(advancingBy: 0.1))
        await Self.check(engine, "after a seek forward")
    }

    @Test("After a keyframe seek back (the renderer flushed), the flash and the clicks are on their seconds")
    func seekBack() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.seek(to: 14.4)
        #expect(await engine.waitForPlayback(advancingBy: 0.5))
        engine.seek(to: 4.6)
        #expect(await engine.waitForPlayback(advancingBy: 0.1))
        await Self.check(engine, "after a seek back")
    }

    @Test("After an exact seek between flashes, the flash and the clicks are on their seconds")
    func exactSeek() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.seek(to: 7.5, exact: true)
        #expect(await engine.waitForPlayback(advancingBy: 0.1))
        await Self.check(engine, "after an exact seek")
    }

    @Test("With an audio delay, the clicks fed are still at their seconds of the media")
    func audioDelay() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.setAudioDelay(0.25)
        #expect(await engine.waitForPlayback(advancingBy: 0.1))
        await Self.check(engine, "with a 0.25 s audio delay")
    }

    @Test("With the audio from an added file, the flash and the clicks are on their seconds")
    func externalAudio() async throws {
        guard let engine = await Self.load(external: true) else { return }
        defer { engine.stop() }
        engine.seek(to: 9.4)
        #expect(await engine.waitForPlayback(advancingBy: 0.1))
        await Self.check(engine, "with external audio, after a seek")
    }

    @Test(
        "Across an HLS discontinuity with the sound in a rendition of its own, the flash and the clicks stay on their seconds"
    )
    func acrossAnHLSBreak() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsDiscontinuityFlashClick) else { return }
        let url = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: url.deletingLastPathComponent())
        defer { server.stop() }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        // Two 6 s stretches, each with its own timestamps from 0, the break at 6 s: the stretches, picture and sound
        // from playlists of their own, must put flash and click on the seconds of the whole timeline. Each run is placed
        // by its first picture's presentation time, so the 2 frames the synthetic video lies after the sound by its
        // reordering (the tracks being encoded apart) do not come back at the break as a shift between picture and sound.
        engine.load(MediaLoadRequest(path: server.url(url.lastPathComponent), startTime: 4.2))
        #expect(await engine.waitUntil { engine.isLoaded }, "The playlist did not load")
        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 0.2))
        let lead = 0.0
        let seen = await Self.check(engine, "across the HLS break", for: .seconds(4), pictureLead: lead)
        #expect(engine.currentTime > 7.0, "Playback reached only \(engine.currentTime) s")
        // The seconds repeat, so the fractions above would pass a second stretch that is a whole number of seconds
        // off (an offset not taken): the second stretch's first whole second (7 s, the click at the break itself is
        // not a start for `clickOnsets`) must be seen, in picture and in sound, where the timeline puts it.
        #expect(seen.flashes.contains { abs($0 - (7 + lead)) < 0.005 }, "Flashes seen at \(seen.flashes)")
        #expect(seen.clicks.contains { abs($0 - 7) < Self.clickTolerance }, "Clicks fed at \(seen.clicks)")
    }

    // MARK: - Checks

    /// Watches 1.2 s of playback (a flash at least: tests that play in real time share a queue, see AGENTS.md), then
    /// checks the frames seen and the audio fed.
    @discardableResult
    private static func check(
        _ engine: PlayerEngine, _ scenario: String, for duration: Duration = .milliseconds(1200),
        pictureLead: Double = 0
    ) async -> (flashes: [Double], clicks: [Double]) {
        let frames = await watchFrames(engine, for: duration)
        let flashes = frames.filter(\.isBright)
        #expect(!flashes.isEmpty, "\(scenario): no flash seen in \(duration)")
        for frame in frames {
            let shifted = frame.pts - pictureLead
            let onSecond = abs(shifted - shifted.rounded()) < 0.005
            #expect(
                frame.isBright == onSecond,
                "\(scenario): the frame at \(frame.pts)s is \(frame.isBright ? "white" : "black")")
        }
        for flash in flashes {
            #expect(
                abs(flash.clockLag) < pictureTolerance,
                "\(scenario): the flash at \(flash.pts)s seen with the clock \(Int(flash.clockLag * 1000)) ms off")
        }

        let onsets = clickOnsets(in: engine.audioSink.retainedAudio)
        #expect(!onsets.isEmpty, "\(scenario): no click in the audio fed")
        for onset in onsets {
            #expect(
                abs(onset - onset.rounded()) < clickTolerance,
                "\(scenario): a click starts at \(String(format: "%.4f", onset))s of the audio fed")
        }
        return (flashes.map(\.pts), onsets)
    }

    private struct SeenFrame {
        let pts: Double
        let isBright: Bool
        /// The clock when the frame was first seen, less its timestamp.
        let clockLag: Double
    }

    /// The frames the display link puts up while the clock runs, as the main actor sees them.
    private static func watchFrames(_ engine: PlayerEngine, for duration: Duration) async -> [SeenFrame] {
        var seen: [SeenFrame] = []
        var lastPTS = -1.0
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(2))
            guard engine.isPlaying, !engine.isSeeking, engine.pendingSeekTime == nil,
                let frame = engine.frameQueue.getLastRenderedFrame(), frame.pts != lastPTS
            else { continue }
            lastPTS = frame.pts
            let clock = engine.playbackClock.currentTime().seconds
            seen.append(SeenFrame(pts: frame.pts, isBright: isBright(frame.pixelBuffer), clockLag: clock - frame.pts))
        }
        return seen
    }

    /// Whether the picture is white: the luma (or green) of a grid of pixels, by its most significant byte.
    private static func isBright(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let isPlanar = CVPixelBufferIsPlanar(buffer)
        let width = isPlanar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = isPlanar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let base = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        let rowBytes = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        guard let bytes = base?.assumingMemoryBound(to: UInt8.self), width > 0, height > 0 else { return false }
        // 1 byte a sample (8-bit luma), 2 (16-bit words, little-endian: the high byte second), 4 (BGRA: green).
        let stride = max(1, rowBytes / width)
        let byte = stride == 2 ? 1 : (stride == 4 ? 1 : 0)
        var total = 0
        var count = 0
        for y in Swift.stride(from: 0, to: height, by: 16) {
            for x in Swift.stride(from: 0, to: width, by: 16) {
                total += Int(bytes[y * rowBytes + x * stride + byte])
                count += 1
            }
        }
        return count > 0 && total / count > 128
    }

    /// Where clicks start in `buffers` (decoded interleaved Float32, in timestamp order), in media seconds: a sample
    /// past the threshold after at least a millisecond of quiet. A start cut off at the head of a run, or of a buffer
    /// that does not follow the one before (a kept renderer's old audio, then the new), is not a start.
    private static func clickOnsets(in buffers: [CMSampleBuffer]) -> [Double] {
        var onsets: [Double] = []
        var quietRun = 0
        var expectedStart: CMTime?
        for buffer in buffers.sorted(by: { $0.presentationTimeStamp < $1.presentationTimeStamp }) {
            guard let format = buffer.formatDescription?.audioStreamBasicDescription,
                format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            else { continue }
            let start = buffer.presentationTimeStamp
            if let expectedStart, abs((start - expectedStart).seconds) > 1.5 / format.mSampleRate { quietRun = 0 }
            expectedStart = start + buffer.duration
            let channels = Int(format.mChannelsPerFrame)
            guard let samples = try? buffer.dataBuffer?.dataBytes() else { continue }
            let frames = samples.count / (4 * channels)
            let quietNeeded = Int(format.mSampleRate / 1000)
            samples.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Float.self)
                for frame in 0..<frames {
                    let value = abs(values[frame * channels])
                    if value > 0.05 {
                        if quietRun >= quietNeeded {
                            onsets.append(start.seconds + Double(frame) / format.mSampleRate)
                        }
                        quietRun = 0
                    } else if value < 0.001 {
                        quietRun += 1
                    }
                }
            }
        }
        return onsets
    }
}
