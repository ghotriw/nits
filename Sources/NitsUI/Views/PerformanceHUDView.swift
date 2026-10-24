import NitsCore
import SwiftUI

/// An unobtrusive real-time telemetry HUD for audio/video playback and rendering diagnostics.
/// Stylistically aligned with the glassmorphic player OSD with structured information sections.
public struct PerformanceHUDView: View {
    let engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        let metrics = engine.currentMetrics
        VStack(alignment: .leading, spacing: 8) {
            // Header
            headerView(metrics: metrics)

            // Section 1: Color & Tone-Mapping Pipeline
            if !metrics.resolution.isEmpty || !metrics.codecName.isEmpty || !metrics.toneMapPipeline.isEmpty {
                dividerView
                colorPipelineSection(metrics: metrics)
            }

            // Section 2: Playback & Pacing
            dividerView
            pacingSection(metrics: metrics)

            // Section 3: System Resources
            dividerView
            systemSection(metrics: metrics)
        }
        .padding(12)
        .frame(width: 290)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 0)
    }

    // MARK: - Header & Badge

    private func headerView(metrics: PlayerPerformanceMonitor.Metrics) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            Text("TELEMETRY")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))

            Spacer()

            modeBadge(metrics: metrics)
        }
    }

    @ViewBuilder
    private func modeBadge(metrics: PlayerPerformanceMonitor.Metrics) -> some View {
        let mode = engine.activeRenderMode
        let (title, icon, tintColor) = badgeConfig(mode: mode, metrics: metrics)

        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(title)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(tintColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(tintColor.opacity(0.18))
                .overlay(
                    Capsule()
                        .stroke(tintColor.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    private func badgeConfig(
        mode: RenderMode,
        metrics: PlayerPerformanceMonitor.Metrics
    ) -> (title: String, icon: String, tintColor: Color) {
        if mode == .system || metrics.toneMapParams.mode == .appleXDR {
            return ("Apple XDR", "sun.max.fill", Color.accentColor)
        }
        switch metrics.toneMapParams.mode {
        case .doviL2Trim:
            return ("DV L2 Trim", "sparkles", Color(red: 0.8, green: 0.6, blue: 1.0))
        case .doviL1Auto:
            return ("DV L1 Auto", "wand.and.stars", Color.cyan)
        case .hdr10PlusDynamic:
            return ("HDR10+ Auto", "wand.and.stars", Color.orange)
        case .bt2390:
            return ("BT.2390 SDR", "display", Color.green)
        case .directSDR:
            return ("SDR Direct", "display", Color.blue)
        case .appleXDR:
            return ("Apple XDR", "sun.max.fill", Color.accentColor)
        case .none:
            if metrics.sourcePeakNits > 105 {
                return ("BT.2390 SDR", "display", Color.green)
            }
            return ("SDR Direct", "display", Color.blue)
        }
    }

    // MARK: - Section 1: Color & Tone-Mapping

    private func colorPipelineSection(metrics: PlayerPerformanceMonitor.Metrics) -> some View {
        let badge = badgeConfig(mode: engine.activeRenderMode, metrics: metrics)

        return VStack(alignment: .leading, spacing: 5) {
            sectionHeader(icon: "paintpalette.fill", title: "COLOR & PIPELINE")

            if !metrics.codecName.isEmpty || !metrics.resolution.isEmpty {
                metricRow(
                    label: "Stream:",
                    value: "\(metrics.codecName) (\(metrics.bitDepth)-bit) • \(metrics.resolution)"
                )
            }

            if !metrics.colorPrimaries.isEmpty || !metrics.transferFunction.isEmpty {
                metricRow(
                    label: "Colorspace:",
                    value: "\(metrics.colorPrimaries) / \(metrics.transferFunction)"
                )
            }

            if let dvProfile = metrics.dolbyVisionProfile {
                HStack {
                    Text("Dolby Vision:")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(dvProfile)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.85, green: 0.65, blue: 1.0))
                }
            }

            if !metrics.toneMapPipeline.isEmpty {
                metricRow(
                    label: "Active Engine:",
                    value: metrics.toneMapPipeline,
                    color: badge.tintColor
                )
            }

            if let details = toneMapDetailsString(params: metrics.toneMapParams) {
                Text(details)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, -1)
            }

            if engine.activeRenderMode == .metalToneMap && metrics.sourcePeakNits > 0 {
                metricRow(
                    label: "Peak / Target:",
                    value: String(format: "%.0f → %.0f nits", metrics.sourcePeakNits, metrics.targetNits),
                    color: Color.green.opacity(0.9)
                )
            }
        }
    }

    private func toneMapDetailsString(params: PlayerPerformanceMonitor.ToneMapParams) -> String? {
        switch params.mode {
        case .doviL2Trim:
            return String(
                format: "Slope: %.2f  Offset: %+.2f  Power: %.2f  Sat: %+.2f",
                params.slope, params.offset, params.power, params.saturation
            )
        case .doviL1Auto, .hdr10PlusDynamic:
            return String(format: "Scene Peak: %.0f nits → Target: %.0f nits", params.peakNits, params.targetNits)
        case .bt2390:
            return String(format: "Peak: %.0f nits → Target: %.0f nits", params.peakNits, params.targetNits)
        case .directSDR, .appleXDR, .none:
            return nil
        }
    }

    // MARK: - Section 2: Playback & Pacing

    private func pacingSection(metrics: PlayerPerformanceMonitor.Metrics) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader(icon: "speedometer", title: "PLAYBACK & PACING")

            HStack {
                Text("Render FPS:")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(fpsIndicatorColor(fps: metrics.renderFps))
                        .frame(width: 5, height: 5)
                    Text(String(format: "%.1f fps", metrics.renderFps))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(fpsIndicatorColor(fps: metrics.renderFps))
                }
            }

            metricRow(
                label: "Frame Delivery:",
                value: String(format: "%.2f ms", metrics.renderDurationMs),
                color: metrics.renderDurationMs > 16.6 ? .orange : .white
            )

            metricRow(
                label: "Buffer Queue:",
                value: "\(metrics.frameQueueCount) frames \(metrics.isDrainPaused ? "(Paused)" : "(Feeding)")",
                color: metrics.frameQueueCount < 5 ? .red : .white
            )

            metricRow(
                label: "A/V Sync Drift:",
                value: String(format: "%+.1f ms", metrics.avSyncDriftMs),
                color: abs(metrics.avSyncDriftMs) > 100
                    ? .red : (abs(metrics.avSyncDriftMs) > 60 ? .orange : .white)
            )

            if metrics.pipelineDroppedFrames > 0 {
                metricRow(
                    label: "Pipeline Drops:",
                    value: "\(metrics.pipelineDroppedFrames)",
                    color: .orange
                )
            }

            if metrics.speedSkippedFrames > 0 {
                let rateStr = String(format: "%.1f× speed", metrics.playbackRate)
                metricRow(
                    label: "Speed Skips:",
                    value: "\(metrics.speedSkippedFrames) (\(rateStr))",
                    color: Color(red: 0.6, green: 0.75, blue: 0.9)
                )
            }

            if engine.activeRenderMode == .system {
                metricRow(
                    label: "DisplayLayer:",
                    value: metrics.nativeLayerStatus,
                    color: metrics.nativeLayerStatus == "Rendering" ? .green : .white
                )
            }
        }
    }

    // MARK: - Section 3: System Resources

    private func systemSection(metrics: PlayerPerformanceMonitor.Metrics) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader(icon: "cpu", title: "SYSTEM")

            metricRow(
                label: "Process CPU:",
                value: String(format: "%.1f%%", metrics.cpuUsagePercent),
                color: metrics.cpuUsagePercent > 50 ? .orange : .white
            )

            metricRow(
                label: "Memory Footprint:",
                value: String(format: "%.1f MB", metrics.memoryUsageMB)
            )
        }
    }

    // MARK: - Helpers

    private var dividerView: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 0.5)
            .padding(.vertical, 1)
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text(title)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.top, 1)
    }

    private func metricRow(label: String, value: String, color: Color = .white) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func fpsIndicatorColor(fps: Double) -> Color {
        if fps >= 55.0 {
            return .green
        } else if fps >= 23.5 {
            return .white
        } else {
            return .orange
        }
    }
}
