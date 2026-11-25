#if os(iOS)
    import NitsCore
    import SwiftUI

    /// The playback speed as a menu button: a gauge icon, with the speed beside it when it is not 1×, the choices in a checkmarked list.
    struct SpeedMenu: View, Equatable {
        let engine: PlayerEngine
        /// Told of a tap on the button and of a choice: a menu's touches do not reach the controls' own timer.
        var onInteraction: () -> Void = {}

        /// Equal while it is the same engine: the screen re-evaluates its controls every quarter second and as the time moves, and a menu rebuilt
        /// while it is open flickers. What the menu shows it observes itself, so a change still redraws it.
        /// `onInteraction` is not compared: the screen always passes the same touch of its controls' visibility.
        nonisolated static func == (lhs: SpeedMenu, rhs: SpeedMenu) -> Bool { lhs.engine === rhs.engine }

        static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3]

        /// The speed in effect (a live stream at its edge plays at 1×, whatever was chosen, until a seek goes behind it).
        private var chosenRate: Double { engine.playbackRate }

        /// The presets, and the speed in effect when it is not one of them (kept from a history or a keyboard step).
        private var choices: [Double] {
            Self.rates.contains(chosenRate) ? Self.rates : (Self.rates + [chosenRate]).sorted()
        }

        private var selection: Binding<Double> {
            Binding(
                get: { chosenRate },
                set: {
                    engine.setPlaybackRate($0)
                    onInteraction()
                })
        }

        var body: some View {
            Menu {
                Picker("Speed", selection: selection) {
                    ForEach(choices, id: \.self) { rate in
                        Text(Self.label(rate)).tag(rate)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if chosenRate != 1 {
                        Text(Self.label(chosenRate)).font(.footnote.weight(.semibold).monospacedDigit())
                    }
                    Image(systemName: "gauge.with.needle").font(.title3)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .simultaneousGesture(TapGesture().onEnded { onInteraction() })
            .accessibilityLabel("Speed")
            .accessibilityValue(Self.label(chosenRate))
        }

        static func label(_ rate: Double) -> String {
            let text = rate.formatted(.number.precision(.fractionLength(0...2)))
            return text + "×"
        }
    }
#endif
