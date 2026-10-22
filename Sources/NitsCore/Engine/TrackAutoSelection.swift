import Foundation

/// When a forced subtitle track is chosen on its own (mpv's `subs-fallback-forced`).
public enum ForcedSubtitleSelection: String, Sendable, Codable, CaseIterable, Identifiable {
    /// A forced track in the language of the selected audio: its signs and foreign-language lines.
    case matchingAudio
    /// Never a forced track.
    case never
    /// Forced tracks only, in any language; a full track, a file next to the media included, is never chosen on its
    /// own. Stricter than mpv's code for `always`, which only ranks full tracks after forced ones; this follows its
    /// documentation and the setting's name.
    case only

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .matchingAudio: "In the audio language"
        case .never: "Never"
        case .only: "Forced only"
        }
    }
}

/// Which subtitles are chosen on their own when the audio is in one of the subtitle languages
/// (mpv's `subs-with-matching-audio`).
public enum SubtitlesWithKnownAudio: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Forced tracks only: the lines in other languages (default).
    case forcedOnly
    /// Full tracks too.
    case all
    /// No subtitles.
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forcedOnly: "Forced only"
        case .all: "All"
        case .none: "None"
        }
    }
}

/// Picks the audio and subtitle tracks a media starts with when neither a request nor the saved history names them,
/// after mpv's `select_default_track`.
public enum TrackAutoSelection {
    /// The audio track in the most preferred of `languages`, else the one the file flags default, else the first; in a
    /// language, one that isn't an audio description. The default flag doesn't tell them apart: an HLS rendition's
    /// stream is flagged by its fragmented MP4 too, and Apple's examples list the description first, `DEFAULT=NO`.
    public static func audioTrackId(in tracks: [MediaDemuxer.AudioTrack], languages: [String]) -> Int? {
        let ranked = tracks.enumerated().min { lhs, rhs in
            let (l, r) = (lhs.element, rhs.element)
            let (lRank, rRank) = (languageRank(l.language, in: languages), languageRank(r.language, in: languages))
            if lRank != rRank { return isBetter(lRank, than: rRank) }
            if l.describesVideo != r.describesVideo { return !l.describesVideo }
            if l.isDefault != r.isDefault { return l.isDefault }
            return lhs.offset < rhs.offset
        }
        return ranked?.element.id
    }

    /// The subtitle track to show, or `nil` for none.
    ///
    /// A track may be chosen when it is forced and fits `preferences.forcedSubtitles`, is in one of
    /// `preferences.subtitleLanguages`, is a file next to the media, or is flagged default. With no subtitle languages
    /// set, `systemLanguages` rank the tracks but don't qualify one: a full track in the user's language shows only when
    /// the file flags it default. Audio in one of the languages limits the media's own tracks by
    /// `preferences.subtitlesWithKnownAudio`.
    public static func subtitleTrackId(
        in tracks: [SubtitleTrack], audioLanguage: String?, preferences: TrackLanguagePreferences,
        systemLanguages: [String]
    ) -> Int? {
        let usesSystemLanguages = preferences.subtitleLanguages.isEmpty
        let languages = usesSystemLanguages ? systemLanguages : preferences.subtitleLanguages
        let audioIsKnown = audioLanguage.map { languageRank($0, in: languages) != nil } ?? false

        struct Candidate {
            let track: SubtitleTrack
            let order: Int
            let rank: LanguageRank?
            let isForcedPick: Bool
        }
        var candidates: [Candidate] = []
        for (order, track) in tracks.enumerated() {
            switch preferences.forcedSubtitles {
            case .never where track.isForced, .only where !track.isForced: continue
            default: break
            }
            // A file next to the media was put there to be shown.
            if audioIsKnown, !track.isExternal {
                switch preferences.subtitlesWithKnownAudio {
                case .none: continue
                case .forcedOnly where !track.isForced: continue
                default: break
                }
            }
            let audioMatches = audioLanguage.map { languageRank(track.language, in: [$0]) != nil } ?? false
            let isForcedPick =
                track.isForced
                && (preferences.forcedSubtitles == .only
                    || (preferences.forcedSubtitles == .matchingAudio && audioMatches))
            let rank = languageRank(track.language, in: languages)
            let isLanguagePick = !usesSystemLanguages && rank != nil
            guard isForcedPick || isLanguagePick || track.isExternal || track.isDefault else { continue }
            candidates.append(Candidate(track: track, order: order, rank: rank, isForcedPick: isForcedPick))
        }

        let best = candidates.min { l, r in
            if l.track.isExternal != r.track.isExternal { return l.track.isExternal }
            if !usesSystemLanguages, l.rank != r.rank { return isBetter(l.rank, than: r.rank) }
            if l.isForcedPick != r.isForcedPick { return l.isForcedPick }
            if l.track.isDefault != r.track.isDefault { return l.track.isDefault }
            if l.track.isForced != r.track.isForced { return !l.track.isForced }
            if usesSystemLanguages, l.rank != r.rank { return isBetter(l.rank, than: r.rank) }
            return l.order < r.order
        }
        return best?.track.id
    }

