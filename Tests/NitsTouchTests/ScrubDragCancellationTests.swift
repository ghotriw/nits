#if os(iOS)
    import Testing

    @testable import NitsTouch

    @Suite("Scrub bar drag cancellation")
    struct ScrubDragCancellationTests {
        @Test("A finger that lifts while the bar still shows a drag is a cancelled drag")
        func cancelledWhenDragRemains() {
            #expect(ScrubDragCancellation.isCancelled(wasDown: true, isDown: false, dragFraction: 0.4))
        }

        @Test("A drag that ended by itself has cleared the fraction: nothing to cancel")
        func finishedDragIsNotCancelled() {
            #expect(!ScrubDragCancellation.isCancelled(wasDown: true, isDown: false, dragFraction: nil))
        }

        @Test("A finger going down, or a state that did not change, cancels nothing")
        func otherTransitionsAreIgnored() {
            #expect(!ScrubDragCancellation.isCancelled(wasDown: false, isDown: true, dragFraction: 0.4))
            #expect(!ScrubDragCancellation.isCancelled(wasDown: false, isDown: false, dragFraction: 0.4))
            #expect(!ScrubDragCancellation.isCancelled(wasDown: true, isDown: true, dragFraction: 0.4))
        }
    }
#endif
