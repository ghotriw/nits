import NitsCore
import SwiftUI

/// The order of audio codecs among the sounds of one language a manifest offers: the first on the list plays, whatever
/// the bitrates (Opus and AAC differ in how they spend them).
struct AudioCodecsSettingsSection: View {
    @AppStorage(PlayerConfiguration.keyAudioCodecs)
    private var stored: String = AudioCodecPreference().stored

    let onChange: () -> Void

    var body: some View {
        Section {
            let current = AudioCodecPreference(stored: stored)
            ForEach(Array(current.order.enumerated()), id: \.element) { index, family in
                HStack {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(AudioCodecPreference.displayName(of: family))
                    Spacer()
                    Button {
                        move(family, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    .help("Move up")
                    Button {
                        move(family, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == current.order.count - 1)
                    .help("Move down")
                }
                .buttonStyle(.borderless)
            }
            Button("Reset to Default") {
                stored = AudioCodecPreference().stored
                onChange()
            }
            .disabled(stored == AudioCodecPreference().stored)
        } header: {
            Text("Preferred Audio Codecs")
        } footer: {
            Text(
                "Among sounds of the same language and role in a DASH manifest (YouTube's included), the first codec on this list plays, whatever the bitrates."
            )
        }
    }

    private func move(_ family: String, by places: Int) {
        var preference = AudioCodecPreference(stored: stored)
        preference.shift(family, by: places)
        stored = preference.stored
        onChange()
    }
}
