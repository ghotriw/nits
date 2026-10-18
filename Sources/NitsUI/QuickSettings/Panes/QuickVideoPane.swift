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
