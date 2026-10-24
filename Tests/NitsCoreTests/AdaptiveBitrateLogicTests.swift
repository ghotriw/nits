import Foundation
import Testing

@testable import NitsCore

@Suite("Adaptive bitrate logic")
struct AdaptiveBitrateLogicTests {
    private static let ladder: [AdaptiveBitrateLogic.Variant] = [
        .init(id: 2, bandwidth: 5_000_000),
        .init(id: 0, bandwidth: 500_000),
        .init(id: 1, bandwidth: 1_500_000),
    ]

    /// A second of transfer at `bitsPerSecond`, reading a second of media.
    private static func measure(
        _ logic: inout AdaptiveBitrateLogic, bitsPerSecond: Double, seconds: Int, at start: Double
    ) {
        for second in 0..<seconds {
            logic.addSample(bytes: Int(bitsPerSecond / 8), seconds: 1, media: 1, at: start + Double(second))
        }
    }

    @Test("The estimate follows a steady rate, falls quickly and rises slowly")
    func estimate() throws {
        var logic = AdaptiveBitrateLogic()
        #expect(logic.estimate == nil)
        Self.measure(&logic, bitsPerSecond: 4_000_000, seconds: 1, at: 0)
        #expect(abs(try #require(logic.estimate) - 4_000_000) < 1)

        Self.measure(&logic, bitsPerSecond: 1_000_000, seconds: 2, at: 1)
        let fallen = try #require(logic.estimate)
        #expect(fallen < 2_600_000, "\(fallen)")

        Self.measure(&logic, bitsPerSecond: 4_000_000, seconds: 2, at: 3)
        let risen = try #require(logic.estimate)
        // The slow average holds it back: still well below the rate it went back to.
        #expect(risen < 3_000_000 && risen > fallen, "\(risen)")
    }

