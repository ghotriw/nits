import NitsCore
import SwiftUI

public struct QuickMediaInfoPane: View {
    public let engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        let metrics = engine.currentMetrics

        VStack(alignment: .leading, spacing: 18) {
            // General Info
            VStack(alignment: .leading, spacing: 8) {
                Label("Media File", systemImage: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                infoRow(label: "Title", value: engine.mediaTitle.isEmpty ? "—" : engine.mediaTitle)
                infoRow(label: "Duration", value: formatDuration(engine.duration))
            }

            Divider()
                .overlay(Color.white.opacity(0.12))

            if engine.hasVideo {
                // Video Stream
                VStack(alignment: .leading, spacing: 8) {
                    Label("Video Stream", systemImage: "film")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    infoRow(label: "Resolution", value: "\(engine.videoWidth) × \(engine.videoHeight)")
                    infoRow(
                        label: "Codec",
                        value: engine.videoCodecName.isEmpty
                            ? (metrics.codecName.isEmpty ? "—" : metrics.codecName) : engine.videoCodecName)
                    infoRow(label: "Color Depth", value: "\(engine.videoBitDepth)-bit")
                    let primaries =
                        engine.videoColorPrimaries.isEmpty ? metrics.colorPrimaries : engine.videoColorPrimaries
                    if !primaries.isEmpty {
                        infoRow(label: "Color Primaries", value: primaries)
                    }
                    let transfer =
                        engine.videoTransferFunction.isEmpty ? metrics.transferFunction : engine.videoTransferFunction
                    if !transfer.isEmpty {
                        infoRow(label: "Transfer Function", value: transfer)
                    }
                    if let dvProfile = engine.videoDolbyVisionProfile ?? metrics.dolbyVisionProfile {
                        infoRow(
                            label: "Dolby Vision",
                            value: dvProfile.hasPrefix("Profile") ? dvProfile : "Profile \(dvProfile)")
                    }
                    let peak = engine.videoSourcePeakNits > 0 ? engine.videoSourcePeakNits : metrics.sourcePeakNits
                    if peak > 0 {
                        infoRow(label: "Source Peak", value: "\(Int(peak)) nits")
                    }
                }

                Divider()
                    .overlay(Color.white.opacity(0.12))
            } else if !engine.audioTracks.isEmpty,
                let currentTrack = engine.audioTracks.first(where: { $0.id == engine.selectedAudioTrackId })
                    ?? engine.audioTracks.first
            {
                // Audio Stream Info (Audio-only file)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Audio Stream", systemImage: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    infoRow(label: "Codec", value: currentTrack.codecName.uppercased())
                    let kHz = Double(currentTrack.sampleRate) / 1000.0
                    let formattedRate =
                        kHz.truncatingRemainder(dividingBy: 1) == 0
                        ? String(format: "%.0f kHz", kHz) : String(format: "%.1f kHz", kHz)
                    infoRow(label: "Sample Rate", value: formattedRate)
                    infoRow(label: "Channels", value: "\(currentTrack.channels) ch")
                    if !currentTrack.language.isEmpty {
                        infoRow(label: "Language", value: currentTrack.language.uppercased())
                    }
                }
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 105, alignment: .leading)

            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.leading)

            Spacer()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        return TimeParser.format(seconds: seconds)
    }
}
