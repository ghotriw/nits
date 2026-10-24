#if os(macOS)
    import Foundation
    import IOKit.pwr_mgt

    typealias PlatformDisplaySleepAssertion = IOKitDisplaySleepAssertion

    /// An IOKit power assertion against idle display sleep.
    final class IOKitDisplaySleepAssertion: DisplaySleepAssertion {
        private let id: IOPMAssertionID

        init?(reason: String) {
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newID
            )
            guard result == kIOReturnSuccess else {
                AppLog.error(.engine, "Failed to create display sleep assertion: \(result)")
                return nil
            }
            id = newID
            AppLog.debug(.engine, "Display sleep disabled (assertionID: \(newID))")
        }

        deinit {
            let result = IOPMAssertionRelease(id)
            if result != kIOReturnSuccess {
                AppLog.error(.engine, "Failed to release display sleep assertion: \(result)")
            } else {
                AppLog.debug(.engine, "Display sleep re-enabled")
            }
        }
    }
#endif