    @Test("A variant that doesn't fit is left for the highest that does, unless the read-ahead is full")
    func stepsDown() {
        var logic = AdaptiveBitrateLogic()
        Self.measure(&logic, bitsPerSecond: 2_500_000, seconds: 10, at: 0)
        // 1.5 Mbit/s fits 80 % of 2.5 Mbit/s; 5 Mbit/s doesn't.
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 30, at: 10) == nil)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 15, at: 10) == 1)
        // A read-ahead still filling (start, seek) is no reason to go lower than what fits.
        var starting = AdaptiveBitrateLogic()
        Self.measure(&starting, bitsPerSecond: 2_500_000, seconds: 1, at: 0)
        #expect(starting.choose(current: 2, among: Self.ladder, readAhead: 0.5, at: 1) == 1)
    }

    @Test("The requests' latency per second of media takes its share of the time a variant may read in")
    func latencyShare() throws {
        var logic = AdaptiveBitrateLogic()
        // 10 Mbit/s, and half a second of waiting for answers per second of media read (a second per 2-second
        // segment): 5 Mbit/s would read a second in 0.5 s plus 0.5 s, over `safety`; 1.5 Mbit/s in 0.15 s plus 0.5 s.
        for second in 0..<10 {
            logic.addSample(bytes: 10_000_000 / 8, seconds: 1, media: 1, at: Double(second))
            logic.addLatency(1, media: 2)
        }
        #expect(abs(try #require(logic.latencyShare) - 0.5) < 0.001)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 10, at: 10) == 1)
        // Without latency, 5 Mbit/s fits 10.
        var quick = AdaptiveBitrateLogic()
        Self.measure(&quick, bitsPerSecond: 10_000_000, seconds: 10, at: 0)
        #expect(quick.choose(current: 2, among: Self.ladder, readAhead: 10, at: 10) == nil)
    }

    @Test("The latency share counts from `minimumLatencyMedia` of media read on")
    func latencyShareNeedsMedia() {
        var logic = AdaptiveBitrateLogic()
        Self.measure(&logic, bitsPerSecond: 10_000_000, seconds: 10, at: 0)
        // Reading starts with requests answered ahead of their media: two of a second each, before 4 s are read.
        logic.addLatency(2, media: 0)
        logic.addLatency(0, media: 4)
        #expect(logic.latencyShare == nil)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 10, at: 10) == nil)
        logic.addLatency(1, media: 3)
        #expect(logic.latencyShare != nil)
    }

    @Test("Answers slower than `safety` of the media bring the variant down to the lowest, without an estimate too")
    func latencyBoundComesDown() {
        var logic = AdaptiveBitrateLogic()
        for _ in 0..<5 { logic.addLatency(2, media: 2) }
        #expect(logic.estimate == nil)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 10, at: 10) == 0)
        // Nor does a full read-ahead probe up from there.
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 30, at: 30) == nil)
    }

    @Test("A sample weighs the media it read: one read fast outweighs a slow start")
    func fastReadsWeighTheirMedia() throws {
        var logic = AdaptiveBitrateLogic()
        Self.measure(&logic, bitsPerSecond: 600_000, seconds: 5, at: 0)
        // The network got faster: 10 s of media at 10 Mbit/s, in 0.4 s. Weighed by those 0.4 s, the slow average
        // kept 97 % of the start's 0.6 Mbit/s.
        logic.addSample(bytes: 500_000, seconds: 0.4, media: 10, at: 6)
        let estimate = try #require(logic.estimate)
        #expect(estimate > 7_000_000, "\(estimate)")
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 30, at: 10) == 2)
    }

    @Test("A sample without media weighs its seconds")
    func samplesWithoutMediaWeighTheirSeconds() throws {
        var logic = AdaptiveBitrateLogic()
        Self.measure(&logic, bitsPerSecond: 10_000_000, seconds: 10, at: 0)
        // 4 s at 0.5 Mbit/s of a stream whose bandwidth isn't known: two fast half-lives.
        logic.addSample(bytes: 250_000, seconds: 4, media: 0, at: 14)
        let estimate = try #require(logic.estimate)
        #expect(estimate < 3_000_000, "\(estimate)")
    }

    @Test("A request's sample weighs its media alone: a small one slow to start neither makes nor sways the estimate")
    func requestsWeighTheirMedia() throws {
        // A 39 Mbit/s variant. Half a megabyte of audio in 0.8 s (5.7 Mbit/s, TCP's slow start) is 0.12 s of it:
        // no estimate yet, where weighed by its seconds it was one, and the variant came down.
        var logic = AdaptiveBitrateLogic()
        let bandwidth = 39_000_000.0
        logic.addSample(bytes: 574_648, seconds: 0.8, media: 574_648 * 8 / bandwidth, at: 0)
        #expect(logic.estimate == nil)
        // A 4K segment of 10 MB in 0.9 s (90 Mbit/s) outweighs it.
        logic.addSample(bytes: 9_935_312, seconds: 0.886, media: 9_935_312 * 8 / bandwidth, at: 1)
        let estimate = try #require(logic.estimate)
        #expect(estimate > 60_000_000, "\(estimate)")
    }

    @Test("A probe that comes down soon doubles the wait before the next")
    func backsOffFailedProbes() {
        var config = AdaptiveBitrateLogic.Config()
        config.estimateLifetime = 5
        var logic = AdaptiveBitrateLogic(config: config)
        // Probe up from 1.5 to 5 Mbit/s, then measure 2.5 Mbit/s: back down at 11 s.
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 0) == 2)
        Self.measure(&logic, bitsPerSecond: 2_500_000, seconds: 10, at: 1)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 15, at: 11) == 1)
        // The estimate is old from 15 s; the next probe waits 20 s after the switch, not 10.
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 22) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 30) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 31.5) == 2)
    }

    @Test("A recent estimate steps up from `estimateUpBuffer` of read-ahead, to what it fits with `upSafety`")
    func stepsUpOnAnEstimate() {
        var logic = AdaptiveBitrateLogic()
        // 10 Mbit/s: 0.7 of it fits 5 Mbit/s.
        Self.measure(&logic, bitsPerSecond: 10_000_000, seconds: 10, at: 0)
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 8, at: 10) == nil)
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 10, at: 10) == 2)
        // Just switched: no step up for `downSwitchInterval`.
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 15, at: 11) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 15, at: 12.5) == 2)
    }

    @Test("Between `upSafety` and `safety` of the estimate a variant is kept, but not stepped up to")
    func holdsBetweenTheSafeties() {
        var logic = AdaptiveBitrateLogic()
        // 6.6 Mbit/s: 5 Mbit/s takes 0.76 of it, within 0.95, over 0.7.
        Self.measure(&logic, bitsPerSecond: 6_600_000, seconds: 10, at: 0)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 5, at: 10) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 15, at: 10) == nil)
        // A full read-ahead, long after a switch, doesn't probe past what a recent estimate fits either.
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 25, at: 19) == nil)
    }

    @Test("Without a recent estimate a full read-ahead steps up one variant at a time")
    func probesUp() {
        var logic = AdaptiveBitrateLogic()
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 30, at: 0) == 1)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 5) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 11) == 2)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 30, at: 30) == nil)

        // A recent estimate that fits nothing higher stands; one older than `estimateLifetime` counts as none.
        var stale = AdaptiveBitrateLogic()
        Self.measure(&stale, bitsPerSecond: 600_000, seconds: 5, at: 0)
        #expect(stale.choose(current: 0, among: Self.ladder, readAhead: 30, at: 10) == nil)
        #expect(stale.choose(current: 0, among: Self.ladder, readAhead: 30, at: 40) == 1)
    }

    @Test("Probes that keep failing wait up to `maxProbeBackoff` times as long, until one holds")
    func backoffGrowsToItsLimit() {
        var config = AdaptiveBitrateLogic.Config()
        config.estimateLifetime = 1
        var logic = AdaptiveBitrateLogic(config: config)
        /// Probes up at `up` (no recent estimate), then measures 2.5 Mbit/s and comes down 3 s later.
        func failedProbe(at up: Double) {
            #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: up) == 2, "probe at \(up)")
            Self.measure(&logic, bitsPerSecond: 2_500_000, seconds: 2, at: up + 1)
            #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 15, at: up + 3) == 1, "down at \(up + 3)")
        }
        failedProbe(at: 0)  // waits 20 s after
        failedProbe(at: 23)  // 40 s
        failedProbe(at: 66)  // 80 s, from 69
        // Over a minute since the last probe, which failed: still waiting.
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 140) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 150) == 2)
        // That probe holds for over a minute; when the network drops later, the next probe waits 10 s again.
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 30, at: 211) == nil)
        Self.measure(&logic, bitsPerSecond: 2_500_000, seconds: 1, at: 214)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 15, at: 215) == 1)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 224) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 226) == 2)
    }

    @Test("Down switches wait `downSwitchInterval` after any switch")
    func downInterval() {
        var logic = AdaptiveBitrateLogic()
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 0) == 2)
        Self.measure(&logic, bitsPerSecond: 1_000_000, seconds: 1, at: 0)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 10, at: 1) == nil)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 10, at: 2) == 0)
    }

    @Test("A single variant, or one not in the list, is left alone")
    func nothingToChoose() {
        var logic = AdaptiveBitrateLogic()
        #expect(logic.choose(current: 0, among: [Self.ladder[1]], readAhead: 30, at: 0) == nil)
        #expect(logic.choose(current: 9, among: Self.ladder, readAhead: 30, at: 0) == nil)
    }
}
