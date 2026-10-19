import Foundation
import Testing

@testable import NitsCore

@Suite("Audio renderer lag detector")
struct AudioLagDetectorTests {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    @Test("Re-anchors once due audio has been held back for the recovery delay")
    func recoversAfterDelay() {
        var detector = AudioLagDetector()
        #expect(detector.observe(isLagging: true, at: at(0)) == nil)
        #expect(detector.observe(isLagging: true, at: at(450)) == nil)
        #expect(detector.observe(isLagging: true, at: at(500)) == .milliseconds(500))
        // The hold starts over after a re-anchor.
        #expect(detector.lagSince == nil)
    }

    @Test("A renderer taking audio in time in between starts the hold over")
    func shortHoldsDoNotAddUp() {
        var detector = AudioLagDetector()
        #expect(detector.observe(isLagging: true, at: at(0)) == nil)
        #expect(detector.observe(isLagging: false, at: at(400)) == nil)
        #expect(detector.observe(isLagging: true, at: at(450)) == nil)
        #expect(detector.observe(isLagging: true, at: at(900)) == nil)
        #expect(detector.observe(isLagging: true, at: at(950)) == .milliseconds(500))
    }

    @Test("A hold seen before the clock stopped does not count after it restarts")
    func clockRestartForgetsHold() {
        var detector = AudioLagDetector()
        #expect(detector.observe(isLagging: true, at: at(0)) == nil)
        // Paused for ten seconds, then resumed with the renderer briefly holding back audio.
        detector.clockRestarted()
        #expect(detector.observe(isLagging: true, at: at(10_000)) == nil)
        #expect(detector.observe(isLagging: true, at: at(10_500)) == .milliseconds(500))
    }

    @Test("Re-anchors at most once per cooldown while the renderer stays behind")
    func cooldownLimitsRecoveries() {
        var detector = AudioLagDetector()
        #expect(detector.observe(isLagging: true, at: at(0)) == nil)
        #expect(detector.observe(isLagging: true, at: at(500)) != nil)
        #expect(detector.observe(isLagging: true, at: at(600)) == nil)
        #expect(detector.observe(isLagging: true, at: at(1_100)) == nil)
        // Still held back when the cooldown runs out: re-anchors at once, counting the whole hold.
        #expect(detector.observe(isLagging: true, at: at(5_500)) == .milliseconds(4_900))
    }
}
