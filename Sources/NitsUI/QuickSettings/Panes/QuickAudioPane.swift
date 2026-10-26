import NitsCore
import SwiftUI

public struct QuickAudioPane: View {
    @Bindable public var engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Volume & Mute Section
            QuickSettingsSection("Volume Control", systemImage: "speaker.wave.2.fill") {
                HStack(spacing: 12) {
                    Button {
                        engine.isMuted.toggle()
                    } label: {
                        Image(
                            systemName: engine.isMuted || engine.volume == 0
                                ? "speaker.slash.fill" : "speaker.wave.2.fill"
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)

                    QuickSettingsSlider(value: $engine.volume, in: 0.0...1.0)

                    Text("\(Int(engine.volume * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 36, alignment: .trailing)
                }
            }

            // Audio Tracks Section
            QuickSettingsSection("Audio Tracks", systemImage: "waveform") {
                if engine.isLoaded {
                    Button("Load External…") {
                        loadExternalAudio()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            } content: {
                if engine.audioTracks.isEmpty {
                    Text("No audio tracks available")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(engine.audioTracks) { track in
                            let isSelected = track.id == engine.selectedAudioTrackId
                            Button {
                                engine.selectAudioTrack(id: track.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.4))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(
                                            TrackTitleFormatter.format(
                                                title: track.title, language: track.language, fallbackId: track.id + 1)
                                        )
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? .white : .white.opacity(0.8))

                                        let kHz = Double(track.sampleRate) / 1000.0
                                        let formattedRate =
                                            kHz.truncatingRemainder(dividingBy: 1) == 0
                                            ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)

                                        Text(
                                            "\(track.codecName.uppercased()) • \(formattedRate) kHz • \(track.channels) ch"
                                        )
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.5))
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !engine.audioTracks.isEmpty {
                syncSection
            }
        }
    }

    private var syncSection: some View {
        QuickSettingsSection("Sync", systemImage: "clock.arrow.circlepath") {
            if engine.audioDelay != 0 {
                Button("Reset") {
                    engine.resetAudioDelay()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        } content: {
            HStack(spacing: 8) {
                Text("Delay")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                QuickSettingsStepper(
                    "Delay",
                    value: Binding(
                        get: { Int((engine.audioDelay * 1000).rounded()) },
                        set: { engine.setAudioDelay(Double($0) / 1000) }
                    ),
                    format: .number,
                    unit: "ms",
                    onDecrement: { engine.stepAudioDelay(by: -0.05) },
                    onIncrement: { engine.stepAudioDelay(by: 0.05) }
                )
            }

            Text("Positive plays audio later. J / K shift by 50 ms while playing.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Adds an audio file (a dub, a commentary) as a track of the media playing, and plays it.
    private func loadExternalAudio() {
        AudioFilePicker.pick { [engine] url in
            Task { await engine.loadExternalAudio(urls: [url]) }
        }
    }
}
