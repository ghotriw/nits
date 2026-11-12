import Foundation
import Testing

@testable import NitsCore

@Suite("Abandoning a segment download")
struct AdaptiveBitrateAbandonmentTests {
    private static let ladder: [AdaptiveBitrateLogic.Variant] = [
        .init(id: 0, bandwidth: 500_000),
        .init(id: 1, bandwidth: 1_500_000),
        .init(id: 2, bandwidth: 5_000_000),
    ]

    /// A 6 s segment of the top variant (3.75 MB) after `elapsed` seconds on a link of `rate` bits a second, the first
    /// answer after 0.2 s.
    private static func download(
        variant: Int = 2, elapsed: Double, rate: Double, isSuspended: Bool = false
    ) -> AdaptiveBitrateLogic.Download {
        let streaming = max(elapsed - 0.2, 0)
        return .init(
            variant: variant, duration: 6, bytes: Int(streaming * rate / 8), length: 3_750_000, elapsed: elapsed,
            firstAnswer: 0.2, transferring: streaming, measuredBytes: Int(streaming * rate / 8),
            isSuspended: isSuspended)
    }

    @Test("A heavy start is given up for the variant the link carries")
    func heavyStart() throws {
        let logic = AdaptiveBitrateLogic()
        // 1 Mbit/s: the rest of 3.75 MB takes ~25 s, the 1.5 Mbit/s one 9.2 s (a stall that long), the lowest 3.2 s; nothing is buffered.
        let decision = try #require(
            logic.abandonment(
                of: Self.download(elapsed: 4, rate: 1_000_000), among: Self.ladder, buffer: 0, roundTrip: 0.2))
        // Nothing arrives within an empty buffer: the lowest, as hls.js (each second it loads is a second of stall).
        #expect(decision.target == 0)
        #expect(decision.remaining > 20)
        #expect(decision.lower < decision.remaining)
    }

    @Test("A drop with a buffer picks the highest variant that arrives before it runs out")
    func dropWithBuffer() throws {
        let logic = AdaptiveBitrateLogic()
        // 3 Mbit/s: the rest takes ~9 s against a buffer of 6; the 1.5 Mbit/s segment takes 3.2 s.
        let decision = try #require(
            logic.abandonment(
                of: Self.download(elapsed: 3.5, rate: 3_000_000), among: Self.ladder, buffer: 6, roundTrip: 0.2))
        #expect(decision.target == 1)
    }

    @Test("A download that finishes within the buffer is left")
    func fitsTheBuffer() {
        let logic = AdaptiveBitrateLogic()
        #expect(
            logic.abandonment(
                of: Self.download(elapsed: 3.5, rate: 3_000_000), among: Self.ladder, buffer: 12, roundTrip: 0.2)
                == nil)
    }

    @Test("Not before half of the segment's duration, nor when done, suspended or the lowest")
    func guards() {
        let logic = AdaptiveBitrateLogic()
        let slow = 1_000_000.0
        #expect(
            logic.abandonment(
                of: Self.download(elapsed: 2.9, rate: slow), among: Self.ladder, buffer: 0, roundTrip: 0.2)
                == nil)
        #expect(
            logic.abandonment(
                of: Self.download(elapsed: 4, rate: slow, isSuspended: true), among: Self.ladder, buffer: 0,
                roundTrip: 0.2) == nil)
        #expect(
            logic.abandonment(
                of: Self.download(variant: 0, elapsed: 4, rate: slow), among: Self.ladder, buffer: 0, roundTrip: 0.2)
                == nil)
        var done = Self.download(elapsed: 4, rate: slow)
        done.bytes = 3_750_000
        #expect(logic.abandonment(of: done, among: Self.ladder, buffer: 0, roundTrip: 0.2) == nil)
    }

    @Test("A lower segment that takes longer than finishing is no way out")
    func lowerIsNoFaster() {
        let logic = AdaptiveBitrateLogic()
        // Almost through: 3.7 of 3.75 MB; the rest takes a fraction of a second against 3 s for the lowest.
        var nearly = Self.download(elapsed: 4, rate: 1_000_000)
        nearly.bytes = 3_700_000
        #expect(logic.abandonment(of: nearly, among: Self.ladder, buffer: 0, roundTrip: 0.2) == nil)
    }
}

