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

    /// A second of transfer at `bitsPerSecond`.
    private static func measure(
        _ logic: inout AdaptiveBitrateLogic, bitsPerSecond: Double, seconds: Int, at start: Double
    ) {
        for second in 0..<seconds {
            logic.addSample(bytes: Int(bitsPerSecond / 8), seconds: 1, at: start + Double(second))
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

    @Test("Stepping up needs a full read-ahead and time since the last switch")
    func stepsUp() {
        var logic = AdaptiveBitrateLogic()
        Self.measure(&logic, bitsPerSecond: 10_000_000, seconds: 10, at: 0)
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 15, at: 10) == nil)
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 25, at: 10) == 2)
        // Just switched: no step up for `upSwitchInterval`.
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 25, at: 15) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 25, at: 21) == 2)
    }

    @Test("Without a recent estimate a full read-ahead steps up one variant at a time")
    func probesUp() {
        var logic = AdaptiveBitrateLogic()
        #expect(logic.choose(current: 0, among: Self.ladder, readAhead: 30, at: 0) == 1)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 5) == nil)
        #expect(logic.choose(current: 1, among: Self.ladder, readAhead: 30, at: 11) == 2)
        #expect(logic.choose(current: 2, among: Self.ladder, readAhead: 30, at: 30) == nil)

        // An estimate older than `estimateLifetime` counts as none.
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
