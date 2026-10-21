import Foundation
import Testing

@testable import NitsCore

@Suite("Text subtitle files FFmpeg reads (MicroDVD, SubViewer, SAMI)")
@MainActor
struct FFmpegTextSubtitleTests {
    private func write(_ text: String, named name: String, encoding: String.Encoding = .utf8) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try #require(text.data(using: encoding)).write(to: url)
        return url
    }

    /// The document of the file's track, read in the background once the track is selected.
    private func load(_ url: URL) async throws -> SubtitleDocument {
        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: url).first, "No track for \(url.lastPathComponent)")
        #expect(engine.subtitleTracks.first { $0.id == id }?.format == .text)
        #expect(engine.loadedSubtitleDocuments[id] == nil, "Read when added, not when selected")
        engine.selectSubtitleTrack(id: id)
        for _ in 0..<100 where engine.loadedSubtitleDocuments[id] == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.activeSubtitleDocument != nil)
        return try #require(engine.loadedSubtitleDocuments[id])
    }

    private func times(_ cue: SubtitleCue?) -> [Double] {
        [cue?.startTime ?? -1, cue?.endTime ?? -1].map { ($0 * 100).rounded() / 100 }
    }

    @Test("A MicroDVD file with its frame rate, in Windows-1251: lines, tags and a line with no end")
    func readsMicroDVD() async throws {
        let url = try write(
            """
            {1}{1}25
            {25}{75}Перший рядок|Другий
            {100}{}Без кінця
            {150}{200}{y:i}Курсив
            """, named: "film.uk.sub", encoding: .windowsCP1251)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cues = try await load(url).cues
        #expect(cues.map(\.text) == ["Перший рядок\nДругий", "Без кінця", "Курсив"])
        #expect(times(cues.first) == [1, 3], "Frames counted at the file's 25 fps")
        #expect(times(cues.dropFirst().first) == [4, 6], "A line with no end lasts until the next one")
    }

    @Test("A MicroDVD file without a frame rate counts at the one given, else at FFmpeg's 23.976")
    func microDVDFrameRate() throws {
        // FFmpeg takes a file for MicroDVD when its first three lines are.
        let url = try write("{50}{100}Рядок\n{150}{200}Другий\n{250}{300}Третій\n", named: "film.sub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let at50 = try #require(FFmpegTextSubtitles.read(url: url, frameRate: 50))
        #expect(times(at50.cues.first) == [1, 2])
        let fallback = try #require(FFmpegTextSubtitles.read(url: url, frameRate: nil))
        #expect(times(fallback.cues.first) == [2.09, 4.17])
    }

    @Test("A SubViewer file")
    func readsSubViewer() async throws {
        let url = try write(
            """
            [INFORMATION]
            [TITLE]Фільм
            [END INFORMATION]
            [SUBTITLE]
            00:00:01.00,00:00:02.50
            Привіт[br]світе

            00:00:03.00,00:00:04.00
            Другий

            """, named: "film.sub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cues = try await load(url).cues
        #expect(cues.map(\.text) == ["Привіт\nсвіте", "Другий"])
        #expect(times(cues.first) == [1, 2.5])
    }

    @Test("A SAMI file: empty syncs end the line before them and show nothing")
    func readsSAMI() async throws {
        let url = try write(
            """
            <SAMI><HEAD><STYLE TYPE="text/css"><!-- .UKCC { Name: Ukrainian; lang: uk-UA; } --></STYLE></HEAD>
            <BODY>
            <SYNC Start=1000><P Class=UKCC>Привіт<br>світе
            <SYNC Start=2500><P Class=UKCC>&nbsp;
            <SYNC Start=3000><P Class=UKCC>Другий
            <SYNC Start=4000><P Class=UKCC>&nbsp;
            </BODY></SAMI>
            """, named: "film.smi")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cues = try await load(url).cues
        #expect(cues.map(\.text) == ["Привіт\nсвіте", "Другий"])
        #expect(times(cues.first) == [1, 2.5])
    }

    @Test("A .sub that is neither text nor has an index adds no track")
    func rejectsUnreadableSub() throws {
        let url = try write(String(repeating: "\u{0}\u{1}\u{2}", count: 100), named: "data.sub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = PlayerEngine.makeForTesting()
        #expect(engine.addExternalSubtitles(url: url).isEmpty)
        #expect(engine.subtitleTracks.isEmpty)
    }

    @Test("A SAMI file in UTF-16 with its byte order mark reads as Unicode, not as a single-byte code page")
    func readsUTF16SAMI() async throws {
        let url = try write(
            """
            <SAMI><BODY>
            <SYNC Start=1000><P>Привіт, світе
            <SYNC Start=2000><P>&nbsp;
            </BODY></SAMI>
            """, named: "film.smi", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try await load(url).cues.map(\.text) == ["Привіт, світе"])
    }

    @Test("An SRT file in UTF-16 with its byte order mark reads as Unicode")
    func readsUTF16SRT() throws {
        let url = try write("1\n00:00:01,000 --> 00:00:02,000\nПривіт\n", named: "film.srt", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: url).first)
        #expect(engine.loadedSubtitleDocuments[id]?.cues.map(\.text) == ["Привіт"])
    }

    @Test("Encodings: a byte order mark decides, a UTF-8 prefix cut inside a character is still UTF-8")
    func detectsEncodings() throws {
        let utf8 = try #require("Привіт".data(using: .utf8))
        #expect(SubtitleTextEncoding.detect(utf8.dropLast(1), isPrefix: true) == .utf8)
        #expect(SubtitleTextEncoding.detect(utf8.dropLast(1)) == .windowsCP1251, "A whole file must decode")
        #expect(SubtitleTextEncoding.detect(Data([0xFF, 0xFE, 0x41, 0x00])) == .utf16)
        #expect(!SubtitleTextEncoding.looksBinary(Data([0xFF, 0xFE, 0x41, 0x00])), "UTF-16 has zero bytes")
        #expect(SubtitleTextEncoding.looksBinary(Data([0x00, 0x00, 0x01, 0xBA])), "MPEG program stream")
    }

    @Test("A subtitle file only opens as a subtitle format: a playlist named .sub reads as nothing")
    func opensSubtitleFormatsOnly() throws {
        let url = try write("ffconcat version 1.0\nfile 'other.mkv'\nfile 'third.mkv'\n", named: "film.sub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FFmpegTextSubtitles.read(url: url, frameRate: nil) == nil)
        #expect(!FFmpegTextSubtitles.isReadable(url))
    }

    @Test("A text file named .sub in no subtitle format adds no track that would read as nothing")
    func rejectsOtherText() throws {
        let url = try write("Just some notes,\nnot subtitles.\nThird line.\n", named: "notes.sub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = PlayerEngine.makeForTesting()
        #expect(engine.addExternalSubtitles(url: url).isEmpty)
    }

    @Test("Plain text or HTML named .smi isn't SAMI: the extension alone, which FFmpeg also scores, isn't enough")
    func rejectsTextNamedSAMI() throws {
        let engine = PlayerEngine.makeForTesting()
        for (index, text) in ["Just some notes,\nnot subtitles.\n", "<html><body><p>Hello</p></body></html>\n"]
            .enumerated()
        {
            let url = try write(text, named: "notes\(index).smi")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            #expect(engine.addExternalSubtitles(url: url).isEmpty, "\(text)")
            #expect(FFmpegTextSubtitles.read(url: url, frameRate: nil) == nil)
        }
    }

    @Test("SAMI that FFmpeg's probe misses (lower case, after white space) is still read by its demuxer")
    func readsLooseSAMI() async throws {
        let url = try write(
            """

              <sami><body>
            <sync start=1000><p>Привіт
            <sync start=2000><p>&nbsp;
            </body></sami>
            """, named: "film.smi")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try await load(url).cues.map(\.text) == ["Привіт"])
    }

    @Test("A line shorter than half a second stays that long, as embedded tracks' do")
    func keepsShortLinesReadable() async throws {
        let url = try write("{1}{1}25\n{25}{26}Мить\n{100}{150}Другий\n", named: "film.sub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(times(try await load(url).cues.first) == [1, 1.5])
    }

    @Test("Lines a few frames long one after another are held up to the next, never two on screen at once")
    func keepsShortLinesApart() async throws {
        // At 25 fps: 1.0–1.16 s, then 1.4 s; 2.0–2.04 s, the last.
        let url = try write("{1}{1}25\n{25}{29}Перший\n{35}{39}Другий\n{50}{51}Третій\n", named: "film.sub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cues = try await load(url).cues
        #expect(cues.map(times) == [[1, 1.4], [1.4, 1.9], [2, 2.5]])
    }

    @Test("A beginning too short to hold a whole UTF-8 character isn't taken for UTF-8")
    func shortPrefixIsNotUTF8() {
        #expect(SubtitleTextEncoding.detect(Data([0xD0]), isPrefix: true) == .windowsCP1251)
        #expect(SubtitleTextEncoding.detect(Data(), isPrefix: true) == .utf8)
    }

    @Test("A MicroDVD file in UTF-16 reads: FFmpeg gets it in UTF-8")
    func readsUTF16MicroDVD() async throws {
        let url = try write(
            "{1}{1}25\n{25}{75}Привіт\n{100}{150}Другий\n", named: "film.sub", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try await load(url).cues.map(\.text) == ["Привіт", "Другий"])
    }

    @Test("Windows-1251 only past the first 64 KB still reads: the encoding comes from the whole file")
    func detectsEncodingPastPrefix() async throws {
        // About 70 KB of ASCII lines, then Cyrillic.
        let ascii = (0..<2000).map { "{\($0 * 10 + 1)}{\($0 * 10 + 5)}Line number \($0) in plain ASCII" }
        let text = (["{1}{1}25"] + ascii + ["{30000}{30050}Останній рядок"]).joined(separator: "\n") + "\n"
        let url = try write(text, named: "film.sub", encoding: .windowsCP1251)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cues = try await load(url).cues
        #expect(cues.count == 2001)
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.endTime <= $1.startTime + 1e-9 }, "Lines overlap")
        #expect(cues.last?.text == "Останній рядок")
    }
}
