import NitsCore
import SwiftUI

public struct QuickVideoPane: View {
    @Bindable public var engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    /// Bindings to the engine's tone-mapping settings.
    private var toneMapping: Bindable<ToneMapController> { Bindable(engine.toneMapping) }

    private var isMetalActive: Bool {
        engine.activeRenderMode == .metalToneMap
    }

    private var deinterlaceDescription: String {
        let fps = String(format: "%.4g", 1.0 / max(engine.nominalFrameDuration, 0.001))
        switch engine.deinterlaceMode {
        case .auto:
            return "A frame per field, \(fps) fps. Fields of still scenes and film stay one frame."
        case .frameRate:
            return "A frame per interlaced frame, \(fps) fps."
        case .off:
            return "Frames are shown woven, as stored."
        }
    }

    private var isPictureAdjusted: Bool {
        let geometry = engine.videoGeometry
        return geometry.aspectRatio != nil || geometry.crop != nil || geometry.zoom != 1.0 || geometry.pan != .zero
    }

    /// The variants playback can switch to; the others need decoders of their own.
    private var qualitySection: some View {
        QuickSettingsSection("Quality", systemImage: "square.stack.3d.up") {
            let selectedLabel: String = {
                if engine.isVariantAutomatic {
                    return automaticTitle
                }
                if let variant = engine.variants.first(where: { $0.id == engine.selectedVariantId }) {
                    return Self.variantTitle(variant)
                }
                return automaticTitle
            }()

            // `nil` is adaptive bitrate, offered while reading ahead (network sources).
            QuickSettingsPicker(
                "Quality",
                valueLabel: selectedLabel,
                selection: Binding(
                    get: { engine.isVariantAutomatic ? nil : engine.selectedVariantId },
                    set: { id in
                        if let id {
                            engine.selectVariant(id: id)
                        } else {
                            engine.selectAutomaticVariant()
                        }
                    }
                )
            ) {
                if engine.canSelectAutomaticVariant {
                    Text(automaticTitle).tag(Int?.none)
                }
                ForEach(engine.variants.filter(\.isSwitchable)) { variant in
                    Text(Self.variantTitle(variant)).tag(Optional(variant.id))
                }
            }
        }
    }

    /// The pictures a page offers as files of their own: choosing one plays it from the current frame, after a pause
    /// while it opens. What yt-dlp chose is the one playing until then.
    private var videoFormatSection: some View {
        QuickSettingsSection("Quality", systemImage: "square.stack.3d.up") {
            let selectedLabel =
                engine.videoFormats.first(where: { $0.id == engine.selectedVideoFormatId })
                .map(Self.videoFormatTitle) ?? "—"

            QuickSettingsPicker(
                "Quality",
                valueLabel: selectedLabel,
                selection: Binding(
                    get: { engine.selectedVideoFormatId },
                    set: { id in
                        if let id { engine.selectVideoFormat(id: id) }
                    }
                )
            ) {
                ForEach(engine.videoFormats) { format in
                    Text(Self.videoFormatTitle(format)).tag(Optional(format.id))
                }
            }
        }
    }

    /// "1920×1080 • 60 fps • AV1 • 0.9 Mbit/s"
    static func videoFormatTitle(_ format: VideoFormat) -> String {
        var parts = ["\(format.width)×\(format.height)"]
        if let fps = format.frameRate, fps > 30 { parts.append("\(Int(fps.rounded())) fps") }
        if !format.codec.isEmpty { parts.append(format.codec) }
        if format.bitrate > 0 { parts.append(String(format: "%.1f Mbit/s", Double(format.bitrate) / 1_000_000)) }
        return parts.joined(separator: " • ")
    }

    /// "Auto", with the variant playing while it chooses.
    private var automaticTitle: String {
        guard engine.isVariantAutomatic,
            let playing = engine.variants.first(where: { $0.id == engine.selectedVariantId })
        else { return "Auto" }
        return "Auto (\(Self.variantTitle(playing)))"
    }

