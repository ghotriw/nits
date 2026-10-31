import CoreMedia
import Testing

@testable import NitsCore

@Suite("Playback clock")
struct PlaybackClockTests {
    private static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 1000)
    }

    @Test("A clock asked to hold reads where it was asked to, applied or not")
    func holdReadsAtOnce() {
        let clock = PlaybackClock()
        clock.setRate(1, time: Self.seconds(50))
        clock.waitUntilApplied()

        clock.setRate(0, time: Self.seconds(3))
        #expect(clock.currentTime().seconds == 3)
        clock.waitUntilApplied()
        #expect(clock.currentTime().seconds == 3)
        #expect(clock.rate == 0)
    }

    @Test("A running clock asked to start elsewhere never reads the position it left")
    func startReadsAtItsStart() {
        let clock = PlaybackClock()
        clock.setRate(1, time: Self.seconds(50))
        clock.waitUntilApplied()
        #expect(clock.currentTime().seconds >= 50)

        clock.setRate(1, time: Self.seconds(5))
        // Queued, or applied with the synchronizer still on its way: either way the old position is not the clock.
        for _ in 0..<50 {
            let reading = clock.currentTime().seconds
            #expect(reading < 6, "Read \(reading)s, the position before the start")
        }
        clock.waitUntilApplied()
        #expect(clock.currentTime().seconds < 6)
    }

    /// No audio renderer is attached here, so a synchronizer that holds its clock back while the audio device starts
    /// is not exercised: the reading short of the start stands for it, and may differ on a live device.
    @Test("A start scheduled for a host time ahead never reads below its start, and never steps back")
    func scheduledStartDoesNotStepBack() async throws {
        let clock = PlaybackClock()
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let start = Self.seconds(10)
        clock.setRate(1, time: start, atHostTime: hostNow + CMTime(seconds: 0.15, preferredTimescale: 1_000_000_000))

        var previous = 0.0
        for _ in 0..<12 {
            let reading = clock.currentTime().seconds
            #expect(reading >= 10, "Read \(reading)s, before the start")
            #expect(reading >= previous, "Stepped back from \(previous)s to \(reading)s")
            previous = reading
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("A new rate before the start has settled is read from that start, not from the synchronizer")
    func rateChangeBeforeSettling() {
        let clock = PlaybackClock()
        clock.setRate(1, time: Self.seconds(50))
        clock.waitUntilApplied()

        clock.setRate(1, time: Self.seconds(5))
        clock.setRate(2, time: clock.currentTime(), keepsRunning: true)
        for _ in 0..<50 {
            let reading = clock.currentTime().seconds
            #expect(reading < 6, "Read \(reading)s, the position before the start")
        }
        clock.waitUntilApplied()
        #expect(clock.currentTime().seconds < 6)
    }

    @Test("A new rate at the running position keeps the clock running, without standing at the anchor")
    func rateChangeIsContinuous() async throws {
        let clock = PlaybackClock()
        clock.setRate(1, time: Self.seconds(20))
        clock.waitUntilApplied()
        try await Task.sleep(for: .milliseconds(400))
        let before = clock.currentTime()
        #expect(before.seconds > 20.2)

        clock.setRate(2, time: before, keepsRunning: true)
        // The change is queued, yet the clock is read as it runs: past the position of the request, not on it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(clock.currentTime().seconds > before.seconds)
    }
}
