#if os(iOS)
    import NitsCore
    import SwiftUI

    /// The playback speed as a menu button: the current speed on the label, the choices in a checkmarked list.
    struct SpeedMenu: View {
        let engine: PlayerEngine
        /// Told of a tap on the button and of a choice: a menu's touches do not reach the controls' own timer.
        var onInteraction: () -> Void = {}

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
                Text(Self.label(chosenRate))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 36)
                    .background(.white.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
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
