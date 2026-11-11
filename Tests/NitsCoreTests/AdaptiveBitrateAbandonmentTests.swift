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
