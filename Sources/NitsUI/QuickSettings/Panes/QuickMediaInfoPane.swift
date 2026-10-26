import NitsCore
import SwiftUI

public struct QuickMediaInfoPane: View {
    public let engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        let metrics = engine.currentMetrics

        VStack(alignment: .leading, spacing: 12) {
            // General Info
            QuickSettingsSection("Media File", systemImage: "doc.text") {
                infoRow(label: "Title", value: engine.mediaTitle.isEmpty ? "—" : engine.mediaTitle)
                infoRow(label: "Duration", value: formatDuration(engine.media.duration))
            }

            if engine.media.hasVideo {
                // Video Stream
                QuickSettingsSection("Video Stream", systemImage: "film") {
                    infoRow(label: "Resolution", value: "\(engine.media.video.width) × \(engine.media.video.height)")
                    let sourceAspect = String(format: "%.2f:1", engine.media.video.displayAspectRatio)
                    let sar = engine.media.video.sampleAspectRatio
                    infoRow(
                        label: "Aspect Ratio",
                        value: sar.isSquare ? sourceAspect : "\(sourceAspect) (SAR \(sar.numerator):\(sar.denominator))"
                    )
                    if engine.videoGeometry.aspectRatio != nil || engine.videoGeometry.crop != nil {
                        infoRow(label: "Shown As", value: String(format: "%.2f:1", engine.contentAspectRatio))
                    }
                    infoRow(
                        label: "Codec",
                        value: engine.media.video.codecName.isEmpty
                            ? (metrics.codecName.isEmpty ? "—" : metrics.codecName) : engine.media.video.codecName)
                    infoRow(label: "Color Depth", value: "\(engine.media.video.bitDepth)-bit")
                    let primaries =
                        engine.media.video.colorPrimaries.isEmpty
                        ? metrics.colorPrimaries : engine.media.video.colorPrimaries
                    if !primaries.isEmpty {
                        infoRow(label: "Color Primaries", value: primaries)
                    }
                    let transfer =
                        engine.media.video.transferFunction.isEmpty
                        ? metrics.transferFunction : engine.media.video.transferFunction
                    if !transfer.isEmpty {
                        infoRow(label: "Transfer Function", value: transfer)
                    }
                    if let dvProfile = engine.media.video.dolbyVisionProfile ?? metrics.dolbyVisionProfile {
                        infoRow(
                            label: "Dolby Vision",
                            value: dvProfile.hasPrefix("Profile") ? dvProfile : "Profile \(dvProfile)")
                    }
                    let peak =
                        engine.media.video.sourcePeakNits > 0
                        ? engine.media.video.sourcePeakNits : metrics.sourcePeakNits
                    if peak > 0 {
                        infoRow(label: "Source Peak", value: "\(Int(peak)) nits")
                    }
                }
            } else if !engine.audioTracks.isEmpty,
                let currentTrack = engine.audioTracks.first(where: { $0.id == engine.selectedAudioTrackId })
                    ?? engine.audioTracks.first
            {
                // Audio Stream Info (Audio-only file)
                QuickSettingsSection("Audio Stream", systemImage: "waveform") {
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
