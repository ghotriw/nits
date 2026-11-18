import Foundation
import Testing
import os

@testable import NitsStreaming

/// A lane tells its observer of every download's progress, again and again over a long run of segments
/// (`StreamingLane.ProgressObserverSlot`).
@Suite("Observer of segment downloads")
struct SegmentProgressObserverTests {
    private static let segment = StreamingLane.SegmentInFlight(
        sequence: 1, start: 0, duration: 1,
        progress: HTTPSessionInput.Progress(
            bytes: 0, length: nil, elapsed: 0, firstAnswer: nil, transferring: 0, measuredBytes: 0, isSuspended: false))

    /// The observer held as the lock's bare state gained two reabstraction thunks a read, which every call went
    /// through: after ~1250 segments of a YouTube stream the reading thread's 512 KB stack overflowed.
    @Test("Telling the observer does not deepen the stack from one call to the next")
    func callsStayShallow() {
        let slot = StreamingLane.ProgressObserverSlot()
        let depth = OSAllocatedUnfairLock(initialState: 0)
        slot.set { _ in depth.withLock { $0 = Thread.callStackSymbols.count } }
        let told = slot.tell(Self.segment)
        let first = depth.withLock { $0 }
        for _ in 0..<1000 { slot.tell(Self.segment) }
        #expect(told)
        #expect(depth.withLock { $0 } == first)
    }

    @Test("Nothing is told before an observer is set")
    func noObserver() {
        #expect(!StreamingLane.ProgressObserverSlot().tell(Self.segment))
    }
}
