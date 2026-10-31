import Testing

@testable import NitsCore

@Suite("Chase settling")
struct ChaseSettlingTests {
    @Test("A seek on its own resumes at once; one following another within the debounce waits for it")
    func burstDetection() {
        var settling = ChaseSettling()
        let start = ContinuousClock.now

        settling.noteRequest(at: start)
        #expect(settling.resumeDelay == .zero)

        settling.noteRequest(at: start + .milliseconds(60))
        #expect(settling.resumeDelay == ChaseSettling.burstDebounce)

        settling.noteRequest(at: start + .milliseconds(60) + ChaseSettling.burstDebounce + .milliseconds(1))
        #expect(settling.resumeDelay == .zero)
    }

    @Test("A resume past its wait cannot be restarted, one still waiting can")
    func committedResume() {
        var settling = ChaseSettling()
        let first = settling.beginSettle()
        #expect(!settling.isSettleCommitted)

        settling.commitSettle(first)
        #expect(settling.isSettleCommitted)

        settling.endSettle(first)
        #expect(!settling.isSettleCommitted)
    }

    @Test("A newer resume or a newer seek lifts the commitment, and a stale resume cannot set it again")
    func supersededResume() {
        var settling = ChaseSettling()
        let stale = settling.beginSettle()
        settling.commitSettle(stale)

        settling.abandonSettle()
        #expect(!settling.isSettleCommitted)

        settling.commitSettle(stale)
        #expect(!settling.isSettleCommitted, "A resume that was superseded committed")

        let current = settling.beginSettle()
        settling.commitSettle(current)
        settling.endSettle(stale)
        #expect(settling.isSettleCommitted, "A stale resume ending cleared the current one")
    }

    @Test("A reset forgets the previous media's seeks, so the first seek of the next is no burst")
    func resetForgetsEverything() {
        var settling = ChaseSettling()
        let start = ContinuousClock.now
        settling.noteRequest(at: start)
        settling.isAudioFlushPending = true
        settling.isAudioRefillPending = true

        settling.reset()
        settling.noteRequest(at: start + .milliseconds(10))

        #expect(settling.resumeDelay == .zero)
        #expect(!settling.isAudioFlushPending)
        #expect(!settling.isAudioRefillPending)
    }
}
