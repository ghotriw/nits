import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// Stopping the feeders while the engine still counts as feeding looks to it like a demuxer that stopped delivering
/// (a stalled network or disk): the queued audio and frames play out, then nothing follows.
@Suite("Buffering when media data runs out", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct BufferingTests {
    private func startPlayback(
        _ preset: SyntheticTestMediaFactory.Preset = .multiTrackH264, rate: Double = 1
    ) async -> PlayerEngine? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return nil }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        #expect(await engine.waitForPlayback(advancingBy: 0.5))
        engine.setPlaybackRate(rate)
        // Let the renderer and the frame queue settle at the new rate.
        try? await Task.sleep(for: .milliseconds(500))
        return engine
    }

    /// Clock position after it has held still for a moment, or `nil` if it kept moving.
    private func heldClock(of engine: PlayerEngine) async -> Double? {
        let before = engine.synchronizer.currentTime().seconds
        try? await Task.sleep(for: .milliseconds(400))
        let after = engine.synchronizer.currentTime().seconds
        return abs(after - before) < 0.01 ? after : nil
    }

    private func stopFeeding(_ engine: PlayerEngine) {
        engine.stopFeedingVideo()
        engine.stopFeedingAudio()
    }

    private func resumeFeeding(_ engine: PlayerEngine) {
        engine.startFeedingVideo()
        engine.startFeedingAudio()
    }

    /// Expects buffering to start, hold the clock (within the queued audio, if any) and end once data returns, with
    /// playback continuing from the held position and not dropping straight back into buffering.
    private func expectHoldAndResume(_ engine: PlayerEngine, rate: Double) async {
        stopFeeding(engine)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.isBuffering }, "Buffering did not start")
        let held = await heldClock(of: engine)
        #expect(held != nil, "The clock kept running through the outage")
        if let held, let audioEnd = engine.audioSink.bufferedEnd?.seconds {
            #expect(held <= audioEnd + 0.01, "The clock ran past the queued audio (\(held)s > \(audioEnd)s)")
        }
        #expect(engine.isPlaying, "Buffering is not a pause")

        resumeFeeding(engine)
        #expect(await engine.waitUntil { !engine.isBuffering }, "Buffering did not end once data returned")
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            #expect(!engine.isBuffering, "Buffering started again right after resuming")
        }
        let position = engine.synchronizer.currentTime().seconds
        if let held {
            #expect(
                position > held && position < held + 2 * rate,
                "Playing at \(position)s one second after resuming, the clock held at \(held)s")
        }
        engine.stop()
    }

    @Test(
        "The clock holds while audio and video run dry and resumes where it stopped once data returns",
        arguments: [1.0, 2.0, 4.0])
    func holdsAndResumes(rate: Double) async {
        guard let engine = await startPlayback(rate: rate) else { return }
        await expectHoldAndResume(engine, rate: rate)
    }

    @Test("Without audio, the clock holds once the frames run out and resumes when they return")
    func videoOnlyHoldsAndResumes() async {
        guard let engine = await startPlayback(.videoOnlyH264) else { return }
        #expect(engine.audioSink.bufferedEnd == nil, "The preset has an audio track")
        await expectHoldAndResume(engine, rate: 1)
    }

    @Test(
        "Audio running out while video still plays (a shorter audio track) does not hold playback",
        arguments: [
            (SyntheticTestMediaFactory.Preset.multiTrackH264, 1.0), (.multiTrackH264, 2.0),
            // At 60 fps the whole frame queue holds under 0.7 s.
            (.h264HFR60, 1.0),
        ])
    func audioEndingEarlyKeepsPlaying(preset: SyntheticTestMediaFactory.Preset, rate: Double) async {
        guard let engine = await startPlayback(preset, rate: rate) else { return }
        let start = engine.synchronizer.currentTime().seconds
        engine.stopFeedingAudio()

        // Long enough for the ~1 s of queued playback audio to run out well before the end.
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            #expect(!engine.isBuffering, "Buffering started although video kept playing")
        }
        #expect(engine.synchronizer.currentTime().seconds > start + 2.5 * rate, "The clock did not keep running")
        engine.stop()
    }

    @Test("Pausing while buffering ends it, and play resumes from the held position")
    func pauseEndsBuffering() async {
        guard let engine = await startPlayback() else { return }
        stopFeeding(engine)
        #expect(await engine.waitUntil(timeout: .seconds(5)) { engine.isBuffering }, "Buffering did not start")
        let held = engine.synchronizer.currentTime().seconds

        engine.pause()
        #expect(!engine.isBuffering)
        #expect(!engine.isPlaying)

        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 0.5), "Playback did not resume after pause")
        #expect(!engine.isBuffering)
        let position = engine.synchronizer.currentTime().seconds
        #expect(position > held && position < held + 2, "Resumed at \(position)s, the clock held at \(held)s")
        engine.stop()
    }
}