@Suite("Abandoning a segment download: what the rate is measured over")
struct AdaptiveBitrateAbandonmentRateTests {
    private static let ladder: [AdaptiveBitrateLogic.Variant] = [
        .init(id: 0, bandwidth: 500_000), .init(id: 1, bandwidth: 5_000_000),
    ]

    @Test("Bytes that came while the demuxer opened are no measure of the link")
    func openingBytesAreNotTheRate() throws {
        let logic = AdaptiveBitrateLogic()
        // 2 MB came, all of it in the opening, then nothing measured yet: no rate to decide with.
        let opening = AdaptiveBitrateLogic.Download(
            variant: 1, duration: 6, bytes: 2_000_000, length: 3_750_000, elapsed: 4, firstAnswer: 0.2,
            transferring: 0, measuredBytes: 0)
        #expect(logic.abandonment(of: opening, among: Self.ladder, buffer: 0, roundTrip: 0.2) == nil)
        // The same download once 100 KB came in 1 s past the opening: the rate is that, 0.8 Mbit/s.
        var past = opening
        past.transferring = 1
        past.measuredBytes = 100_000
        let decision = try #require(logic.abandonment(of: past, among: Self.ladder, buffer: 0, roundTrip: 0.2))
        #expect(decision.target == 0)
        #expect(abs(try #require(decision.loadRate) - 800_000) < 1)
    }

    @Test("Answered but no body yet: the estimate decides")
    func answeredWithoutBytes() throws {
        var logic = AdaptiveBitrateLogic()
        logic.addSample(bytes: 125_000, seconds: 1, media: 2, at: 0)  // 1 Mbit/s
        let waiting = AdaptiveBitrateLogic.Download(
            variant: 1, duration: 6, bytes: 0, length: 3_750_000, elapsed: 4, firstAnswer: 0.5, transferring: 0,
            measuredBytes: 0)
        let decision = try #require(logic.abandonment(of: waiting, among: Self.ladder, buffer: 0, roundTrip: 0.5))
        #expect(decision.target == 0)
        #expect(decision.loadRate == nil)
    }
}

@Suite("Abandoning a segment download: what is left to load")
struct AdaptiveBitrateAbandonmentExpectedTests {
    private static let ladder: [AdaptiveBitrateLogic.Variant] = [
        .init(id: 0, bandwidth: 500_000), .init(id: 1, bandwidth: 5_000_000),
    ]

    /// A 6 s segment of a 5 Mbit/s rung (3.75 MB by its bandwidth) that is `length` bytes, 4 s in at 1 Mbit/s.
    private static func download(length: Int64?) -> AdaptiveBitrateLogic.Download {
        .init(
            variant: 1, duration: 6, bytes: 475_000, length: length, elapsed: 4, firstAnswer: 0.2, transferring: 3.8,
            measuredBytes: 475_000)
    }

    @Test("The length the server told is what is left, not the bandwidth's peak")
    func lengthOverBandwidth() throws {
        let logic = AdaptiveBitrateLogic()
        // 1 MB in all: 4.2 s left against a buffer of 5 s. By the bandwidth (3.75 MB) it would be 26 s: given up.
        #expect(
            logic.abandonment(of: Self.download(length: 1_000_000), among: Self.ladder, buffer: 5, roundTrip: 0.2)
                == nil)
        let unknown = try #require(
            logic.abandonment(of: Self.download(length: nil), among: Self.ladder, buffer: 5, roundTrip: 0.2))
        #expect(unknown.remaining > 20)
    }

    @Test("A length larger than the bandwidth's is the larger")
    func lengthAboveBandwidth() throws {
        let logic = AdaptiveBitrateLogic()
        let decision = try #require(
            logic.abandonment(of: Self.download(length: 8_000_000), among: Self.ladder, buffer: 5, roundTrip: 0.2))
        #expect(abs(decision.remaining - (8_000_000 - 475_000) * 8 / 1_000_000.0) < 1)
    }

    @Test("A live stream's lower playlist load counts in the lower segment's time")
    func playlistLoad() throws {
        let logic = AdaptiveBitrateLogic()
        let plain = try #require(
            logic.abandonment(of: Self.download(length: 8_000_000), among: Self.ladder, buffer: 5, roundTrip: 0.2))
        let live = try #require(
            logic.abandonment(
                of: Self.download(length: 8_000_000), among: Self.ladder, buffer: 5, roundTrip: 0.2, playlistLoad: 0.4))
        #expect(abs(live.lower - plain.lower - 0.4) < 1e-9)
    }
}

