import AppKit
import NitsCore
import SwiftUI
import UniformTypeIdentifiers

public struct QuickSubtitlesPane: View {
    @Bindable public var engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Subtitle Tracks Section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Subtitle Tracks", systemImage: "captions.bubble")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button("Load External…") {
                        loadExternalSubtitle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }

                // Off Option
                let isOff = engine.selectedSubtitleTrackId == nil
                Button {
                    engine.selectSubtitleTrack(id: nil)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isOff ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(isOff ? Color.accentColor : Color.white.opacity(0.4))
                        Text("Off")
                            .font(.system(size: 12, weight: isOff ? .semibold : .regular))
                            .foregroundStyle(isOff ? .white : .white.opacity(0.8))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isOff ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
                    )
                }
                .buttonStyle(.plain)

                if engine.subtitleTracks.isEmpty {
                    Text("No embedded subtitle tracks")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 6) {
                        ForEach(engine.subtitleTracks) { track in
                            let isSelected = track.id == engine.selectedSubtitleTrackId
                            Button {
                                engine.selectSubtitleTrack(id: track.id)
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

                                        HStack(spacing: 6) {
                                            if track.isExternal {
                                                Text("External")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.white.opacity(0.5))
                                            } else {
                                                Text("Embedded")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.white.opacity(0.5))
                                            }
                                            if track.isForced {
                                                Text("• Forced")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.white.opacity(0.5))
                                            }
                                            if track.isSDH {
                                                Text("• SDH")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.white.opacity(0.5))
                                            }
                                        }
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

            Divider()
                .overlay(Color.white.opacity(0.12))

            timingSection

            Divider()
                .overlay(Color.white.opacity(0.12))

            // Appearance & Styling Section
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Appearance", systemImage: "textformat.size")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button("Reset") {
                        withAnimation {
                            engine.subtitleFontSize = 24.0
                            engine.subtitleFontName = "System Rounded"
                            engine.subtitleFontWeight = "Semibold"
                            engine.subtitleTextColorHex = "#FFFFFF"
                            engine.subtitleBgColorHex = "#000000"
                            engine.subtitleBgOpacity = 0.65
                            UserDefaults.standard.set(24.0, forKey: PlayerConfiguration.keySubtitleFontSize)
                            UserDefaults.standard.set("System Rounded", forKey: PlayerConfiguration.keySubtitleFontName)
                            UserDefaults.standard.set("Semibold", forKey: PlayerConfiguration.keySubtitleFontWeight)
                            UserDefaults.standard.set("#FFFFFF", forKey: PlayerConfiguration.keySubtitleTextColorHex)
                            UserDefaults.standard.set("#000000", forKey: PlayerConfiguration.keySubtitleBgColorHex)
                            UserDefaults.standard.set(0.65, forKey: PlayerConfiguration.keySubtitleBgOpacity)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }

                // Font Family Picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Font Family")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    Picker("Font Family", selection: $engine.subtitleFontName) {
                        Section("System Designs") {
                            Text("Rounded").tag("System Rounded")
                            Text("Standard (SF Pro)").tag("System")
                            Text("Serif (New York)").tag("System Serif")
                            Text("Monospaced (SF Mono)").tag("System Monospaced")
                        }
                        Section("Standard Fonts") {
                            ForEach(
                                [
                                    "Helvetica Neue", "Arial", "Avenir Next", "Futura", "Trebuchet MS", "Verdana",
                                    "Menlo", "Georgia",
                                ], id: \.self
                            ) { name in
                                Text(name).tag(name)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: engine.subtitleFontName) { _, newFont in
                        UserDefaults.standard.set(newFont, forKey: PlayerConfiguration.keySubtitleFontName)
                    }
                }

                // Font Weight Picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Font Weight")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    Picker("Font Weight", selection: $engine.subtitleFontWeight) {
                        Text("Regular").tag("Regular")
                        Text("Medium").tag("Medium")
                        Text("Semibold").tag("Semibold")
                        Text("Bold").tag("Bold")
                        Text("Heavy").tag("Heavy")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: engine.subtitleFontWeight) { _, newWeight in
                        UserDefaults.standard.set(newWeight, forKey: PlayerConfiguration.keySubtitleFontWeight)
                    }
                }

                // Font Size Slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Font Size")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("\(Int(engine.subtitleFontSize)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Slider(value: $engine.subtitleFontSize, in: 16...48, step: 1)
                        .onChange(of: engine.subtitleFontSize) { _, newSize in
                            UserDefaults.standard.set(newSize, forKey: PlayerConfiguration.keySubtitleFontSize)
                        }
                }

                // Color Pickers
                HStack(spacing: 20) {
                    // Text Color
                    HStack(spacing: 8) {
                        Text("Text Color")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        ColorPicker(
                            "",
                            selection: Binding(
                                get: { Color(hex: engine.subtitleTextColorHex) ?? .white },
                                set: { newColor in
                                    if let hex = newColor.toHex() {
                                        engine.subtitleTextColorHex = hex
                                        UserDefaults.standard.set(
                                            hex, forKey: PlayerConfiguration.keySubtitleTextColorHex)
                                    }
                                }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }

                    // Background Box Color
                    HStack(spacing: 8) {
                        Text("Box Color")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        ColorPicker(
                            "",
                            selection: Binding(
                                get: { Color(hex: engine.subtitleBgColorHex) ?? .black },
                                set: { newColor in
                                    if let hex = newColor.toHex() {
                                        engine.subtitleBgColorHex = hex
                                        UserDefaults.standard.set(
                                            hex, forKey: PlayerConfiguration.keySubtitleBgColorHex)
                                    }
                                }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }
                }

                // Background Opacity Slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Box Opacity")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("\(Int(engine.subtitleBgOpacity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Slider(value: $engine.subtitleBgOpacity, in: 0.0...1.0)
                        .onChange(of: engine.subtitleBgOpacity) { _, newOpacity in
                            UserDefaults.standard.set(newOpacity, forKey: PlayerConfiguration.keySubtitleBgOpacity)
                        }
                }
            }
        }
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Timing", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if engine.subtitleDelay != 0 {
                    Button("Reset") {
                        engine.resetSubtitleDelay()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            }

            HStack(spacing: 8) {
                Text("Delay")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                delayStepButton(systemImage: "minus", delta: -0.1)
                TextField(
                    "Delay",
                    value: Binding(
                        get: { engine.subtitleDelay },
                        set: { engine.setSubtitleDelay($0) }
                    ),
                    format: .number.precision(.fractionLength(1...3))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 70)
                Text("s")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                delayStepButton(systemImage: "plus", delta: 0.1)
            }

            Text("Positive shows subtitles later. Z / X shift by 0.1 s while playing.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func delayStepButton(systemImage: String, delta: Double) -> some View {
        Button {
            engine.stepSubtitleDelay(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
    }

    private func loadExternalSubtitle() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Subtitle File"
        openPanel.prompt = "Load"
        openPanel.allowedContentTypes = [
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "vtt"),
            UTType(filenameExtension: "ass"),
            UTType(filenameExtension: "ssa"),
        ].compactMap { $0 }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        if openPanel.runModal() == .OK, let url = openPanel.url {
            engine.loadExternalSubtitle(url: url)
        }
    }
}
