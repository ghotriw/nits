import CoreFoundation
import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("Encoding of text files without a byte order mark")
@MainActor
struct TextFileEncodingTests {
    private func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    private func srt(_ text: String) -> String {
        "1\n00:00:01,000 --> 00:00:03,000\n\(text)\n\n2\n00:00:04,000 --> 00:00:06,000\n- Ok.\n"
    }

    private func write(_ text: String, named name: String, encoding: String.Encoding) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try #require(text.data(using: encoding)).write(to: url)
        return url
    }

    @Test("Code pages other than Windows-1251, single- and double-byte, are detected")
    func detectsCodePages() throws {
        let samples: [(String.Encoding, String)] = [
            (.windowsCP1250, "Cześć, jak się masz? Nie wiem, co jej powiedzieć.\nGdzie byłeś wczoraj wieczorem?"),
            (.windowsCP1251, "Привіт, як справи? Я не знаю, що їй сказати.\nДе ти був учора ввечері?"),
            (.windowsCP1252, "Où étais-tu hier soir ? Je ne sais pas quoi lui dire. Ça va."),
            (.windowsCP1253, "Γεια σου, τι κάνεις; Δεν ξέρω τι να της πω.\nΠού ήσουν χθες το βράδυ;"),
            (encoding(.windowsBalticRim), "Ačiū, labai gražu. Nežinau, ką jai pasakyti.\nKur tu buvai vakar vakare?"),
            (encoding(.dosKorean), "안녕하세요, 어떻게 지내세요? 그녀에게 무슨 말을 해야 할지 모르겠어요."),
            (.shiftJIS, "こんにちは、お元気ですか？彼女に何と言えばいいか分かりません。"),
            (encoding(.GB_18030_2000), "你好，你怎么样？我不知道该对她说什么。"),
            (encoding(.GB_18030_2000), "你好。"),
            (encoding(.big5), "你好，你怎麼樣？我不知道該對她說什麼。"),
        ]
        for (encoding, text) in samples {
            let data = try #require(srt(text).data(using: encoding))
            #expect(TextFileEncoding.decode(data)?.text == srt(text), "\(String.localizedName(of: encoding))")
        }
    }

    @Test("A line or two of Cyrillic, in capitals too, reads as Windows-1251, not as what the detector takes it for")
    func shortCyrillic() throws {
        for text in [
            srt("Київ, 1987"), srt("КИЇВ, 1987\n\n2\n00:00:04,000 --> 00:00:06,000\nЦІЛКОМ ТАЄМНО"),
            srt("ШТАБ-КВАРТИРА\n\n2\n00:00:04,000 --> 00:00:06,000\nТРИ РОКИ ПОТОМУ\n\nЗАЛИШ МЕНЕ В СПОКОЇ"),
            srt("Да."), srt("ЇЖАК"), srt("ГОТЕЛЬ"), srt("ВХІД\n\n2\n00:00:04,000 --> 00:00:06,000\nАПТЕКА"),
        ] {
            let data = try #require(text.data(using: .windowsCP1251))
            #expect(TextFileEncoding.decode(data)?.text == text)
        }
    }

    @Test("A file of a single short CJK line is CJK, though its Windows-1251 reading has few letters")
    func shortCJK() throws {
        let samples: [(String.Encoding, String)] = [
            (encoding(.GB_18030_2000), "北京"), (.shiftJIS, "病院"), (.shiftJIS, "本当に"), (encoding(.dosKorean), "어디 가요"),
        ]
        for (encoding, line) in samples {
            let data = try #require(srt(line).data(using: encoding))
            #expect(TextFileEncoding.decode(data)?.text == srt(line), "\(line)")
        }
    }

    @Test("Windows-1252 with signs that are letters in Windows-1251, or an accented capital first, stays Western")
    func shortWestern() throws {
        for text in [
            srt("¿Qué tal? No sé qué decirle."), srt("Hola, ¿cómo estás?\n¡Vámonos de aquí!"),
            srt("Il fait 20° dehors, à peu près ½ de plus."), srt("Ça va?"), srt("ÉCOUTE!"),
        ] {
            let data = try #require(text.data(using: .windowsCP1252))
            #expect(TextFileEncoding.decode(data)?.text == text)
        }
    }

    @Test("Vietnamese tones, which Windows-1258 writes as combining marks, make no odd word; Windows-1252 letters do")
    func vietnameseTones() {
        // "Tôi không biết": ô, ê precomposed, the acute on ê apart, as Windows-1258 decodes.
        #expect(
            TextFileEncoding.oddWords(
                in: "T\u{F4}i kh\u{F4}ng bi\u{EA}\u{301}t", encoding: encoding(.windowsVietnamese)) == 0)
        #expect(
            TextFileEncoding.oddWords(in: "Ïðèâ³ò, ÿê ñïðàâè?", encoding: .windowsCP1252) == 2,
            "ÿê is too short to tell")
    }

    @Test("Arabic and Thai code pages are taken with the language from the file's name")
    func caselessScripts() throws {
        let samples: [(String.Encoding, String, String)] = [
            (encoding(.windowsArabic), "ara", "مرحبا، كيف حالك؟ لا أعرف ماذا أقول لها.\nأين كنت الليلة الماضية؟"),
            (encoding(.dosThai), "th", "สวัสดี คุณเป็นอย่างไรบ้าง ฉันไม่รู้ว่าจะพูดอะไรกับเธอ"),
        ]
        for (encoding, language, text) in samples {
            let data = try #require(srt(text).data(using: encoding))
            #expect(TextFileEncoding.decode(data, hints: .init(language: language))?.text == srt(text), "\(language)")
            #expect(TextFileEncoding.detect(data) != encoding, "\(language)")
        }
    }

    @Test("A file longer than the sample is judged by its beginning, and by all of it when that doesn't decode it")
    func longFiles() throws {
        let english = String(repeating: srt("Where were you last night?"), count: 2_000)
        let polish = srt("Gdzie byłeś wczoraj wieczorem? Nie wiem, co jej powiedzieć.")
        for text in [english + polish, String(repeating: polish, count: 1_000)] {
            let data = try #require(text.data(using: .windowsCP1250))
            #expect(data.count > TextFileEncoding.sampleLength)
            #expect(TextFileEncoding.decode(data)?.text == text)
        }
    }

    @Test("Hebrew in Windows-1255 needs the language from the file's name")
    func hebrewNeedsLanguage() throws {
        let text = srt("שלום, מה שלומך? אני לא יודע מה להגיד לה.\nאיפה היית אתמול בערב?")
        let data = try #require(text.data(using: encoding(.windowsHebrew)))
        #expect(TextFileEncoding.decode(data, hints: .init(language: "heb"))?.text == text)
        #expect(TextFileEncoding.detect(data) != encoding(.windowsHebrew))

        let url = try write(text, named: "film.he.srt", encoding: encoding(.windowsHebrew))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.subtitles.addExternalFile(url: url).first)
        #expect(engine.subtitles.loadedDocuments[id]?.cues.first?.text.hasPrefix("שלום") == true)
    }

    @Test("The chosen encoding reads what the detector gets wrong, but not Unicode files")
    func chosenEncoding() throws {
        let koi8 = encoding(.KOI8_R)
        let text = srt("Привет, как дела? Где ты был вчера вечером?")
        let data = try #require(text.data(using: koi8))
        #expect(TextFileEncoding.decode(data, hints: .init(encoding: koi8))?.text == text)
        let utf8 = Data(text.utf8)
        #expect(TextFileEncoding.detect(utf8, hints: .init(encoding: koi8)) == .utf8)

        let url = try write(text, named: "film.srt", encoding: koi8)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var configuration = PlayerConfiguration()
        configuration.subtitleEncoding = koi8
        let engine = PlayerEngine.makeForTesting(configuration: configuration)
        let id = try #require(engine.subtitles.addExternalFile(url: url).first)
        #expect(engine.subtitles.loadedDocuments[id]?.cues.first?.text == "Привет, как дела? Где ты был вчера вечером?")
    }

    @Test("A beginning cut inside a double-byte character is judged up to its last line")
    func cutPrefix() throws {
        let text = """
            {1}{1}25
            {25}{75}안녕하세요, 어떻게 지내세요?
            {100}{150}그녀에게 무슨 말을 해야 할지 모르겠어요.
            {200}{250}어젯밤에 어디 있었어요?
            """
        let data = try #require(text.data(using: encoding(.dosKorean)))
        let prefix = data.dropLast(1)
        #expect(TextFileEncoding.detect(prefix, isPrefix: true) == encoding(.dosKorean))
        #expect(TextFileEncoding.utf8(prefix, isPrefix: true) == Data(String(text.dropLast()).utf8))
    }

    @Test("Every encoding settings offer survives its stored name")
    func storedNames() {
        for encoding in TextFileEncoding.selectable {
            let name = TextFileEncoding.name(of: encoding)
            #expect(name.flatMap(TextFileEncoding.encoding(named:)) == encoding, "\(name ?? "-")")
        }
        #expect(TextFileEncoding.encoding(named: "") == nil)

        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.subtitleEncoding = .windowsCP1250
        config.saveToUserDefaults(userDefaults: defaults)
        #expect(PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults).subtitleEncoding == .windowsCP1250)
        config.subtitleEncoding = nil
        config.saveToUserDefaults(userDefaults: defaults)
        #expect(PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults).subtitleEncoding == nil)
    }

    @Test("A playlist in Windows-1250 names its files right")
    func playlist() throws {
        let url = try write("#EXTM3U\nŻółć.mkv\nCześć.mkv\n", named: "list.m3u", encoding: .windowsCP1250)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(PlaylistParser.parse(url: url).map { $0.url.lastPathComponent } == ["Żółć.mkv", "Cześć.mkv"])
    }
}