@Suite("Abandoning a segment download: margin and pick")
struct AdaptiveBitrateAbandonmentMarginTests {
    private static let ladder: [AdaptiveBitrateLogic.Variant] = [
        .init(id: 0, bandwidth: 500_000), .init(id: 1, bandwidth: 1_500_000), .init(id: 2, bandwidth: 5_000_000),
    ]

    /// A 6 s segment of the top rung of `length` bytes, 4 s in at 2.5 Mbit/s (1.19 MB loaded).
    private static func download(length: Int64) -> AdaptiveBitrateLogic.Download {
        .init(
            variant: 2, duration: 6, bytes: 1_187_500, length: length, elapsed: 4, firstAnswer: 0.2, transferring: 3.8,
            measuredBytes: 1_187_500)
    }

    @Test("A lower segment that is barely sooner than finishing is no reason to throw the bytes away")
    func marginRefusesAGain() {
        let logic = AdaptiveBitrateLogic()
        // 2 s left; the lowest rung takes 1.4 s: 0.6 s for the bytes loaded and a fivefold drop in quality.
        #expect(
            logic.abandonment(of: Self.download(length: 1_812_500), among: Self.ladder, buffer: 1, roundTrip: 0.2)
                == nil)
    }

    @Test("With none within the buffer the lowest is picked, not a higher one that merely beats the download")
    func lowestWhenNoneFits() throws {
        let logic = AdaptiveBitrateLogic()
        // 6.4 s left at 2.5 Mbit/s; buffer 1 s. The 1.5 Mbit/s rung takes 3.8 s (3.8 s of stall), the lowest 1.4 s.
        let decision = try #require(
            logic.abandonment(of: Self.download(length: 3_187_500), among: Self.ladder, buffer: 1, roundTrip: 0.2))
        #expect(decision.target == 0)
        #expect(decision.lower < decision.remaining - 1)
    }

    @Test("One within the buffer is still the highest that fits it")
    func withinTheBuffer() throws {
        let logic = AdaptiveBitrateLogic()
        // Buffer of 5 s: the 1.5 Mbit/s rung (3.8 s) arrives in it, so it is the pick.
        let decision = try #require(
            logic.abandonment(of: Self.download(length: 3_187_500), among: Self.ladder, buffer: 5, roundTrip: 0.2))
        #expect(decision.target == 1)
    }
}

@Suite("Abandoning a segment download: what the logic does with it")
struct AdaptiveBitrateAbandonedStepTests {
    private static let ladder: [AdaptiveBitrateLogic.Variant] = [
        .init(id: 0, bandwidth: 500_000), .init(id: 1, bandwidth: 1_500_000), .init(id: 2, bandwidth: 5_000_000),
    ]

    private static func logic() -> AdaptiveBitrateLogic {
        var logic = AdaptiveBitrateLogic()
        for second in 0..<6 { logic.addSample(bytes: 500_000, seconds: 1, media: 1, at: Double(second)) }  // 4 Mbit/s
        return logic
    }

    @Test("A download given up counts as a step down: no step back up until the wait is over")
    func holdsOffAStepUp() {
        var fresh = Self.logic()
        // Standing on the lowest variant with a full read-ahead at 4 Mbit/s: it steps up.
        #expect(fresh.choose(current: 0, among: Self.ladder, readAhead: 25, at: 12) != nil)

        var abandoned = Self.logic()
        abandoned.noteAbandoned(at: 11)
        #expect(abandoned.choose(current: 0, among: Self.ladder, readAhead: 25, at: 12) == nil)
        // The wait is `upSwitchInterval` from the switch (10 s), and longer when it undid a recent step up.
        #expect(abandoned.choose(current: 0, among: Self.ladder, readAhead: 25, at: 22) != nil)
    }

