import Foundation
import Testing

@testable import NitsCore

/// Repeated seeks (a held arrow key) resume playback after a wait that tells the burst from a single seek; the release
/// of the key (`endSeekBurst`) ends the wait.
@Suite("End of a seek burst", .serialized, .realtimePlayback, .hostDependent)
struct SeekBurstEndTests {
    /// Milliseconds from the last press (or `endSeekBurst()`, when `releases`) to the resume.
    @MainActor
    private static func resumeDelay(releasing releases: Bool) async -> Double? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return nil }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: path)
        guard engine.isLoaded, engine.media.duration > 40 else { return nil }
        engine.play()
        _ = await engine.waitForPlayback()
        try? await Task.sleep(for: .milliseconds(500))

        for _ in 0..<8 {
            engine.seekRelative(by: 5)
            try? await Task.sleep(for: .milliseconds(60))
        }
        let clock = ContinuousClock()
        let released = clock.now
        if releases { engine.endSeekBurst() }
        let deadline = clock.now + .seconds(3)
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
            if !engine.isSeeking, !engine.isAwaitingClockStart {
                let elapsed = clock.now - released
                return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            }
        }
        return nil
    }

    @Test("Releasing the key resumes playback before the burst's wait is over")
    @MainActor
    func releaseResumesAtOnce() async throws {
        let withRelease = try #require(await Self.resumeDelay(releasing: true))
        let withoutRelease = try #require(await Self.resumeDelay(releasing: false))
        // The control: without the release the wait is the debounce, less the time since the last landing.
        #expect(withoutRelease >= 200, "Without a release the resume took \(withoutRelease) ms: no wait to end")
        #expect(withRelease < withoutRelease - 100, "Release \(withRelease) ms, none \(withoutRelease) ms")
    }

    @Test("A release right after a single seek lands, while its resume flushes, loses no audio and shows no buffering")
    @MainActor
    func releaseDuringFlush() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        defer { engine.stop() }
        engine.load(path: path)
        guard engine.isLoaded, engine.media.duration > 40 else { return }
        engine.play()
        _ = await engine.waitForPlayback()

        for round in 0..<2 {
            try? await Task.sleep(for: .milliseconds(500))
            engine.seekRelative(by: round.isMultiple(of: 2) ? 5 : -5)
            _ = await engine.waitUntil { !engine.isSeeking }
            // The key release of the press, and more of them, through the flush the resume waits for.
            for _ in 0..<30 {
                engine.endSeekBurst()
                try? await Task.sleep(for: .milliseconds(1))
            }
            let startTime = engine.currentTime
            var buffered = false
            let deadline = ContinuousClock.now + .milliseconds(800)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                if engine.isBuffering { buffered = true }
            }
            #expect(!buffered, "Buffering showed after the release, round \(round)")
            #expect(engine.currentTime - startTime > 0.3, "The clock did not run, round \(round)")
            let audioEnd = engine.audioSink.bufferedEnd?.seconds ?? 0
            #expect(audioEnd > engine.currentTime, "The renderer holds no audio past the clock, round \(round)")
        }
    }
}
