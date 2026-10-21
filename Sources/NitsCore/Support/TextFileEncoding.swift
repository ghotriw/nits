import CoreFoundation
import Foundation

/// How text files (subtitles, playlists) are decoded, in mpv's order (`--sub-codepage`): by their byte order mark, as
/// UTF-8 when they are valid UTF-8, in the encoding the user chose, in the one Foundation's detector and a check of the
/// words find (`guessed`), else in the first of a few single-byte code pages that decodes them.
public enum TextFileEncoding {
    /// What tells a file's encoding besides its bytes.
    struct Hints: Sendable, Equatable {
        /// The user's choice for files that aren't Unicode; `nil` leaves it to the detector.
        var encoding: String.Encoding?
        /// The language of the text, from the file's name (`film.he.srt`): the Hebrew, Arabic and Thai code pages are
        /// taken only with it. Only the file's own word is taken: a wrong language misleads the detector (Ukrainian in
        /// Windows-1251 said to be English comes out Latin-1), so the user's preferred languages aren't used.
        var language: String?
    }

    /// Tried in order when no candidate of `guessed` decodes a file.
    static let fallbacks: [String.Encoding] = [.windowsCP1251, .windowsCP1252, .isoLatin1]

    /// How much of a whole file the encoding is judged by: the detector takes 150 ms for 240 KB.
    static let sampleLength = 64 << 10

    /// The encoding of `data`, the whole file or (`isPrefix`) its beginning, which may end inside a character. A whole
    /// file longer than `sampleLength` is judged by its beginning; only when the encoding found there doesn't decode
    /// all of it (Polish lines after 64 KB of English ones) is all of it looked at.
    static func detect(_ data: Data, isPrefix: Bool = false, hints: Hints = Hints()) -> String.Encoding? {
        if !isPrefix, data.count > sampleLength,
            let encoding = detect(data.prefix(sampleLength), isPrefix: true, hints: hints),
            String(data: data, encoding: encoding) != nil
        {
            return encoding
        }
        if hasUTF16ByteOrderMark(data) { return .utf16 }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if isUTF8(data, isPrefix: isPrefix) { return .utf8 }
        // A beginning is judged up to its last line feed, which no character of these encodings has in its bytes.
        let text = isPrefix ? data.lastIndex(of: 0x0A).map { Data(data.prefix(through: $0)) } ?? data : data
        if let encoding = hints.encoding, String(data: text, encoding: encoding) != nil { return encoding }
        if let guessed = guessed(text, language: hints.language) { return guessed }
        return fallbacks.first { String(data: text, encoding: $0) != nil }
    }

    /// The text of a whole file, `nil` when no encoding decodes it.
    static func decode(_ data: Data, hints: Hints = Hints()) -> (text: String, encoding: String.Encoding)? {
        guard let encoding = detect(data, hints: hints), let text = String(data: data, encoding: encoding) else {
            return nil
        }
        return (text, encoding)
    }

    /// Whether the beginning of a file is binary rather than text: zero bytes, which text has none of outside UTF-16
    /// (a VobSub `.sub` without its index is MPEG program stream).
    static func looksBinary(_ prefix: Data) -> Bool {
        !hasUTF16ByteOrderMark(prefix) && prefix.contains(0)
    }

    /// `data` as UTF-8 without a byte order mark: decoded in its encoding (`detect`) and encoded again. For a prefix, a
    /// character cut at the end is left out. What FFmpeg's subtitle demuxers read: most of them look for ASCII in the
    /// bytes, so UTF-16 is lost on them, and its decoders drop lines that aren't UTF-8.
    static func utf8(_ data: Data, isPrefix: Bool = false, hints: Hints = Hints()) -> Data? {
        guard let encoding = detect(data, isPrefix: isPrefix, hints: hints) else { return nil }
        for cut in 0...(isPrefix ? min(3, data.count) : 0) {
            guard var text = String(data: data.dropLast(cut), encoding: encoding) else { continue }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return Data(text.utf8)
        }
        return nil
    }