    @Test("One that undoes a step up not yet held doubles the wait before the next")
    func doublesTheWaitAfterAFailedProbe() {
        var logic = Self.logic()
        // Stepped up, and given up at once: a failed probe (the step up is inside `failedProbeWindow`). The estimate is no
        // longer recent by then (it lives 20 s), so only the wait of a probe at a full read-ahead is left.
        _ = logic.choose(current: 0, among: Self.ladder, readAhead: 25, at: 12)
        logic.noteAbandoned(at: 13)
        #expect(
            logic.choose(current: 0, among: Self.ladder, readAhead: 25, at: 30) == nil, "17 s is not enough now: 20 are"
        )
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 25, at: 40) != nil)
    }

    /// What the top variant's download brought before it was given up: 1.2 Mbit/s for 4 s after the first answer.
    private static let slowDownload = AdaptiveBitrateLogic.Download(
        variant: 2, duration: 6, bytes: 600_000, length: 3_750_000, elapsed: 4.2, firstAnswer: 0.2, transferring: 4,
        measuredBytes: 600_000)

    @Test("An estimate of the link before the drop is set to what keeps the target, so it does not step back up")
    func estimateKeepsTheTarget() throws {
        // 40 Mbit/s measured before the drop: it would step up from the lowest variant at once, past what was given up.
        var logic = AdaptiveBitrateLogic()
        for second in 0..<6 { logic.addSample(bytes: 5_000_000, seconds: 1, media: 1, at: Double(second)) }
        logic.noteAbandoned(at: 10, download: Self.slowDownload, targetBandwidth: 500_000)
        let estimate = try #require(logic.estimate)
        // The target fits `safety`, no more than it `upSafety`.
        #expect(500_000 <= estimate * logic.config.safety + 1)
        #expect(1_500_000 > estimate * logic.config.upSafety)
        // Long past every wait, on the estimate alone it stays and does not come down further either.
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 15, at: 25) == nil)
    }

    @Test("An estimate that already holds the target is only given the download's sample")
    func lowEstimateIsKept() throws {
        // 0.6 Mbit/s, and the download given up brought 0.4: 0.7 of the estimate does not reach 0.5 Mbit/s, so nothing is
        // set; the slow sample lowers it.
        var logic = AdaptiveBitrateLogic()
        for second in 0..<6 { logic.addSample(bytes: 75_000, seconds: 1, media: 1, at: Double(second)) }
        let before = try #require(logic.estimate)
        let slower = AdaptiveBitrateLogic.Download(
            variant: 2, duration: 6, bytes: 200_000, length: 3_750_000, elapsed: 4.2, firstAnswer: 0.2,
            transferring: 4, measuredBytes: 200_000)
        logic.noteAbandoned(at: 10, download: slower, targetBandwidth: 500_000)
        let after = try #require(logic.estimate)
        #expect(after < before)
        #expect(abs(after - 500_000 / logic.config.safety) > 1_000, "Not set to the target's")
    }

    @Test("Nothing measured, no estimate is made up")
    func noEstimateIsMadeUp() {
        // No sample before, and the download brought nothing past its opening: still nothing measured.
        var logic = AdaptiveBitrateLogic()
        let nothing = AdaptiveBitrateLogic.Download(
            variant: 2, duration: 6, bytes: 0, length: 3_750_000, elapsed: 4.2, firstAnswer: nil, transferring: 0,
            measuredBytes: 0)
        logic.noteAbandoned(at: 10, download: nothing, targetBandwidth: 500_000)
        #expect(logic.estimate == nil)
        logic.noteAbandoned(at: 11, download: nil, targetBandwidth: 500_000)
        #expect(logic.estimate == nil)
    }
}

@Suite("Abandoning a segment download: back up after it")
struct AdaptiveBitrateDetourTests {
    /// `hlsLadder`'s rungs: 320x180 at 0.46 Mbit/s, 480x270 at 1.08, 640x360 at 2.86.
    private static let ladder: [AdaptiveBitrateLogic.Variant] = [
        .init(id: 0, bandwidth: 460_000, pixels: 320 * 180), .init(id: 1, bandwidth: 1_079_000, pixels: 480 * 270),
        .init(id: 2, bandwidth: 2_862_000, pixels: 640 * 360),
    ]

