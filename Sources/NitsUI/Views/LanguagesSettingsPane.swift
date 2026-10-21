import NitsCore
import SwiftUI

/// Settings tab for the languages that choose the audio and subtitle tracks a media starts with.
struct LanguagesSettingsPane: View {
    @AppStorage(PlayerConfiguration.keyAudioLanguages)
    private var audioLanguages: String = ""

    @AppStorage(PlayerConfiguration.keySubtitleLanguages)
    private var subtitleLanguages: String = ""

    @AppStorage(PlayerConfiguration.keyForcedSubtitleSelection)
    private var forcedSubtitles: ForcedSubtitleSelection = .matchingAudio

    @AppStorage(PlayerConfiguration.keySubtitlesWithKnownAudio)
    private var subtitlesWithKnownAudio: SubtitlesWithKnownAudio = .forcedOnly

    let onChange: () -> Void

    var body: some View {
        Form {
            Section {
                LanguageListEditor(languages: list($audioLanguages))
            } header: {
                Text("Audio Languages")
            } footer: {
                Text(
                    "The first language a file has an audio track in is played. With no languages, the track the file marks default plays."
                )
            }

            Section {
                LanguageListEditor(languages: list($subtitleLanguages))
            } header: {
                Text("Subtitle Languages")
            } footer: {
                Text(
                    "Subtitles in the first of these languages a file has are shown. With no languages, the system's languages are used, and a track in them shows only when the file marks it default."
                )
            }

            Section {
                Picker("Forced subtitles", selection: $forcedSubtitles) {
                    ForEach(ForcedSubtitleSelection.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: forcedSubtitles) { _, _ in onChange() }

                Picker("When the audio is in a subtitle language", selection: $subtitlesWithKnownAudio) {
                    ForEach(SubtitlesWithKnownAudio.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: subtitlesWithKnownAudio) { _, _ in onChange() }
            } header: {
                Text("Automatic Subtitles")
            } footer: {
                Text(
                    "Forced subtitles translate only signs and lines in other languages. A subtitle file next to the video shows whatever the audio language. A track chosen by hand, or turned off, is remembered for the file and wins over these settings."
                )
            }
        }
        .formStyle(.grouped)
    }

    /// A stored comma-separated list as an array of language codes.
    private func list(_ stored: Binding<String>) -> Binding<[String]> {
        Binding(
            get: { TrackLanguagePreferences.languages(fromStored: stored.wrappedValue) },
            set: { languages in
                stored.wrappedValue = TrackLanguagePreferences.storedValue(of: languages)
                onChange()
            }
        )
    }
}

/// An ordered list of languages, most preferred first, with buttons to reorder, remove and add.
private struct LanguageListEditor: View {
    @Binding var languages: [String]

    var body: some View {
        ForEach(Array(languages.enumerated()), id: \.element) { index, code in
            HStack {
                Text("\(index + 1).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(LanguageCatalog.name(of: code))
                Spacer()
                Button {
                    languages.swapAt(index, index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .help("Move up")
                Button {
                    languages.swapAt(index, index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == languages.count - 1)
                .help("Move down")
                Button {
                    languages.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .help("Remove")
            }
            .buttonStyle(.borderless)
        }
        Menu("Add Language") {
            // Compared in one spelling: a language listed as `ukr` hides `uk`, and `nb` hides both Norwegian entries.
            let listed = Set(languages.map { TrackAutoSelection.canonicalTag($0) ?? $0 })
            ForEach(
                LanguageCatalog.all.filter { !listed.contains(TrackAutoSelection.canonicalTag($0.code) ?? $0.code) },
                id: \.code
            ) { language in
                Button(language.name) { languages.append(language.code) }
            }
        }
        .fixedSize()
    }
}

/// The ISO 639-1 languages, named in the user's language.
private enum LanguageCatalog {
    static let all: [(code: String, name: String)] = Locale.LanguageCode.isoLanguageCodes
        .map(\.identifier)
        .filter { $0.count == 2 }
        .compactMap { code in Locale.current.localizedString(forLanguageCode: code).map { (code, capitalized($0)) } }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code).map(capitalized) ?? code
    }

    private static func capitalized(_ name: String) -> String {
        name.prefix(1).capitalized(with: .current) + name.dropFirst()
    }
}