    static func variantTitle(_ variant: MediaDemuxer.StreamVariant) -> String {
        let rate = String(format: "%.1f Mbit/s", Double(variant.bandwidth) / 1_000_000)
        return variant.height > 0 ? "\(variant.width)×\(variant.height) • \(rate)" : rate
    }

    private var pictureSection: some View {
        QuickSettingsSection("Picture", systemImage: "aspectratio") {
            if isPictureAdjusted {
                Button("Reset") {
                    engine.setVideoAspectRatio(nil)
                    engine.setVideoCrop(nil)
                    engine.resetVideoZoom()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    pictureLabel("Aspect Ratio")
                    QuickSettingsPicker(
                        "Aspect Ratio",
                        valueLabel: engine.videoGeometry.aspectRatio?.displayName
                            ?? "Default (\(formattedRatio(engine.media.video.displayAspectRatio)))",
                        selection: Binding(
                            get: { engine.videoGeometry.aspectRatio },
                            set: { engine.setVideoAspectRatio($0) }
                        )
                    ) {
                        Text("Default (\(formattedRatio(engine.media.video.displayAspectRatio)))").tag(
                            RationalAspectRatio?.none)
                        ForEach(RationalAspectRatio.displayPresets, id: \.self) { ratio in
                            Text(ratio.displayName).tag(RationalAspectRatio?.some(ratio))
                        }
                    }
                }
                GridRow {
                    pictureLabel("Crop")
                    QuickSettingsPicker(
                        "Crop",
                        valueLabel: engine.videoGeometry.crop?.displayName ?? "None",
                        selection: Binding(
                            get: { engine.videoGeometry.crop },
                            set: { engine.setVideoCrop($0) }
                        )
                    ) {
                        Text("None").tag(RationalAspectRatio?.none)
                        ForEach(RationalAspectRatio.displayPresets, id: \.self) { ratio in
                            Text(ratio.displayName).tag(RationalAspectRatio?.some(ratio))
                        }
                    }
                }
                GridRow {
                    pictureLabel("Scaling")
                    QuickSettingsPicker(
                        "Scaling",
                        valueLabel: engine.videoGeometry.scaling.title,
                        selection: Binding(
                            get: { engine.videoGeometry.scaling },
                            set: { engine.setVideoScaling($0) }
                        )
                    ) {
                        ForEach(VideoScaling.allCases) { scaling in
                            Text(scaling.title).tag(scaling)
                        }
                    }
                }
                GridRow {
                    pictureLabel("Zoom")
                    QuickSettingsStepper(
                        "Zoom",
                        value: Binding(
                            get: { Int((engine.videoGeometry.zoom * 100).rounded()) },
                            set: { engine.setVideoZoom(Double($0) / 100.0) }
                        ),
                        format: .number,
                        unit: "%",
                        canDecrement: engine.videoGeometry.zoom > VideoGeometrySettings.zoomRange.lowerBound,
                        canIncrement: engine.videoGeometry.zoom < VideoGeometrySettings.zoomRange.upperBound,
                        onDecrement: { engine.stepVideoZoom(by: -1) },
                        onIncrement: { engine.stepVideoZoom(by: 1) }
                    )
                }
            }

            Text("Aspect ratio and crop are remembered for this file. Drag the picture to move it while it is zoomed.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func pictureLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.7))
    }

    private func formattedRatio(_ ratio: Double) -> String {
        String(format: "%.2f:1", ratio)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Playback Speed Section (First Item)
            QuickSettingsSection("Playback Speed", systemImage: "gauge.with.dots.needle.bottom.50percent") {
                if engine.playbackRate != 1.0 {
                    Button("Reset") {
                        withAnimation {
                            engine.resetPlaybackRate()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                let formattedRate: String = {
                    let rate = engine.playbackRate
                    let isTenth = abs((rate * 10).rounded() - (rate * 10)) < 1e-4
                    return isTenth ? String(format: "%.1f×", rate) : String(format: "%.2f×", rate)
                }()
                Text(formattedRate)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(engine.playbackRate == 1.0 ? .white.opacity(0.7) : Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            } content: {

                QuickSettingsSlider(
                    value: Binding(
                        get: { engine.playbackRate },
                        set: { engine.setPlaybackRate($0) }
                    ),
                    in: 0.5...2.5,
                    step: 0.1
                )

                // Visual tick marks: 0.5×, 1.0×, 1.5×, 2.0×, 2.5×
                HStack {
                    Text("0.5×")
                    Spacer()
                    Text("1.0×")
                    Spacer()
                    Text("1.5×")
                    Spacer()
                    Text("2.0×")
                    Spacer()
                    Text("2.5×")
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 2)
            }

            // HLS variants, or the files a page offers
            if engine.variants.filter(\.isSwitchable).count > 1 {
                qualitySection
            } else if engine.videoFormats.count > 1 {
                videoFormatSection
            }

            // Picture geometry: aspect ratio, crop, scaling, zoom
            if engine.media.hasVideo {
                pictureSection
            }

            // Deinterlacing - only for interlaced video
            if engine.media.video.isInterlaced {
                QuickSettingsSection("Deinterlacing", systemImage: "line.3.horizontal") {
                    QuickSettingsPicker(
                        "Deinterlacing",
                        valueLabel: engine.deinterlaceMode.rawValue,
                        selection: $engine.deinterlaceMode
                    ) {
                        ForEach(DeinterlaceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    Text(deinterlaceDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            // Render Mode Section
            QuickSettingsSection("Render Mode", systemImage: "display") {
                QuickSettingsPicker(
                    "Render Mode",
                    valueLabel: engine.renderMode.rawValue,
                    selection: $engine.renderMode
                ) {
                    ForEach(RenderMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Text(
                    "Display: \(engine.isHDRDisplay ? "HDR / EDR Capable" : "Standard SDR") • Active: \(engine.activeRenderMode.rawValue)"
                )
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            }

            // Tone Mapping Parameters (BT.2390 EETF) - only shown when Metal Tone Mapping is active
            if isMetalActive {
                QuickSettingsSection("Tone Mapping Controls", systemImage: "slider.horizontal.3") {
                    Button("Reset") {
                        withAnimation {
                            engine.toneMapping.sharpness = 0.5
                            engine.toneMapping.exposure = 1.0
                            engine.toneMapping.shadowLift = 0
                            engine.toneMapping.targetNitsScale = 1.0
                            engine.toneMapping.localContrast = ToneMapController.defaultLocalContrast
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                } content: {
                    // Sharpness (CAS)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("CAS Sharpness")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(String(format: "%.2f", engine.toneMapping.sharpness))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        QuickSettingsSlider(value: toneMapping.sharpness, in: 0.0...1.0)
                    }

                    // Target Nits Scale
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Target Nits (Adaptive White)")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(
                                "\(Int(engine.toneMapping.appliedTargetNits)) nits (\(String(format: "%.2f", engine.toneMapping.targetNitsScale))×)"
                            )
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                        }
                        QuickSettingsSlider(value: toneMapping.targetNitsScale, in: 0.5...2.0)
                    }

                    // Exposure
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Output Exposure")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(String(format: "%.2f×", engine.toneMapping.exposure))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        QuickSettingsSlider(value: toneMapping.exposure, in: 0.5...2.0)
                    }

                    // Shadow Lift
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Shadow Lift")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(String(format: "%.3f", engine.toneMapping.shadowLift))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        QuickSettingsSlider(value: toneMapping.shadowLift, in: 0.0...0.1)
                    }

                    // Local contrast (ContrastRecovery)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Local Contrast")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(
                                engine.toneMapping.localContrast > 0
                                    ? String(format: "%.2f", engine.toneMapping.localContrast) : "Off"
                            )
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                        }
                        QuickSettingsSlider(value: toneMapping.localContrast, in: 0.0...1.0)
                    }

                    if engine.media.video.dolbyVisionProfile != nil {
                        Toggle(isOn: toneMapping.applyDolbyVisionTrims) {
                            Text("Dolby Vision Trims (L2)")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
