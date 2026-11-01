import Foundation
import Testing

@testable import NitsCore

/// An arrow key scrubs (`beginScrubbing` at its press, `endScrubbing` at its release): the seeks show their frames and
/// hold the clock, and playback resumes once, from the last landing.
@Suite("Scrubbing", .serialized, .realtimePlayback, .hostDependent)
@MainActor
struct SeekScrubbingTests {
    private static func playingEngine() async -> PlayerEngine? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return nil }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: path)
        guard await engine.waitForPlayback(advancingBy: 0.3), engine.media.duration > 12 else {
            engine.stop()
            return nil
        }
        return engine
    }

    @Test("Seeks while scrubbing hold the clock at their landing; the end resumes from the last one")
    func holdsThenResumes() async throws {
        guard let engine = await Self.playingEngine() else { return }
        defer { engine.stop() }

        engine.beginScrubbing()
        for _ in 0..<3 {
            engine.seekRelative(by: 2, exact: false)
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(await engine.waitUntil { !engine.isSeeking }, "The seeks did not land")
        let landed = try #require(engine.pendingSeekTime, "The landing was not kept for the resume")
        let heldAt = engine.playbackClock.currentTime().seconds
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(engine.playbackClock.currentTime().seconds - heldAt) < 0.05, "The clock ran while scrubbing")
        #expect(abs(heldAt - landed) < 0.05, "The clock is not held at the landing")
        #expect(engine.isPlaying, "Scrubbing dropped the intent to play")

        engine.endScrubbing()
        #expect(await engine.waitForPlayback(advancingBy: 0.3), "Playback did not resume")
        #expect(engine.playbackClock.currentTime().seconds >= landed, "Resumed before the landing")
    }

    @Test("A pause while scrubbing settles the landing at once: play works before the key is released")
    func pausedWhileScrubbing() async throws {
        guard let engine = await Self.playingEngine() else { return }
        defer { engine.stop() }

        engine.beginScrubbing()
        engine.seekRelative(by: 2, exact: false)
        #expect(await engine.waitUntil { !engine.isSeeking })
        engine.pause()
        #expect(engine.pendingSeekTime == nil, "The landing was left as a seek still on its way")
        #expect(!engine.isPlaying)

        // Space twice while the arrow is still down (its repeats stopped by the other key).
        engine.play()
        #expect(await engine.waitForPlayback(advancingBy: 0.3), "Play waited for the arrow's release")
        engine.endScrubbing()
        #expect(await engine.waitForPlayback(advancingBy: 0.3))
    }

    @Test("A held key's presses are one burst, however long the system waits before repeating")
    func oneBurstAcrossTheRepeatDelay() async throws {
        guard let engine = await Self.playingEngine() else { return }
        defer { engine.stop() }

        engine.beginScrubbing()
        engine.seekRelative(by: 2)
        let burstStart = try #require(engine.relativeSeekBurst.startTime)
        // Past the burst timer (300 ms), as a long InitialKeyRepeat is.
        try await Task.sleep(for: PlayerEngine.relativeSeekBurstTimeout + .milliseconds(500))
        engine.seekRelative(by: 2)
        #expect(engine.relativeSeekBurst.startTime == burstStart, "The first repeat started a burst of its own")
        #expect(engine.chase?.exact == false, "The repeat seeked exactly, as a first press does")
        engine.endScrubbing()
        #expect(await engine.waitForPlayback(advancingBy: 0.3))
    }

    @Test("Held at the end, further presses forward start no seek")
    func heldAtTheEnd() async throws {
        guard let engine = await Self.playingEngine() else { return }
        defer { engine.stop() }

        engine.beginScrubbing()
        engine.seekRelative(by: engine.media.duration)
        #expect(await engine.waitUntil { !engine.isSeeking })
        let generation = engine.seekGeneration.current
        for _ in 0..<3 {
            engine.seekRelative(by: 2)
            #expect(!engine.isSeeking, "A press at the end seeked again")
        }
        #expect(engine.seekGeneration.current == generation)
        engine.endScrubbing()
    }

    @Test("A seek still in flight at the end resumes as it lands")
    func endBeforeLanding() async throws {
        guard let engine = await Self.playingEngine() else { return }
        defer { engine.stop() }

        engine.beginScrubbing()
        engine.seekRelative(by: 2, exact: false)
        engine.endScrubbing()
        #expect(await engine.waitForPlayback(advancingBy: 0.3), "Playback did not resume")
    }
}
