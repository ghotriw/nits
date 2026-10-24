import Foundation
import Testing

@testable import NitsCore

/// Sequences follow the system-log captures of 2026-10-23/24 on AirPods (`.agents/bluetooth-startup-audio-desync.md`).
@Suite("Audio output interruption detector")
struct AudioOutputInterruptionDetectorTests {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    /// Feeds `events` (`isRunning`, clock rate, milliseconds) and returns which of them asked for a re-anchor.
    private func feed(_ detector: inout AudioOutputInterruptionDetector, _ events: [(Bool, Double, Int)]) -> [Bool] {
        events.map { isRunning, rate, milliseconds in
            detector.deviceRunningChanged(isRunning: isRunning, rate: rate, at: at(milliseconds)) != nil
        }
    }

    private func confirm(
        _ detector: inout AudioOutputInterruptionDetector, _ generation: UInt64, _ milliseconds: Int
    ) -> Bool {
        detector.confirmRecovery(generation: generation, at: at(milliseconds))
    }

    /// Stops the device just before `from` (a run from before the clock start doesn't count), runs it on the
    /// placeholder from `from` for `ranFor`, stops it, and runs it again 0.6 s later; returns the clock generation asked
    /// to re-anchor, if any.
    private func placeholderSwitch(
        _ detector: inout AudioOutputInterruptionDetector, from: Int, ranFor: Int = 200
    ) -> UInt64? {
        _ = detector.deviceRunningChanged(isRunning: false, rate: 1, at: at(from - 5))
        _ = detector.deviceRunningChanged(isRunning: true, rate: 1, at: at(from))
        _ = detector.deviceRunningChanged(isRunning: false, rate: 1, at: at(from + ranFor))
        return detector.deviceRunningChanged(isRunning: true, rate: 1, at: at(from + ranFor + 600))
    }

    @Test(
        "IO stopping after a run on the placeholder re-anchors once the device runs again", arguments: [111, 192, 321])
    func placeholderSwitch(ranFor milliseconds: Int) {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        // The clock may or may not be moving yet when the IO stops: the synchronizer can hold it after the queue started.
        let results = feed(&detector, [(true, 1, 90), (false, 1, 90 + milliseconds), (false, 1, 95 + milliseconds)])
        #expect(results == [false, false, false])
        #expect(detector.isInterrupted)
        let generation = detector.deviceRunningChanged(isRunning: true, rate: 1, at: at(milliseconds + 700))
        #expect(generation == detector.clockGeneration)
        #expect(feed(&detector, [(true, 1, milliseconds + 701)]) == [false])
        let current = detector.clockGeneration
        #expect(confirm(&detector, current, milliseconds + 710))
    }

    @Test("IO restarting within the queue start is a healthy start", arguments: [6, 11])
    func restartWithinQueueStart(ranFor milliseconds: Int) {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        // The HAL repeats the stop.
        let events = [
            (true, 1.0, 10), (false, 1.0, 10 + milliseconds), (false, 1.0, 14 + milliseconds), (true, 1.0, 550),
        ]
        #expect(feed(&detector, events) == [false, false, false, false])
        #expect(!detector.isInterrupted)
    }

    @Test("The stop of a run that began before the clock started does not count")
    func earlierRunDoesNotCount() {
        var detector = AudioOutputInterruptionDetector()
        // The previous media's (or another player's) queue ran the device; its stop arrives after the new clock start.
        #expect(feed(&detector, [(true, 1, 0)]) == [false])
        detector.clockStopped()
        detector.clockStarted(at: at(5000))
        #expect(feed(&detector, [(false, 1, 5050), (true, 1, 5600)]) == [false, false])
        #expect(!detector.isInterrupted)
    }

    @Test("A seek or buffering stops the clock before the device")
    func ownStopsDoNotCount() {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        #expect(feed(&detector, [(true, 1, 100)]) == [false])
        detector.clockStopped()
        // Delivered after the clock ran again: the run began before that start.
        detector.clockStarted(at: at(2400))
        #expect(feed(&detector, [(false, 1, 2500), (true, 1, 3240)]) == [false, false])
        #expect(!detector.isInterrupted)
    }

