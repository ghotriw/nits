#if os(iOS)
    import NitsCore
    import Testing

    @testable import NitsTouchUI

    @Suite("Repeat icon")
    struct RepeatIconTests {
        @Test("Each mode has its symbol")
        func symbols() {
            #expect(RepeatIcon.symbol(for: .off) == "repeat")
            #expect(RepeatIcon.symbol(for: .all) == "repeat")
            #expect(RepeatIcon.symbol(for: .one) == "repeat.1")
        }

        @Test("The accessibility labels differ")
        func labelsAreDistinct() {
            let labels = PlaylistRepeatMode.allCases.map { RepeatIcon.label(for: $0) }
            #expect(Set(labels).count == 3)
            #expect(labels.allSatisfy { !$0.isEmpty })
        }
    }
#endif
