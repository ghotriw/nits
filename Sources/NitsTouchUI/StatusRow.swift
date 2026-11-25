#if os(iOS)
    import SwiftUI
    import UIKit

    /// The row the system's status bar leaves when it is hidden: clock and network at the left, the title after them (left-aligned: centred, the number of icons would move it), the battery at the right.
    struct StatusRow: View {
        let title: String
        /// The screen's one monitor (this row is rebuilt when the controls lock and unlock, and four times a second).
        let network: NetworkKindMonitor?
        @State private var battery = Self.currentBattery()

        var body: some View {
            HStack(spacing: 10) {
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                }
                networkIcon
                Text(title).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                Spacer(minLength: 8)
                if let percent = battery.percent {
                    Text("\(percent)%")
                }
                if let symbol = battery.symbolName {
                    Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                }
            }
            .font(.footnote.weight(.medium))
            .frame(height: 24)
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                battery = Self.currentBattery()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                battery = Self.currentBattery()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                battery = Self.currentBattery()
            }
            .accessibilityElement(children: .combine)
        }

        @ViewBuilder private var networkIcon: some View {
            switch network?.kind ?? .other {
            case .wifi: Image(systemName: "wifi")
            case .cellular: Image(systemName: "antenna.radiowaves.left.and.right")
            case .offline: Image(systemName: "wifi.slash")
            case .other: EmptyView()
            }
        }

        private static func currentBattery() -> BatteryReading {
            BatteryReading(level: UIDevice.current.batteryLevel, state: UIDevice.current.batteryState)
        }
    }
#endif
