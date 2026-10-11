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

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                }
            }
        }
    }
}
