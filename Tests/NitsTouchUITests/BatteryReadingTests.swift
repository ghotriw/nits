#if os(iOS)
    import Testing
    import UIKit

    @testable import NitsTouchUI

    @Suite("Battery reading")
    struct BatteryReadingTests {
        @Test("An unknown level (the simulator) has no percentage")
        func unknownLevelHasNoPercent() {
            #expect(BatteryReading(level: -1, state: .unknown).percent == nil)
        }

        @Test("The level rounds to a whole percent")
        func levelRoundsToWholePercent() {
            #expect(BatteryReading(level: 0.75, state: .unplugged).percent == 75)
            #expect(BatteryReading(level: 0.754, state: .unplugged).percent == 75)
        }

        @Test("Charging shows the bolt and the flag")
        func chargingShowsBoltAndFlag() {
            let reading = BatteryReading(level: 1, state: .charging)
            #expect(reading.isCharging)
            #expect(reading.symbolName == "battery.100percent.bolt")
            #expect(BatteryReading(level: 0.4, state: .charging).symbolName == "battery.100percent.bolt")
        }

        @Test("A full battery on the charger shows the bolt too")
        func fullOnChargerIsCharging() {
            #expect(BatteryReading(level: 1, state: .full).isCharging)
        }

        @Test("An unknown level has no symbol")
        func unknownLevelHasNoSymbol() {
            #expect(BatteryReading(level: -1, state: .unknown).symbolName == nil)
        }

        @Test("The symbol steps by quarter")
        func symbolStepsByQuarter() {
            #expect(BatteryReading(level: 0, state: .unplugged).symbolName == "battery.0percent")
            #expect(BatteryReading(level: 0.2, state: .unplugged).symbolName == "battery.25percent")
            #expect(BatteryReading(level: 0.5, state: .unplugged).symbolName == "battery.50percent")
            #expect(BatteryReading(level: 0.8, state: .unplugged).symbolName == "battery.75percent")
            #expect(BatteryReading(level: 0.95, state: .unplugged).symbolName == "battery.100percent")
        }
    }
#endif
