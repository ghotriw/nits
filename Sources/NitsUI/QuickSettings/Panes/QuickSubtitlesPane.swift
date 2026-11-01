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
            mainSection

            secondSection

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
                        defaults.set(style.letterSpacing, forKey: PlayerConfiguration.keySubtitleLetterSpacing)
                        defaults.set(style.outlineWidth, forKey: PlayerConfiguration.keySubtitleOutlineWidth)
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

                sliderRow(
                    "Font Size", valueText: "\(Int(engine.subtitles.style.fontSize)) pt",
                    isDefault: engine.subtitles.style.fontSize == SubtitleStyle.defaultFontSize,
                    reset: { engine.subtitles.style.fontSize = SubtitleStyle.defaultFontSize },
                    slider: {
                        QuickSettingsSlider(value: subtitles.style.fontSize, in: 16...48, step: 1)
                            .onChange(of: engine.subtitles.style.fontSize) { _, newSize in
                                UserDefaults.standard.set(newSize, forKey: PlayerConfiguration.keySubtitleFontSize)
                            }
                    })

                sliderRow(
                    "Box Opacity", valueText: "\(Int((engine.subtitles.style.backgroundOpacity * 100).rounded()))%",
                    isDefault: engine.subtitles.style.backgroundOpacity == SubtitleStyle.defaultBackgroundOpacity,
                    reset: { engine.subtitles.style.backgroundOpacity = SubtitleStyle.defaultBackgroundOpacity },
                    slider: {
                        QuickSettingsSlider(value: subtitles.style.backgroundOpacity, in: 0.0...1.0)
                            .onChange(of: engine.subtitles.style.backgroundOpacity) { _, newOpacity in
                                UserDefaults.standard.set(
                                    newOpacity, forKey: PlayerConfiguration.keySubtitleBgOpacity)
                            }
                    })

                sliderRow(
                    "Letter Spacing", valueText: String(format: "%+.1f%%", engine.subtitles.style.letterSpacing * 100),
                    isDefault: engine.subtitles.style.letterSpacing == SubtitleStyle.defaultLetterSpacing,
                    reset: { engine.subtitles.style.letterSpacing = SubtitleStyle.defaultLetterSpacing },
                    slider: {
                        QuickSettingsSlider(
                            value: subtitles.style.letterSpacing, in: SubtitleStyle.letterSpacingRange, step: 0.005
                        )
                        .onChange(of: engine.subtitles.style.letterSpacing) { _, spacing in
                            UserDefaults.standard.set(spacing, forKey: PlayerConfiguration.keySubtitleLetterSpacing)
                        }
                    })

                sliderRow(
                    "Outline Width", valueText: "\(Int((engine.subtitles.style.outlineWidth * 100).rounded()))%",
                    isDefault: engine.subtitles.style.outlineWidth == SubtitleStyle.defaultOutlineWidth,
                    reset: { engine.subtitles.style.outlineWidth = SubtitleStyle.defaultOutlineWidth },
                    slider: {
                        QuickSettingsSlider(
                            value: subtitles.style.outlineWidth, in: SubtitleStyle.outlineWidthRange, step: 0.05
                        )
                        .onChange(of: engine.subtitles.style.outlineWidth) { _, width in
                            UserDefaults.standard.set(width, forKey: PlayerConfiguration.keySubtitleOutlineWidth)
                        }
                    })
            }
        }
    }

    private func appearanceLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.7))
    }

    /// A labelled slider with its value, and a Reset when it isn't at its default.
    private func sliderRow(
        _ title: String, valueText: String, isDefault: Bool, reset: @escaping () -> Void, slider: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                resetIcon(reset)
                    .opacity(isDefault ? 0 : 1)
                    .disabled(isDefault)
                    .accessibilityHidden(isDefault)
                Text(valueText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            slider()
        }
    }

    /// A small reset for one setting. Always laid out (hidden at the default), so a row keeps its height.
    private func resetIcon(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reset to default")
        .accessibilityLabel("Reset")
    }

    private func resetButton(_ action: @escaping () -> Void) -> some View {
        Button("Reset", action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
    }

    /// The selected track, with its own delay (kept for the file).
    private var mainSection: some View {
        let subtitles = engine.subtitles
        let selected = subtitles.tracks.first { $0.id == subtitles.selectedTrackId }
        return QuickSettingsSection("Subtitle Track", systemImage: "captions.bubble") {
            HStack(spacing: 10) {
                if subtitles.delay != 0 { resetButton { subtitles.resetDelay() } }
                loadButton { url in await subtitles.addExternal(url: url) }
            }
        } content: {
            if subtitles.tracks.isEmpty { hint("No subtitle tracks") }
            QuickSettingsPicker(
                "Subtitle Track",
                valueLabel: selected.map(TrackTitleFormatter.format) ?? "Off",
                selection: Binding(get: { subtitles.selectedTrackId }, set: { subtitles.select(trackId: $0) })
            ) {
                Text("Off").tag(Int?.none)
                ForEach(subtitles.tracks) { track in
                    Text(TrackTitleFormatter.format(track)).tag(Int?.some(track.id))
                }
            }
            if selected != nil {
                delayRow(
                    "Delay", value: subtitles.delay, set: { subtitles.setDelay($0) },
                    step: { subtitles.stepDelay(by: $0) })
                hint("Positive shows subtitles later. Z / X shift by 0.1 s while playing.")
                scaleSlider
            }
        }
    }

    /// A second track shown above the main one (which moves to the bottom), with its own delay.
    @ViewBuilder
    private var secondSection: some View {
        let subtitles = engine.subtitles
        let secondary = subtitles.secondary
        let candidates = secondary.candidates
        QuickSettingsSection("Second Subtitle Track", systemImage: "captions.bubble.fill") {
            HStack(spacing: 10) {
                if secondary.delay != 0 { resetButton { secondary.resetDelay() } }
                loadButton { url in await secondary.addExternal(url: url) }
            }
        } content: {
            QuickSettingsPicker(
                "Second Subtitle Track",
                valueLabel: candidates.first { $0.id == secondary.selectedTrackId }.map(TrackTitleFormatter.format)
                    ?? "Off",
                selection: Binding(get: { secondary.selectedTrackId }, set: { secondary.select(trackId: $0) })
            ) {
                Text("Off").tag(Int?.none)
                ForEach(candidates) { track in
                    Text(TrackTitleFormatter.format(track)).tag(Int?.some(track.id))
                }
            }
            if secondary.isActive {
                delayRow(
                    "Delay", value: secondary.delay, set: { secondary.setDelay($0) },
                    step: { secondary.stepDelay(by: $0) })
            }
            hint("Shown at the top, in plain text; the main track moves to the bottom.")
        }
    }

    private func delayRow(
        _ title: String, value: Double, set: @escaping @MainActor @Sendable (Double) -> Void,
        step: @escaping @MainActor @Sendable (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            QuickSettingsStepper(
                title,
                value: Binding(get: { value }, set: set),
                format: .number.precision(.fractionLength(1...3)),
                unit: "s",
                onDecrement: { step(-0.1) },
                onIncrement: { step(0.1) }
            )
        }
    }

    /// Asks for a subtitle file and adds it with `add`.
    private func loadButton(_ add: @escaping @MainActor (URL) async -> AddedSubtitleFiles) -> some View {
        Button("Load External…") {
            if let url = SubtitleFilePicker.pick() {
                Task { _ = await add(url) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Placement

extension QuickSubtitlesPane {
    /// The size of the kinds the text style doesn't size (ASS, pictures).
    @ViewBuilder
    fileprivate var scaleSlider: some View {
        let subtitles = engine.subtitles
        if subtitles.tracks.contains(where: { $0.format == .ass || $0.format == .bitmap }) {
            sliderRow(
                "Scale (ASS and Picture Subtitles)", valueText: "\(Int((subtitles.scale * 100).rounded()))%",
                isDefault: subtitles.scale == 1, reset: { subtitles.scale = 1 },
                slider: {
                    QuickSettingsSlider(
                        value: Bindable(subtitles).scale, in: SubtitleController.scaleRange, step: 0.05
                    )
                    .onChange(of: subtitles.scale) { _, scale in
                        UserDefaults.standard.set(scale, forKey: PlayerConfiguration.keySubtitleScale)
                    }
                })
        }
    }

    /// Where subtitles stand: from the top edge (the second track, and any line a track places at the top) and from
    /// the bottom one (mpv's `sub-pos`, stored as 100 at the edge and shown as the distance; plain text sits exactly
    /// there, ASS and pictures rise only past the default).
    fileprivate var placementSection: some View {
        let subtitles = engine.subtitles
        let secondary = subtitles.secondary
        return QuickSettingsSection("Placement", systemImage: "arrow.up.and.down.text.horizontal") {
            sliderRow(
                "Distance from Top", valueText: "\(Int((secondary.inset * 100).rounded()))%",
                isDefault: secondary.inset == SecondarySubtitles.defaultInset,
                reset: { secondary.inset = SecondarySubtitles.defaultInset },
                slider: {
                    QuickSettingsSlider(
                        value: Bindable(secondary).inset, in: SecondarySubtitles.insetRange, step: 0.01
                    )
                    .onChange(of: secondary.inset) { _, inset in
                        UserDefaults.standard.set(inset, forKey: PlayerConfiguration.keySecondarySubtitleInset)
                    }
                })
            sliderRow(
                "Distance from Bottom", valueText: "\(Int((100 - subtitles.position).rounded()))%",
                isDefault: subtitles.position == SubtitleController.defaultPosition,
                reset: { subtitles.position = SubtitleController.defaultPosition },
                slider: {
                    QuickSettingsSlider(
                        value: Binding(get: { 100 - subtitles.position }, set: { subtitles.position = 100 - $0 }),
                        in: 0...50, step: 1
                    )
                    .onChange(of: subtitles.position) { _, position in
                        UserDefaults.standard.set(position, forKey: PlayerConfiguration.keySubtitlePosition)
                    }
                })
        }
    }
}