    @Test("A stop with the clock not started or stopped elsewhere does not count")
    func stoppedClockDoesNotCount() {
        var detector = AudioOutputInterruptionDetector()
        #expect(feed(&detector, [(true, 1, 0), (false, 1, 500)]) == [false, false])
        detector.clockStarted(at: at(900))
        #expect(feed(&detector, [(true, 0, 1000), (false, 0, 1500)]) == [false, false])
        #expect(!detector.isInterrupted)
    }

    @Test("A rate change while the device is stopped keeps the interruption")
    func rateChangeKeepsInterruption() {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        _ = feed(&detector, [(true, 1, 90), (false, 1, 300)])
        // `startSynchronizerClock` with the clock running: same start, same generation.
        detector.clockStarted(at: at(500))
        #expect(detector.isInterrupted)
        #expect(feed(&detector, [(true, 1.5, 900)]) == [true])
    }

    @Test("A new output device starts over: a short restart on it is not an interruption")
    func outputDeviceChange() {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        #expect(feed(&detector, [(true, 1, 90)]) == [false])
        detector.outputDeviceChanged()
        let results = feed(&detector, [(true, 1, 5000), (false, 1, 5010), (true, 1, 5400)])
        #expect(results == [false, false, false])
    }

    @Test("The engine's own renderer flush under the running clock is not an interruption")
    func rendererFlush() {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        #expect(feed(&detector, [(true, 1, 90)]) == [false])
        // An audio delay change 1.3 s in: the queue restarts and the device's IO with it, the clock keeps going.
        detector.rendererFlushed()
        #expect(feed(&detector, [(false, 1, 1400), (true, 1, 1490)]) == [false, false])
        #expect(!detector.isInterrupted)
        // The run the flushed queue started still counts.
        #expect(feed(&detector, [(false, 1, 1700), (true, 1, 2300)]) == [false, true])
    }

    @Test("A clock stop between the IO stop and restart drops the interruption")
    func clockStopClearsInterruption() {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        _ = feed(&detector, [(true, 1, 10), (false, 1, 200)])
        #expect(detector.isInterrupted)
        detector.clockStopped()
        #expect(feed(&detector, [(true, 1, 900)]) == [false])
    }

    @Test("A recovery decided for an earlier clock start is not carried out")
    func staleRecovery() throws {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        let generation = try #require(placeholderSwitch(&detector, from: 90))
        // A pause and resume before the main actor got to it.
        detector.clockStopped()
        detector.clockStarted(at: at(950))
        #expect(!confirm(&detector, generation, 960))
    }

    @Test("A recovery not carried out leaves the cooldown untouched")
    func rejectedRecoveryKeepsCooldown() throws {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        let stale = try #require(placeholderSwitch(&detector, from: 90))
        detector.clockStopped()
        #expect(!confirm(&detector, stale, 900))
        // The clock start that ends the buffering, then another interruption: within 5 s of the rejected one.
        detector.clockStarted(at: at(1000))
        let generation = try #require(placeholderSwitch(&detector, from: 1100))
        #expect(confirm(&detector, generation, 1910))
    }

    @Test("Re-anchors at most once per cooldown while the device keeps restarting")
    func cooldown() throws {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        let first = try #require(placeholderSwitch(&detector, from: 10))
        #expect(confirm(&detector, first, 820))
        // A re-anchor stops and starts the clock again.
        detector.clockStopped()
        detector.clockStarted(at: at(820))
        let second = try #require(placeholderSwitch(&detector, from: 900))
        #expect(!confirm(&detector, second, 1710))
        detector.clockStopped()
        detector.clockStarted(at: at(1710))
        let third = try #require(placeholderSwitch(&detector, from: 6000))
        #expect(confirm(&detector, third, 6810))
    }

    @Test("Loading media forgets the cooldown and drops a recovery on its way")
    func reset() throws {
        var detector = AudioOutputInterruptionDetector()
        detector.clockStarted(at: at(0))
        let first = try #require(placeholderSwitch(&detector, from: 10))
        #expect(confirm(&detector, first, 820))
        let pending = try #require(placeholderSwitch(&detector, from: 900))
        detector.reset()
        detector.clockStarted(at: at(2000))
        #expect(!confirm(&detector, pending, 2010))
        // The new media's start interruption, within 5 s of the old media's recovery.
        let generation = try #require(placeholderSwitch(&detector, from: 2090))
        #expect(confirm(&detector, generation, 2900))
    }
}