    private static func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    }

    private static func isUTF8(_ data: Data, isPrefix: Bool) -> Bool {
        guard isPrefix else { return String(data: data, encoding: .utf8) != nil }
        // A cut character takes up to three bytes at the end; something must be left to decode.
        return (0...max(0, min(3, data.count - 1))).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
    }

    /// The encoding of text that is neither Unicode nor in the user's choice; `nil` when no candidate decodes it.
    /// Foundation's detector knows letters by their lower case and needs more than a few of them: lines in capitals,
    /// which forced subtitles often are, it takes for ISO Latin 2, Thai, Arabic, Hebrew or GB 18030 (`ЇЖАК`), a line of
    /// Cyrillic for Latin-1, `It costs £5` for Shift JIS. So only some of its guesses are taken as they are: a CJK
    /// encoding whose text holds no half-width katakana and doesn't read as Cyrillic (`multiByte`,
    /// `readsAsCyrillic`), or the code page of a caseless script with its language in the
    /// file's name (`caselessCodePages`). A guess of a cased script's code page (`casedCodePages`, or the one that
    /// reads an ISO Latin guess the same: ISO Latin 7 is Windows-1257) competes with Windows-1251 and 1252 instead:
    /// the one reading as fewer odd words wins (`oddWords`), earlier ones on a tie.
    private static func guessed(_ data: Data, language: String?) -> String.Encoding? {
        let language = language.flatMap(TrackAutoSelection.languageCode)
        var guess: String.Encoding?
        if let (encoding, text) = detected(data, language: language) {
            // A Windows code page reading the same text stands for an ISO one (ISO 8859-8 for Hebrew).
            if let language, let codePage = caselessCodePages[language], String(data: data, encoding: codePage) == text
            {
                return codePage
            }
            if multiByte.contains(encoding),
                !text.unicodeScalars.contains(where: { (0xFF61...0xFF9F).contains($0.value) }), !readsAsCyrillic(data)
            {
                return encoding
            }
            if casedCodePages.contains(encoding) {
                guess = encoding
            } else {
                guess = casedCodePages.first { String(data: data, encoding: $0) == text }
            }
        }
        let candidates = [guess, .windowsCP1251, .windowsCP1252].compactMap { $0 }.compactMap { encoding in
            String(data: data, encoding: encoding).map { (encoding, oddWords(in: $0, encoding: encoding)) }
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    /// Foundation's guess and the text in it. Checked, as it takes UTF-8 that ends inside a character for UTF-8, which
    /// `String(data:encoding:)` refuses.
    private static func detected(_ data: Data, language: String?) -> (String.Encoding, String)? {
        var options: [StringEncodingDetectionOptionsKey: Any] = [.allowLossyKey: false]
        if let language { options[.likelyLanguageKey] = language }
        let raw = NSString.stringEncoding(
            for: data, encodingOptions: options, convertedString: nil, usedLossyConversion: nil)
        let encoding = String.Encoding(rawValue: raw)
        guard raw != 0, let text = String(data: data, encoding: encoding) else { return nil }
        return (encoding, text)
    }

    /// Words, from their first letter to their last, that text read in the wrong code page makes: a character outside
    /// ASCII that isn't a letter inside one (`Київ` in Windows-1252 is `Êè¿â`); in Cyrillic or Greek, Latin and other
    /// letters in one (`Ça va` in Windows-1251 is `Сa va`); in a Latin script, three letters or more and none of them
    /// ASCII (`ÏÐÈÂ²Ò`).
    static func oddWords(in text: String, encoding: String.Encoding) -> Int {
        let isLatin = encoding != .windowsCP1251 && encoding != .windowsCP1253
        return text.split(whereSeparator: \.isWhitespace).count { word in
            let scalars = word.unicodeScalars
            guard let first = scalars.firstIndex(where: isLetter), let last = scalars.lastIndex(where: isLetter) else {
                return false
            }
            let letters = scalars[first...last]
            if letters.contains(where: { !$0.isASCII && !isLetter($0) }) { return true }
            let hasASCII = letters.contains { $0.isASCII && isLetter($0) }
            let hasOther = letters.contains { !$0.isASCII && isLetter($0) }
            return isLatin ? !hasASCII && letters.count >= 3 : hasASCII && hasOther
        }
    }

    /// Whether `data` reads as Windows-1251 without odd words (`oddWords`), a capital after a small letter in a word,
    /// or a sign Cyrillic text doesn't use (`cyrillicSigns`). Cyrillic capitals are pairs of GB 18030 bytes; CJK text
    /// in Windows-1251 has its full-width punctuation inside words (`，` is `Ј¬`), case flipping in them (`你好` is
    /// `ДгєГ`) or signs around them (`北京` is `±±ѕ©`).
    private static func readsAsCyrillic(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .windowsCP1251) else { return false }
        let flipsCase = text.split(whereSeparator: \.isWhitespace).contains { word in
            zip(word.unicodeScalars, word.unicodeScalars.dropFirst()).contains {
                $0.properties.isLowercase && $1.properties.isUppercase
            }
        }
        let hasOtherSigns = text.unicodeScalars.contains {
            !$0.isASCII && !isLetter($0) && !$0.properties.isWhitespace && !cyrillicSigns.contains($0)
        }
        return !flipsCase && !hasOtherSigns && oddWords(in: text, encoding: .windowsCP1251) == 0
    }

    /// The signs outside ASCII that Cyrillic text uses: quotes, dashes, the ellipsis, the numero sign, the middle dot.
    private static let cyrillicSigns: Set<Unicode.Scalar> = [
        "«", "»", "„", "“", "”", "‘", "’", "‹", "›", "…", "—", "–", "№", "·",
    ]

    /// A letter, or a mark combining with one: Windows-1258 writes Vietnamese tones apart (`biết` is
    /// `bi\u{EA}\u{301}t`).
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.generalCategory == .nonspacingMark
    }

    /// The CJK encodings, taken as the detector finds them: it tells them by which bytes may follow which.
    private static let multiByte: Set<String.Encoding> = [
        .shiftJIS, .japaneseEUC, encoding(.dosKorean), encoding(.EUC_KR), encoding(.GB_18030_2000),
        encoding(.dosChineseSimplif), encoding(.big5), encoding(.dosChineseTrad),
    ]

    /// The Windows code pages of scripts with cases, the most used first: an ISO Latin guess stands for the first that
    /// reads it the same.
    private static let casedCodePages: [String.Encoding] = [
        .windowsCP1252, .windowsCP1250, encoding(.windowsBalticRim), .windowsCP1254, encoding(.windowsVietnamese),
        .windowsCP1251, .windowsCP1253,
    ]

    /// Code pages of scripts without cases, by language: taken only with the language in the file's name.
    private static let caselessCodePages: [String: String.Encoding] = [
        "he": encoding(.windowsHebrew), "yi": encoding(.windowsHebrew), "ar": encoding(.windowsArabic),
        "fa": encoding(.windowsArabic), "ur": encoding(.windowsArabic), "th": encoding(.dosThai),
    ]

    /// The encodings settings offer for files the detector gets wrong (KOI8-R is taken for ISO 8859-5).
    public static let selectable: [String.Encoding] = [
        .windowsCP1250, .windowsCP1251, .windowsCP1252, .windowsCP1253, .windowsCP1254,
        encoding(.windowsHebrew), encoding(.windowsArabic), encoding(.windowsBalticRim), encoding(.windowsVietnamese),
        encoding(.dosThai), .isoLatin2, encoding(.isoLatinCyrillic), encoding(.KOI8_R), encoding(.KOI8_U),
        .shiftJIS, .japaneseEUC, encoding(.dosKorean), encoding(.GB_18030_2000), encoding(.dosChineseTrad),
    ]

    /// The encoding's IANA name (`windows-1250`), as settings store it.
    public static func name(of encoding: String.Encoding) -> String? {
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        return CFStringConvertEncodingToIANACharSetName(cfEncoding) as String?
    }

    /// The encoding of an IANA name, `nil` for one Foundation doesn't know.
    public static func encoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}
