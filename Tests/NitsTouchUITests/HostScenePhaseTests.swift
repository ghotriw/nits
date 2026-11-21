#if os(iOS)
    import NitsTouchKit
    import SwiftUI
    import Testing

    @testable import NitsTouchUI

    @Suite("Scene phase mapping")
    struct HostScenePhaseTests {
        /// The session's background handling hangs on this mapping: a wrong case would never tell the engine.
        @Test("Each SwiftUI phase maps to its own")
        func mapping() {
            #expect(HostScenePhase(.active) == .active)
            #expect(HostScenePhase(.inactive) == .inactive)
            #expect(HostScenePhase(.background) == .background)
        }
    }
#endif
