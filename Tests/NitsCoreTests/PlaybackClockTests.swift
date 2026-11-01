import CoreMedia
import QuartzCore
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

    // MARK: - Provisional clock

    @Test("A provisional clock runs on host time at once, with the synchronizer held")
    func provisionalRunsAtOnce() async throws {
        let clock = PlaybackClock()
        clock.startProvisional(at: Self.seconds(100), rate: 1)
        #expect(clock.isProvisional)
        #expect(clock.rate == 1)
        let hostBefore = CACurrentMediaTime()
        let first = clock.currentTime().seconds
        #expect(first >= 100 && first < 100.05)
        try await Task.sleep(for: .milliseconds(200))
        let later = clock.currentTime().seconds
        // Against the host time that passed (a loaded machine stretches a sleep), not the sleep.
        let elapsed = CACurrentMediaTime() - hostBefore
        #expect(abs((later - first) - elapsed) < 0.05, "Moved \(later - first)s in \(elapsed)s")
        clock.waitUntilApplied()
        #expect(CMTimebaseGetRate(clock.synchronizer.timebase) == 0)
    }

    @Test("A new rate before the join takes over goes on from the position, at the new rate")
    func provisionalRateChange() async throws {
        let clock = PlaybackClock()
        clock.startProvisional(at: Self.seconds(10), rate: 1)
        try await Task.sleep(for: .milliseconds(100))
        let before = clock.currentTime().seconds
        #expect(clock.changeProvisionalRate(to: 2))
        #expect(clock.isProvisional)
        #expect(clock.readRate == 2)
        let after = clock.currentTime().seconds
        let hostAfter = CACurrentMediaTime()
        #expect(abs(after - before) < 0.05, "Stepped from \(before)s to \(after)s")
        try await Task.sleep(for: .milliseconds(200))
        let moved = clock.currentTime().seconds - after
        let elapsed = CACurrentMediaTime() - hostAfter
        #expect(abs(moved - 2 * elapsed) < 0.1, "Moved \(moved)s in \(elapsed)s at 2x")
    }

    @Test("The join takes the position over at its host time without a step")
    func handOverDoesNotStep() async throws {
        let clock = PlaybackClock()
        clock.startProvisional(at: Self.seconds(10), rate: 1)
        try await Task.sleep(for: .milliseconds(50))
        let host = try #require(clock.handOver(after: 0.1))
        var previous = clock.currentTime().seconds
        while CACurrentMediaTime() < host + 0.6 {
            try await Task.sleep(for: .milliseconds(5))
            let reading = clock.currentTime().seconds
            #expect(reading >= previous - 0.002, "Stepped back from \(previous)s to \(reading)s")
            previous = reading
        }
        // Past the take-over the synchronizer is the clock.
        #expect(!clock.isProvisional)
        #expect(clock.rate == 1)
    }

    @Test("A hold or a new start replaces a provisional clock, and it cannot be joined or re-rated then")
    func provisionalEndsWithTheNextChange() {
        let clock = PlaybackClock()
        clock.startProvisional(at: Self.seconds(10), rate: 1)
        clock.setRate(0, time: Self.seconds(12))
        #expect(!clock.isProvisional)
        #expect(clock.currentTime().seconds == 12)
        #expect(clock.handOver(after: 0.1) == nil)
        #expect(!clock.changeProvisionalRate(to: 2))
    }
}