    /// The top variant's download given up at 1 s for `target` (the lowest unless told), then `rate` bits a second measured
    /// each second to `until`, three seconds of media a second (the lowest reads so fast on 1.5 Mbit/s).
    private static func givenUp(
        rate: Int, until: Int, target: Int = 460_000, from abandoned: Int = 2_862_000
    ) -> AdaptiveBitrateLogic {
        var logic = AdaptiveBitrateLogic()
        logic.addSample(bytes: rate / 8, seconds: 1, media: 1, at: 0)
        logic.noteAbandoned(at: 1, targetBandwidth: target, abandonedBandwidth: abandoned)
        for second in 2...until { logic.addSample(bytes: rate / 8, seconds: 1, media: 3, at: Double(second)) }
        return logic
    }

    @Test("A link in the band between keeping and stepping up to a variant goes back to it once the read-ahead holds")
    func stepsBackToWhatTheLinkCarries() throws {
        var logic = Self.givenUp(rate: 1_500_000, until: 8)
        let estimate = try #require(logic.estimate)
        // 480 is kept on 1.5 Mbit/s (0.95) but not stepped up to (0.7): the ordinary rules leave it on 320.
        #expect(1_079_000 > estimate * logic.config.upSafety)
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 6, at: 8) == nil, "Not before 10 s read ahead")
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 12, at: 8) == 1)
        #expect(logic.detour == nil, "A step up ends it")
    }

    @Test("Never back to the variant given up, however fast the link looks")
    func staysBelowTheVariantGivenUp() throws {
        // 640 given up for 480; then 3.7 Mbit/s, which `probeSafety` takes for enough for 640 and `upSafety` not.
        var logic = Self.givenUp(rate: 3_700_000, until: 14, target: 1_079_000)
        let estimate = try #require(logic.estimate)
        #expect(2_862_000 <= estimate * logic.config.probeSafety)
        #expect(2_862_000 > estimate * logic.config.upSafety)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 12, at: 14) == nil)
    }

    @Test("Not at a live edge, whose read-ahead is raised to stand for a full one, nor after a seek")
    func needsARealReadAhead() {
        var live = Self.givenUp(rate: 1_500_000, until: 8)
        #expect(live.choose(current: 0, among: Self.ladder, readAhead: 20, isReadAheadReal: false, at: 8) == nil)
        var sought = Self.givenUp(rate: 1_500_000, until: 8)
        sought.endDetour()
        #expect(sought.choose(current: 0, among: Self.ladder, readAhead: 12, at: 8) == nil)
    }

    @Test("Only on an estimate measured since the give-up, and not long after it")
    func needsAFreshEstimateSoon() {
        // An estimate from before the give-up (recent, and here left as it was) is no measure since: nothing done.
        var unmeasured = AdaptiveBitrateLogic()
        for second in 0..<6 { unmeasured.addSample(bytes: 1_500_000 / 8, seconds: 1, media: 1, at: Double(second)) }
        unmeasured.noteAbandoned(at: 6, abandonedBandwidth: 2_862_000)
        #expect(unmeasured.choose(current: 0, among: Self.ladder, readAhead: 12, at: 9) == nil)
        // Past `failedProbeWindow` (60 s) the give-up is history: the ordinary rules (here the probe at 20 s) decide.
        var late = Self.givenUp(rate: 1_500_000, until: 70)
        #expect(late.choose(current: 0, among: Self.ladder, readAhead: 12, at: 70) == nil)
        #expect(late.detour == nil)
    }

    @Test("Back up is a step up: given up again soon after, the next wait doubles")
    func isAStepUp() {
        var logic = Self.givenUp(rate: 1_500_000, until: 8)
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 12, at: 8) == 1)
        logic.noteAbandoned(at: 9, targetBandwidth: 460_000, abandonedBandwidth: 1_079_000)
        for second in 10...14 { logic.addSample(bytes: 1_500_000 / 8, seconds: 1, media: 1, at: Double(second)) }
        // Below 480 now, and 4 s (twice `downSwitchInterval`) after the give-up.
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 12, at: 12) == nil, "3 s is not enough now")
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 12, at: 14) == nil, "Not 480: it was given up")
    }
}
