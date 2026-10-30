import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("Audio and subtitle tracks chosen on load by language and flags")
struct TrackAutoSelectionTests {
    /// The system's languages in every case: tests mustn't depend on the host's.
    private let system = ["uk-UA", "en-US"]

    private func sub(
        _ id: Int, _ language: String, forced: Bool = false, isDefault: Bool = false, external: Bool = false
    ) -> SubtitleTrack {
        SubtitleTrack(
            id: id, title: "", language: language,
            externalURL: external ? URL(fileURLWithPath: "/tmp/film.\(language).srt") : nil,
            isForced: forced, isDefault: isDefault)
    }

    private func audio(
        _ id: Int, _ language: String, isDefault: Bool = false, describesVideo: Bool = false
    ) -> MediaDemuxer.AudioTrack {
        MediaDemuxer.AudioTrack(
            id: id, streamIndex: id + 1, title: "", language: language, codecName: "aac", channels: 2,
            sampleRate: 48_000, isDefault: isDefault, describesVideo: describesVideo)
    }

    private func pick(
        _ tracks: [SubtitleTrack], audio: String?, _ preferences: TrackLanguagePreferences = .init()
    ) -> Int? {
        TrackAutoSelection.subtitleTrackId(
            in: tracks, audioLanguage: audio, preferences: preferences, systemLanguages: system)
    }

    @Test("A forced track in the audio language; the system's languages alone don't choose a full track")
    func forcedForAudioLanguage() {
        #expect(pick([sub(0, "eng"), sub(1, "eng", forced: true)], audio: "jpn") == nil)
        #expect(pick([sub(0, "jpn"), sub(1, "jpn", forced: true)], audio: "jpn") == 1)
        // Ukrainian is a system language, but the file doesn't flag the track default.
        #expect(pick([sub(0, "ukr"), sub(1, "deu")], audio: "jpn") == nil)
        #expect(pick([sub(0, "deu"), sub(1, "ukr", isDefault: true)], audio: "jpn") == 1)
        // Without subtitle languages the system's rank flagged tracks.
        #expect(pick([sub(0, "deu", isDefault: true), sub(1, "eng", isDefault: true)], audio: "jpn") == 1)
    }

    @Test("Subtitle languages choose a full track, in their order")
    func subtitleLanguages() {
        let preferences = TrackLanguagePreferences(subtitleLanguages: ["pl", "uk"])
        #expect(pick([sub(0, "eng"), sub(1, "ukr"), sub(2, "pol")], audio: "jpn", preferences) == 2)
        #expect(pick([sub(0, "eng", isDefault: true), sub(1, "ukr")], audio: "jpn", preferences) == 1)
        // The system's languages no longer count.
        #expect(pick([sub(0, "eng")], audio: "jpn", preferences) == nil)
    }

    @Test("Audio in a subtitle language: forced only by default, or all, or none")
    func knownAudio() {
        let tracks = [sub(0, "ukr"), sub(1, "eng", forced: true, isDefault: true)]
        var preferences = TrackLanguagePreferences(subtitleLanguages: ["uk"])
        #expect(pick(tracks, audio: "ukr", preferences) == 1)
        #expect(pick([sub(0, "ukr")], audio: "ukr", preferences) == nil)
        preferences.subtitlesWithKnownAudio = .all
        #expect(pick([sub(0, "ukr")], audio: "ukr", preferences) == 0)
        preferences.subtitlesWithKnownAudio = .none
        #expect(pick(tracks, audio: "ukr", preferences) == nil)
        // The system's languages make the audio known too.
        #expect(pick([sub(0, "eng", isDefault: true)], audio: "eng") == nil)
    }

    @Test("Forced subtitles never, or forced only in any language")
    func forcedModes() {
        let tracks = [sub(0, "ukr", isDefault: true), sub(1, "eng", forced: true)]
        #expect(pick(tracks, audio: "eng") == 1)
        #expect(pick(tracks, audio: "eng", .init(forcedSubtitles: .never)) == nil)
        #expect(pick(tracks, audio: "jpn", .init(forcedSubtitles: .never)) == 0)
        #expect(pick(tracks, audio: "jpn", .init(forcedSubtitles: .only)) == 1)
        #expect(pick([sub(0, "ukr", isDefault: true)], audio: "jpn", .init(forcedSubtitles: .only)) == nil)
    }

    @Test("A file next to the media comes first, a full one before a forced one, whatever the audio language")
    func sidecars() {
        let embedded = sub(0, "ukr", isDefault: true)
        #expect(pick([embedded, sub(1, "und", external: true)], audio: "jpn") == 1)
        #expect(pick([sub(0, "eng", forced: true, external: true), sub(1, "und", external: true)], audio: nil) == 1)
        // Audio in a system language limits only the media's own tracks: the file still shows.
        let english = [sub(0, "eng", isDefault: true), sub(1, "und", external: true)]
        #expect(pick(english, audio: "eng") == 1)
        #expect(pick(english, audio: "eng", .init(subtitlesWithKnownAudio: .none)) == 1)
        #expect(pick([sub(0, "eng", isDefault: true)], audio: "eng") == nil)
        // Forced only still applies to files.
        #expect(pick(english, audio: "eng", .init(forcedSubtitles: .only)) == nil)
    }

