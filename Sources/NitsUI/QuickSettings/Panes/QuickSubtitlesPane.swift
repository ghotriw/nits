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

    private static func fontDisplayName(_ fontName: String) -> String {
        switch SubtitleSystemFont(rawValue: fontName) {
        case .rounded: return "Rounded"
        case .standard: return "Standard (SF Pro)"
        case .serif: return "Serif (New York)"
        case .monospaced: return "Monospaced (SF Mono)"
        case nil: return fontName
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Subtitle Tracks Section
            QuickSettingsSection("Subtitle Tracks", systemImage: "captions.bubble") {
                Button("Load External…") {
                    loadExternalSubtitle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            } content: {
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
                                            if track.isAutoGenerated {
                                                Text("• Auto")
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

            timingSection

            placementSection

            if engine.subtitles.tracks.contains(where: { $0.format == .ass }) {
                QuickSettingsSection {
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
                            QuickSettingsPicker(
                                "Dialogue in My Style",
                                valueLabel: engine.subtitles.assStyleOverride.title,
                                selection: subtitles.assStyleOverride
                            ) {
                                ForEach(AssStyleOverride.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .onChange(of: engine.subtitles.assStyleOverride) { _, mode in
                                UserDefaults.standard.set(
                                    mode.rawValue, forKey: PlayerConfiguration.keyAssStyleOverride)
                            }
                            Text("Takes the style below for plain dialogue; signs and positioned text keep the file's.")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }

            if engine.subtitles.tracks.contains(where: { $0.format == .bitmap }) {
                QuickSettingsSection {
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
                }
            }

            // Appearance & Styling Section
            QuickSettingsSection("Appearance", systemImage: "textformat.size") {
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
            } content: {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        appearanceLabel("Font Family")
                        QuickSettingsPicker(
                            "Font Family",
                            valueLabel: Self.fontDisplayName(engine.subtitles.style.fontName),
                            selection: subtitles.style.fontName
                        ) {
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
                        .onChange(of: engine.subtitles.style.fontName) { _, newFont in
                            UserDefaults.standard.set(newFont, forKey: PlayerConfiguration.keySubtitleFontName)
                        }
                    }

                    GridRow {
                        appearanceLabel("Font Weight")
                        QuickSettingsPicker(
                            "Font Weight",
                            valueLabel: engine.subtitles.style.fontWeight,
                            selection: subtitles.style.fontWeight
                        ) {
                            Text("Regular").tag("Regular")
                            Text("Medium").tag("Medium")
                            Text("Semibold").tag("Semibold")
                            Text("Bold").tag("Bold")
                            Text("Heavy").tag("Heavy")
                        }
                        .onChange(of: engine.subtitles.style.fontWeight) { _, newWeight in
                            UserDefaults.standard.set(newWeight, forKey: PlayerConfiguration.keySubtitleFontWeight)
                        }
                    }

                    GridRow {
                        appearanceLabel("Text Color")
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

                    GridRow {
                        appearanceLabel("Box Color")
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
                    QuickSettingsSlider(value: subtitles.style.fontSize, in: 16...48, step: 1)
                        .onChange(of: engine.subtitles.style.fontSize) { _, newSize in
                            UserDefaults.standard.set(newSize, forKey: PlayerConfiguration.keySubtitleFontSize)
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
                    QuickSettingsSlider(value: subtitles.style.backgroundOpacity, in: 0.0...1.0)
                        .onChange(of: engine.subtitles.style.backgroundOpacity) { _, newOpacity in
                            UserDefaults.standard.set(newOpacity, forKey: PlayerConfiguration.keySubtitleBgOpacity)
                        }
                }
            }
        }
    }

    private func appearanceLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.7))
    }

    /// Position for every kind of subtitle; scale for the ones the text style doesn't size (ASS, pictures).
    private var placementSection: some View {
        QuickSettingsSection("Placement", systemImage: "arrow.up.and.down.text.horizontal") {
            if engine.subtitles.position != 100 || engine.subtitles.scale != 1 {
                Button("Reset") {
                    engine.subtitles.position = 100
                    engine.subtitles.scale = 1
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        } content: {
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
                QuickSettingsSlider(
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
                    QuickSettingsSlider(value: subtitles.scale, in: SubtitleController.scaleRange, step: 0.05)
                        .onChange(of: engine.subtitles.scale) { _, scale in
                            UserDefaults.standard.set(scale, forKey: PlayerConfiguration.keySubtitleScale)
                        }
                }
            }
        }
    }

    private var timingSection: some View {
        QuickSettingsSection("Timing", systemImage: "clock.arrow.circlepath") {
            if engine.subtitles.delay != 0 {
                Button("Reset") {
                    engine.subtitles.resetDelay()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        } content: {
            HStack(spacing: 8) {
                Text("Delay")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                QuickSettingsStepper(
                    "Delay",
                    value: Binding(
                        get: { engine.subtitles.delay },
                        set: { engine.subtitles.setDelay($0) }
                    ),
                    format: .number.precision(.fractionLength(1...3)),
                    unit: "s",
                    onDecrement: { engine.subtitles.stepDelay(by: -0.1) },
                    onIncrement: { engine.subtitles.stepDelay(by: 0.1) }
                )
            }

            Text("Positive shows subtitles later. Z / X shift by 0.1 s while playing.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
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
            Task { await engine.subtitles.addExternal(url: url) }
        }
    }
}
