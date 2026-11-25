#if os(iOS)
    import UIKit

    /// The battery as the status row shows it: a symbol and a whole percent, none while the level is unknown (the
    /// simulator reports -1).
    struct BatteryReading: Equatable {
        let level: Float
        let state: UIDevice.BatteryState

        init(level: Float, state: UIDevice.BatteryState) {
            self.level = level
            self.state = state
        }

        var percent: Int? {
            level < 0 ? nil : Int((min(level, 1) * 100).rounded())
        }

        /// On power: charging, or full and still on the charger (the system's status bar shows the bolt for both).
        var isCharging: Bool { state == .charging || state == .full }

        /// `nil` while the level is unknown. SF Symbols has the bolt only on the full battery, so a charging one is drawn so.
        var symbolName: String? {
            guard level >= 0 else { return nil }
            if isCharging { return "battery.100percent.bolt" }
            let step: Int
            switch level {
            case ..<0.125: step = 0
            case ..<0.375: step = 25
            case ..<0.625: step = 50
            case ..<0.875: step = 75
            default: step = 100
            }
            return "battery.\(step)percent"
        }
    }
#endif