    @Test("Remote subtitle tracks obey subtitle language rules and prefer manual tracks over auto-generated ones")
    func remoteAndAutoGeneratedSubtitles() {
        let remoteAuto = SubtitleTrack(
            id: 0, title: "Ukrainian (auto-generated)", language: "uk",
            externalURL: URL(string: "https://example.com/sub/uk-auto.vtt")!,
            isAutoGenerated: true)
        let remoteManual = SubtitleTrack(
            id: 1, title: "Ukrainian", language: "uk",
            externalURL: URL(string: "https://example.com/sub/uk.vtt")!,
            isAutoGenerated: false)

        // Unlike local sidecars, remote subtitles aren't auto-selected when audio is already in a known language.
        #expect(pick([remoteAuto, remoteManual], audio: "uk") == nil)

        // When subtitle languages request Ukrainian on foreign audio, the manual track beats the auto-generated one.
        let preferences = TrackLanguagePreferences(subtitleLanguages: ["uk"])
        #expect(pick([remoteAuto, remoteManual], audio: "ja", preferences) == 1)
        #expect(pick([remoteAuto], audio: "ja", preferences) == 0)
    }

    @Test("Audio: the most preferred language, else the default flag, else the first track")
    func audioTracks() {
        let tracks = [audio(0, "eng", isDefault: true), audio(1, "ukr"), audio(2, "pol")]
        #expect(TrackAutoSelection.audioTrackId(in: tracks, languages: ["de", "pl", "uk"]) == 2)
        #expect(TrackAutoSelection.audioTrackId(in: tracks, languages: ["de"]) == 0)
        #expect(
            TrackAutoSelection.audioTrackId(in: [audio(0, "eng"), audio(1, "ukr", isDefault: true)], languages: []) == 1
        )
        #expect(TrackAutoSelection.audioTrackId(in: [audio(0, "eng"), audio(1, "ukr")], languages: []) == 0)
        #expect(TrackAutoSelection.audioTrackId(in: [], languages: ["uk"]) == nil)
    }

    @Test("Audio: in a language, a track that isn't an audio description, though both are flagged default")
    func audioDescriptions() {
        // Apple's HLS examples: the description first, both streams flagged default.
        let apple = [
            audio(0, "en-US", isDefault: true, describesVideo: true), audio(1, "en-US", isDefault: true),
        ]
        #expect(TrackAutoSelection.audioTrackId(in: apple, languages: []) == 1)
        #expect(TrackAutoSelection.audioTrackId(in: apple, languages: ["en"]) == 1)
        // The language comes first: a description in it before a plain track in another.
        let other = [audio(0, "eng", describesVideo: true), audio(1, "ukr")]
        #expect(TrackAutoSelection.audioTrackId(in: other, languages: ["en"]) == 0)
        #expect(TrackAutoSelection.audioTrackId(in: [audio(0, "eng", describesVideo: true)], languages: []) == 0)
    }

    @Test("Language tags in ISO 639-1 and both 639-2 forms match; unknown ones don't")
    func languageCodes() {
        for (tag, code) in [
            ("ukr", "uk"), ("uk", "uk"), ("ger", "de"), ("deu", "de"), ("fre", "fr"), ("chi", "zh"),
            ("pt-BR", "pt"), ("nob", "no"), ("nor", "no"), ("EN", "en"),
        ] {
            #expect(TrackAutoSelection.languageCode(tag) == code, "\(tag)")
        }
        for tag in ["", "und", "zxx", "English"] {
            #expect(TrackAutoSelection.languageCode(tag) == nil, "\(tag)")
        }
        // Another region counts against a listed language before its position does.
        #expect(TrackAutoSelection.languageRank("pt-BR", in: ["pt-PT", "pt"])?.index == 1)
        #expect(TrackAutoSelection.languageRank("pt", in: ["pt-PT"])?.regionMismatch == false)
    }

    @Test("Language settings survive user defaults")
    func storedSettings() {
        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.trackLanguages = TrackLanguagePreferences(
            audioLanguages: ["uk", "en"], subtitleLanguages: ["pl"], forcedSubtitles: .only,
            subtitlesWithKnownAudio: .all)
        config.saveToUserDefaults(userDefaults: defaults)
        #expect(
            PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults).trackLanguages == config.trackLanguages)
        #expect(
            PlayerConfiguration.loadFromUserDefaults(userDefaults: InMemoryUserDefaults()).trackLanguages == .init())
        #expect(
            TrackLanguagePreferences.languages(fromStored: "uk, ukr,pt-BR,pt-PT,,de,ger,xx,XX")
                == ["uk", "pt-BR", "pt-PT", "de", "xx"])
    }
}
