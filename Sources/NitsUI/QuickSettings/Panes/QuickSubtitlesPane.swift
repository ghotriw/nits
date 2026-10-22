import AppKit
import NitsCore
import SwiftUI
import UniformTypeIdentifiers

public struct QuickSubtitlesPane: View {
    @Bindable public var engine: PlayerEngine

    public init(engine: PlayerEngine) {
        self.engine = engine
    }

    /// Bindings to the engine's subtitle settings.
    private var subtitles: Bindable<SubtitleController> { Bindable(engine.subtitles) }

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
                let isOff = engine.subtitles.selectedTrackId == nil
                Button {
                    engine.subtitles.select(trackId: nil)
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

                if engine.subtitles.tracks.isEmpty {
                    Text("No embedded subtitle tracks")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 6) {
                        ForEach(engine.subtitles.tracks) { track in
                            let isSelected = track.id == engine.subtitles.selectedTrackId
                            Button {
                                engine.subtitles.select(trackId: track.id)
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

            placementSection

            Divider()
                .overlay(Color.white.opacity(0.12))

            if engine.subtitles.tracks.contains(where: { $0.format == .ass }) {
                Toggle(isOn: subtitles.usesAuthoredStyles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original ASS Styling")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(
                            "Fonts, colors and positions from the subtitle file. Off shows its text in the style below."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: engine.subtitles.usesAuthoredStyles) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: PlayerConfiguration.keyAuthoredSubtitleStyles)
                }

                if engine.subtitles.usesAuthoredStyles {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dialogue in My Style")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        Picker("Dialogue in My Style", selection: subtitles.assStyleOverride) {
                            ForEach(AssStyleOverride.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: engine.subtitles.assStyleOverride) { _, mode in
                            UserDefaults.standard.set(mode.rawValue, forKey: PlayerConfiguration.keyAssStyleOverride)
                        }
                        Text("Takes the style below for plain dialogue; signs and positioned text keep the file's.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Divider()
                    .overlay(Color.white.opacity(0.12))
            }

            if engine.subtitles.tracks.contains(where: { $0.format == .bitmap }) {
                Toggle(isOn: subtitles.showsOnlyForced) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Forced Subtitles Only")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(
                            "Picture tracks (Blu-ray, DVD) show only the lines they mark as forced: signs and foreign speech."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: engine.subtitles.showsOnlyForced) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: PlayerConfiguration.keyForcedSubtitlesOnly)
                }

                Divider()
                    .overlay(Color.white.opacity(0.12))
            }

            // Appearance & Styling Section
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Appearance", systemImage: "textformat.size")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button("Reset") {
                        withAnimation {
                            let style = SubtitleStyle()
                            engine.subtitles.style = style
                            let defaults = UserDefaults.standard
                            defaults.set(style.fontSize, forKey: PlayerConfiguration.keySubtitleFontSize)
                            defaults.set(style.fontName, forKey: PlayerConfiguration.keySubtitleFontName)
                            defaults.set(style.fontWeight, forKey: PlayerConfiguration.keySubtitleFontWeight)
                            defaults.set(style.textColorHex, forKey: PlayerConfiguration.keySubtitleTextColorHex)
                            defaults.set(style.backgroundColorHex, forKey: PlayerConfiguration.keySubtitleBgColorHex)
                            defaults.set(style.backgroundOpacity, forKey: PlayerConfiguration.keySubtitleBgOpacity)
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
                    Picker("Font Family", selection: subtitles.style.fontName) {
                        Section("System Designs") {
                            Text("Rounded").tag(SubtitleSystemFont.rounded.rawValue)
                            Text("Standard (SF Pro)").tag(SubtitleSystemFont.standard.rawValue)
                            Text("Serif (New York)").tag(SubtitleSystemFont.serif.rawValue)
                            Text("Monospaced (SF Mono)").tag(SubtitleSystemFont.monospaced.rawValue)
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
                    .onChange(of: engine.subtitles.style.fontName) { _, newFont in
                        UserDefaults.standard.set(newFont, forKey: PlayerConfiguration.keySubtitleFontName)
                    }
                }

                // Font Weight Picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Font Weight")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    Picker("Font Weight", selection: subtitles.style.fontWeight) {
                        Text("Regular").tag("Regular")
                        Text("Medium").tag("Medium")
                        Text("Semibold").tag("Semibold")
                        Text("Bold").tag("Bold")
                        Text("Heavy").tag("Heavy")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: engine.subtitles.style.fontWeight) { _, newWeight in
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
                        Text("\(Int(engine.subtitles.style.fontSize)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Slider(value: subtitles.style.fontSize, in: 16...48, step: 1)
                        .onChange(of: engine.subtitles.style.fontSize) { _, newSize in
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
                                get: { Color(hex: engine.subtitles.style.textColorHex) ?? .white },
                                set: { newColor in
                                    if let hex = newColor.toHex() {
                                        engine.subtitles.style.textColorHex = hex
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
                                get: { Color(hex: engine.subtitles.style.backgroundColorHex) ?? .black },
                                set: { newColor in
                                    if let hex = newColor.toHex() {
                                        engine.subtitles.style.backgroundColorHex = hex
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
                        Text("\(Int(engine.subtitles.style.backgroundOpacity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Slider(value: subtitles.style.backgroundOpacity, in: 0.0...1.0)
                        .onChange(of: engine.subtitles.style.backgroundOpacity) { _, newOpacity in
                            UserDefaults.standard.set(newOpacity, forKey: PlayerConfiguration.keySubtitleBgOpacity)
                        }
                }
            }
        }
    }

    /// Position for every kind of subtitle; scale for the ones the text style doesn't size (ASS, pictures).
    private var placementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Placement", systemImage: "arrow.up.and.down.text.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if engine.subtitles.position != 100 || engine.subtitles.scale != 1 {
                    Button("Reset") {
                        engine.subtitles.position = 100
                        engine.subtitles.scale = 1
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Raise")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("\(Int((100 - engine.subtitles.position).rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                // Raised by moving left to right; stored as mpv's `sub-pos` (100 at the bottom).
                Slider(
                    value: Binding(
                        get: { 100 - engine.subtitles.position }, set: { engine.subtitles.position = 100 - $0 }),
                    in: 0...50, step: 1
                )
                .onChange(of: engine.subtitles.position) { _, position in
                    UserDefaults.standard.set(position, forKey: PlayerConfiguration.keySubtitlePosition)
                }
            }

            if engine.subtitles.tracks.contains(where: { $0.format == .ass || $0.format == .bitmap }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Scale (ASS and Picture Subtitles)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("\(Int((engine.subtitles.scale * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Slider(value: subtitles.scale, in: SubtitleController.scaleRange, step: 0.05)
                        .onChange(of: engine.subtitles.scale) { _, scale in
                            UserDefaults.standard.set(scale, forKey: PlayerConfiguration.keySubtitleScale)
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
                if engine.subtitles.delay != 0 {
                    Button("Reset") {
                        engine.subtitles.resetDelay()
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
                        get: { engine.subtitles.delay },
                        set: { engine.subtitles.setDelay($0) }
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
            engine.subtitles.stepDelay(by: delta)
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
        openPanel.allowedContentTypes = SidecarSubtitles.pickableExtensions.compactMap { UTType(filenameExtension: $0) }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        if openPanel.runModal() == .OK, let url = openPanel.url {
            engine.subtitles.addExternal(url: url)
        }
    }
}
