import CoreMedia
import Testing

@testable import NitsCore

/// When a seek's audio join flushes the renderer: only when what it holds reaches past where the new audio starts. A
/// flush restarts the output's IO on some routes (multichannel to AirPods, ~0.5 s), and audio that ends before the start
/// is dropped as late by the synchronizer anyway.
@Suite("Audio join flush rule")
struct AudioJoinFlushTests {
    private static func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 1_000_000) }

    private static func needsFlush(
        end: Double?, startsAt: Double, owed: Bool = false, pending: Bool = false
    ) -> Bool {
        AudioJoin.needsFlush(
            bufferedEnd: end.map(seconds), startsAt: seconds(startsAt), isFlushOwed: owed, isEnqueuePending: pending)
    }

    @Test("An empty renderer is not flushed")
    func empty() {
        #expect(!Self.needsFlush(end: nil, startsAt: 10))
    }

    @Test("A seek forward past the audio fed keeps the renderer")
    func forwardPastFed() {
        // Playing at 100 s with 2 s fed; a seek to 160 s.
        #expect(!Self.needsFlush(end: 102, startsAt: 160.17))
        // Ending exactly at the start: nothing reaches past it.
        #expect(!Self.needsFlush(end: 160.17, startsAt: 160.17))
    }

    @Test("A seek back, or forward within the audio fed, flushes")
    func reachesPast() {
        #expect(Self.needsFlush(end: 102, startsAt: 40.17))
        #expect(Self.needsFlush(end: 102, startsAt: 101.2))
    }

    @Test("A flush owed or an enqueue in flight flushes")
    func owedOrPending() {
        #expect(Self.needsFlush(end: nil, startsAt: 10, owed: true))
        #expect(Self.needsFlush(end: 2, startsAt: 10, pending: true))
    }

    @Test("A position that is not a number flushes")
    func indefinite() {
        #expect(
            AudioJoin.needsFlush(
                bufferedEnd: Self.seconds(5), startsAt: .invalid, isFlushOwed: false, isEnqueuePending: false))
    }
}
