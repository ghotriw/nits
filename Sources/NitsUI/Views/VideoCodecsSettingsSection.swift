import NitsCore
import SwiftUI

/// The order of video codecs among the pictures of one size a manifest offers, with a switch for each: a codec off is
/// played only when nothing else is there.
struct VideoCodecsSettingsSection: View {
    @AppStorage(PlayerConfiguration.keyVideoCodecs)
    private var stored: String = VideoCodecPreference().stored

    let onChange: () -> Void

    private var preference: Binding<VideoCodecPreference> {
        Binding(
            get: { VideoCodecPreference(stored: stored) },
            set: { stored = $0.stored }
        )
    }

    var body: some View {
        Section {
            let current = preference.wrappedValue
            ForEach(Array(current.order.enumerated()), id: \.element) { index, family in
                HStack {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Toggle(
                        VideoCodecPreference.displayName(of: family),
                        isOn: Binding(
                            get: { preference.wrappedValue.isEnabled(family) },
                            set: { isOn in
                                preference.wrappedValue.setEnabled(isOn, family: family)
                                onChange()
                            }
                        )
                    )
                    Spacer()
                    Button {
                        preference.wrappedValue.shift(family, by: -1)
                        onChange()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    .help("Move up")
                    Button {
                        preference.wrappedValue.shift(family, by: 1)
                        onChange()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == current.order.count - 1)
                    .help("Move down")
                }
                .buttonStyle(.borderless)
            }
            Button("Reset to Default") {
                stored = VideoCodecPreference().stored
                onChange()
            }
            .disabled(stored == VideoCodecPreference().stored)
        } header: {
            Text("Preferred Video Codecs")
        } footer: {
            Text(
                "Among pictures of the same size and range in a DASH manifest, the first codec on this list plays; the others stay in the Format menu. A codec switched off plays only when nothing else is offered."
            )
        }
    }
}