    /// Where a language stands in a preference list: a region other than the listed one's (`pt-BR` for `pt-PT`)
    /// counts against it before the position does.
    struct LanguageRank: Comparable {
        let regionMismatch: Bool
        let index: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.regionMismatch ? 1 : 0, lhs.index) < (rhs.regionMismatch ? 1 : 0, rhs.index)
        }
    }

    private static func isBetter(_ lhs: LanguageRank?, than rhs: LanguageRank?) -> Bool {
        switch (lhs, rhs) {
        case (let l?, let r?): l < r
        case (.some, nil): true
        default: false
        }
    }

    /// The best match of a track's language tag (`ukr`, `en`, `pt-BR`) in `list`; `nil` when it matches none or is
    /// unknown (`und`, empty).
    static func languageRank(_ language: String, in list: [String]) -> LanguageRank? {
        guard let track = Tag(language) else { return nil }
        var best: LanguageRank?
        for (index, entry) in list.enumerated() {
            guard let wanted = Tag(entry), wanted.code == track.code else { continue }
            let mismatch = wanted.region != nil && track.region != nil && wanted.region != track.region
            let rank = LanguageRank(regionMismatch: mismatch, index: index)
            if best.map({ rank < $0 }) ?? true { best = rank }
        }
        return best
    }

    /// The language code of a tag, the same for ISO 639-1 and both 639-2 forms (`uk` / `ukr`, `de` / `deu` / `ger`).
    public static func languageCode(_ language: String) -> String? {
        Tag(language)?.code
    }

    /// A tag in one spelling per language and region (`ukr` → `uk`, `por-br` → `pt-BR`), to tell repeats apart.
    public static func canonicalTag(_ language: String) -> String? {
        Tag(language).map { tag in tag.region.map { "\(tag.code)-\($0)" } ?? tag.code }
    }

    private struct Tag {
        let code: String
        let region: String?

        init?(_ tag: String) {
            let trimmed = tag.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty, !["und", "mis", "mul", "zxx"].contains(trimmed) else { return nil }
            let primary = String(trimmed.prefix { $0 != "-" && $0 != "_" })
            let identifier = TrackAutoSelection.bibliographicCodes[primary].map {
                $0 + trimmed.dropFirst(primary.count)
            }
            let language = Locale.Language(identifier: identifier ?? trimmed)
            guard let code = language.languageCode?.identifier.lowercased(), code.count <= 3 else { return nil }
            self.code = TrackAutoSelection.equivalentCodes[code] ?? code
            self.region = language.region?.identifier.uppercased()
        }
    }

    /// ISO 639-2/B codes, which Foundation doesn't map to 639-1 (it does the 639-2/T ones): Matroska files use them.
    private static let bibliographicCodes = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr",
        "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "per": "fa",
        "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy", "scc": "sr", "scr": "hr",
    ]

    /// Codes files use for the same language: Norwegian tracks are tagged `nor` as often as `nob`.
    private static let equivalentCodes = ["nb": "no"]
}

/// The user's language preferences for choosing tracks on load.
public struct TrackLanguagePreferences: Sendable, Equatable {
    /// Audio languages, most preferred first (mpv's `alang`). Empty: the track the file flags default.
    public var audioLanguages: [String]
    /// Subtitle languages, most preferred first (mpv's `slang`). Empty: the system's languages, which only rank tracks.
    public var subtitleLanguages: [String]
    public var forcedSubtitles: ForcedSubtitleSelection
    public var subtitlesWithKnownAudio: SubtitlesWithKnownAudio

    public init(
        audioLanguages: [String] = [], subtitleLanguages: [String] = [],
        forcedSubtitles: ForcedSubtitleSelection = .matchingAudio,
        subtitlesWithKnownAudio: SubtitlesWithKnownAudio = .forcedOnly
    ) {
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.forcedSubtitles = forcedSubtitles
        self.subtitlesWithKnownAudio = subtitlesWithKnownAudio
    }

    /// A list as stored in user defaults: codes separated by commas. A language listed again, in any of its codes
    /// (`uk`, `ukr`), is dropped.
    public static func languages(fromStored value: String) -> [String] {
        var seen = Set<String>()
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { entry in
            !entry.isEmpty && seen.insert(TrackAutoSelection.canonicalTag(entry) ?? entry.lowercased()).inserted
        }
    }

    public static func storedValue(of languages: [String]) -> String {
        languages.joined(separator: ",")
    }
}
