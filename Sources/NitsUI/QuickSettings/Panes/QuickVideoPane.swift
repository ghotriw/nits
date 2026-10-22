import NitsCore
import SwiftUI

public struct QuickVideoPane: View {
    @Bindable public var engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

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
        VStack(alignment: .leading, spacing: 8) {
            Label("Quality", systemImage: "square.stack.3d.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            // `nil` is adaptive bitrate, offered while reading ahead (network sources).
            Picker(
                "Quality",
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
            .pickerStyle(.menu)
            .labelsHidden()
        }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Picture", systemImage: "aspectratio")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
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
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    pictureLabel("Aspect Ratio")
                    Picker(
                        "Aspect Ratio",
                        selection: Binding(
                            get: { engine.videoGeometry.aspectRatio },
                            set: { engine.setVideoAspectRatio($0) }
                        )
                    ) {
                        Text("Default (\(formattedRatio(engine.displayAspectRatio)))").tag(RationalAspectRatio?.none)
                        ForEach(RationalAspectRatio.displayPresets, id: \.self) { ratio in
                            Text(ratio.displayName).tag(RationalAspectRatio?.some(ratio))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    pictureLabel("Crop")
                    Picker(
                        "Crop",
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
                    .labelsHidden()
                }
                GridRow {
                    pictureLabel("Scaling")
                    Picker(
                        "Scaling",
                        selection: Binding(
                            get: { engine.videoGeometry.scaling },
                            set: { engine.setVideoScaling($0) }
                        )
                    ) {
                        ForEach(VideoScaling.allCases) { scaling in
                            Text(scaling.title).tag(scaling)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    pictureLabel("Zoom")
                    HStack(spacing: 6) {
                        Button {
                            engine.stepVideoZoom(by: -1)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .disabled(engine.videoGeometry.zoom <= VideoGeometrySettings.zoomRange.lowerBound)
                        Text("\(Int((engine.videoGeometry.zoom * 100).rounded()))%")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(engine.videoGeometry.zoom == 1.0 ? .white.opacity(0.7) : Color.accentColor)
                            .frame(minWidth: 44)
                        Button {
                            engine.stepVideoZoom(by: 1)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .disabled(engine.videoGeometry.zoom >= VideoGeometrySettings.zoomRange.upperBound)
                    }
                }
            }
            .pickerStyle(.menu)

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
        VStack(alignment: .leading, spacing: 20) {
            // Playback Speed Section (First Item)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Playback Speed", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
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
                }

                Slider(
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

            Divider()
                .overlay(Color.white.opacity(0.12))

            // Render Mode Section
            VStack(alignment: .leading, spacing: 8) {
                Label("Render Mode", systemImage: "display")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Picker("Render Mode", selection: $engine.renderMode) {
                    ForEach(RenderMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Text(
                    "Display: \(engine.isHDRDisplay ? "HDR / EDR Capable" : "Standard SDR") • Active: \(engine.activeRenderMode.rawValue)"
                )
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            }

            // HLS variants
            if engine.variants.filter(\.isSwitchable).count > 1 {
                Divider()
                    .overlay(Color.white.opacity(0.12))

                qualitySection
            }

            // Picture geometry: aspect ratio, crop, scaling, zoom
            if engine.hasVideo {
                Divider()
                    .overlay(Color.white.opacity(0.12))

                pictureSection
            }

            // Deinterlacing - only for interlaced video
            if engine.isInterlacedContent {
                Divider()
                    .overlay(Color.white.opacity(0.12))

                VStack(alignment: .leading, spacing: 8) {
                    Label("Deinterlacing", systemImage: "line.3.horizontal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    Picker("Deinterlacing", selection: $engine.deinterlaceMode) {
                        ForEach(DeinterlaceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text(deinterlaceDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            // Tone Mapping Parameters (BT.2390 EETF) - only shown when Metal Tone Mapping is active
            if isMetalActive {
                Divider()
                    .overlay(Color.white.opacity(0.12))

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Tone Mapping Controls", systemImage: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Button("Reset") {
                            withAnimation {
                                engine.metalSharpness = 0.5
                                engine.metalExposure = 1.0
                                engine.metalShadowLift = 0.0
                                engine.targetNitsScale = 1.0
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }

                    // Sharpness (CAS)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("CAS Sharpness")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(String(format: "%.2f", engine.metalSharpness))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Slider(value: $engine.metalSharpness, in: 0.0...1.0)
                    }

                    // Target Nits Scale
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Target Nits (Adaptive White)")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(
                                "\(Int(engine.metalTargetNits)) nits (\(String(format: "%.2f", engine.targetNitsScale))×)"
                            )
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                        }
                        Slider(value: $engine.targetNitsScale, in: 0.5...2.0)
                    }

                    // Exposure
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Output Exposure")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(String(format: "%.2f×", engine.metalExposure))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Slider(value: $engine.metalExposure, in: 0.5...2.0)
                    }

                    // Shadow Lift
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Shadow Lift")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(String(format: "%.3f", engine.metalShadowLift))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Slider(value: $engine.metalShadowLift, in: 0.0...0.1)
                    }

                    if engine.videoDolbyVisionProfile != nil {
                        Toggle(isOn: $engine.applyDolbyVisionTrims) {
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
