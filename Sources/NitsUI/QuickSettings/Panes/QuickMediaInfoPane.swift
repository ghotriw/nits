import NitsCore
import SwiftUI

public struct QuickMediaInfoPane: View {
    public let engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        QuickMediaInfoContent(sections: [fileSection, streamSection].compactMap(\.self))
    }

    private var fileSection: MediaInfoSection {
        let duration = engine.media.duration
        return MediaInfoSection(
            title: "Media File", systemImage: "doc.text",
            rows: [
                ("Title", engine.mediaTitle.isEmpty ? "—" : engine.mediaTitle),
                ("Duration", duration > 0 ? TimeParser.format(seconds: duration) : "—"),
            ])
    }

    /// The video stream, or the selected audio track of a file without a picture.
    private var streamSection: MediaInfoSection? {
        if engine.media.hasVideo {
            return MediaInfoSection(title: "Video Stream", systemImage: "film", rows: videoRows)
        }
        guard
            let track = engine.audioTracks.first(where: { $0.id == engine.selectedAudioTrackId })
                ?? engine.audioTracks.first
        else { return nil }
        var rows: [MediaInfoSection.Row] = [
            ("Codec", track.codecName.uppercased()),
            ("Sample Rate", track.sampleRateText),
            ("Channels", "\(track.channels) ch"),
        ]
        if !track.language.isEmpty {
            rows.append(("Language", track.language.uppercased()))
        }
        return MediaInfoSection(title: "Audio Stream", systemImage: "waveform", rows: rows)
    }

    private var videoRows: [MediaInfoSection.Row] {
        let video = engine.media.video
        let metrics = engine.currentMetrics
        var rows: [MediaInfoSection.Row] = [("Resolution", "\(video.width) × \(video.height)")]

        let sourceAspect = String(format: "%.2f:1", video.displayAspectRatio)
        let sar = video.sampleAspectRatio
        rows.append(
            ("Aspect Ratio", sar.isSquare ? sourceAspect : "\(sourceAspect) (SAR \(sar.numerator):\(sar.denominator))"))
        if engine.videoGeometry.aspectRatio != nil || engine.videoGeometry.crop != nil {
            rows.append(("Shown As", String(format: "%.2f:1", engine.contentAspectRatio)))
        }

        let codec = video.codecName.isEmpty ? metrics.codecName : video.codecName
        rows.append(("Codec", codec.isEmpty ? "—" : codec))
        rows.append(("Color Depth", "\(video.bitDepth)-bit"))

        let primaries = video.colorPrimaries.isEmpty ? metrics.colorPrimaries : video.colorPrimaries
        if !primaries.isEmpty {
            rows.append(("Color Primaries", primaries))
        }
        let transfer = video.transferFunction.isEmpty ? metrics.transferFunction : video.transferFunction
        if !transfer.isEmpty {
            rows.append(("Transfer Function", transfer))
        }
        if let dvProfile = video.dolbyVisionProfile ?? metrics.dolbyVisionProfile {
            rows.append(("Dolby Vision", dvProfile.hasPrefix("Profile") ? dvProfile : "Profile \(dvProfile)"))
        }
        let peak = video.sourcePeakNits > 0 ? video.sourcePeakNits : metrics.sourcePeakNits
        if peak > 0 {
            rows.append(("Source Peak", "\(Int(peak)) nits"))
        }
        return rows
    }
}

private struct MediaInfoSection {
    typealias Row = (label: String, value: String)

    let title: String
    let systemImage: String
    let rows: [Row]
}

/// The pane's layout, apart from the engine so that a preview can fill it.
private struct QuickMediaInfoContent: View {
    let sections: [MediaInfoSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sections, id: \.title) { section in
                QuickSettingsSection(section.title, systemImage: section.systemImage) {
                    ForEach(section.rows, id: \.label) { row in
                        infoRow(label: row.label, value: row.value)
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
}

#Preview("Video") {
    QuickMediaInfoContent(sections: [
        MediaInfoSection(
            title: "Media File", systemImage: "doc.text",
            rows: [("Title", "Tears of Steel (4K HDR)"), ("Duration", "12:14")]),
        MediaInfoSection(
            title: "Video Stream", systemImage: "film",
            rows: [
                ("Resolution", "3840 × 2160"),
                ("Aspect Ratio", "2.40:1"),
                ("Codec", "HEVC"),
                ("Color Depth", "10-bit"),
                ("Color Primaries", "BT.2020"),
                ("Transfer Function", "SMPTE ST 2084 (PQ)"),
                ("Dolby Vision", "Profile 8.1 (HDR10 Base)"),
                ("Source Peak", "1000 nits"),
            ]),
    ])
    .padding()
    .frame(width: 340)
    .background(.black.opacity(0.85))
}

#Preview("Audio only") {
    QuickMediaInfoContent(sections: [
        MediaInfoSection(
            title: "Media File", systemImage: "doc.text",
            rows: [("Title", "Synthetic tone"), ("Duration", "6:21")]),
        MediaInfoSection(
            title: "Audio Stream", systemImage: "waveform",
            rows: [("Codec", "FLAC"), ("Sample Rate", "96 kHz"), ("Channels", "2 ch"), ("Language", "UKR")]),
    ])
    .padding()
    .frame(width: 340)
    .background(.black.opacity(0.85))
}
