import Foundation
import Testing

@testable import NitsCore

@Suite("Bitmap subtitles (PGS)")
struct BitmapSubtitleTests {
    @Test("A PGS stream is listed as a bitmap track")
    func listsBitmapTrack() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .pgsSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        #expect(demuxer.subtitleTracks.count == 1)
        #expect(track.format == .bitmap)
        #expect(track.language == "eng")
    }

    @Test("Display sets become image cues: a cleared one ends at the clear, an open one at the fallback")
    func extractsImageCues() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .pgsSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        let document = try #require(demuxer.loadSubtitleDocument(for: track.id, url: path, headers: [:]))

        #expect(document.cues.isEmpty)
        let cues = document.imageCues
        try #require(cues.count == 2, "Cues: \(cues.map { ($0.startTime, $0.endTime) })")
        #expect(abs(cues[0].startTime) < 0.01)
        #expect(abs(cues[0].endTime - 1.5) < 0.01)
        #expect(abs(cues[1].startTime - 2.5) < 0.01)
        #expect(abs(cues[1].endTime - (2.5 + BitmapSubtitleDecoder.fallbackDuration)) < 0.01)

        #expect(cues[0].canvasWidth == 320 && cues[0].canvasHeight == 240)
        let region = try #require(cues[0].regions.first)
        let bar = SyntheticTestMediaFactory.pgsBar
        #expect((region.x, region.y, region.width, region.height) == (bar.x, bar.y, bar.width, bar.height))

        // The palette entry is opaque white: every pixel of the bar.
        let pixels = region.premultipliedBGRA()
        try #require(pixels.count == bar.width * bar.height * 4)
        #expect(pixels.allSatisfy { $0 >= 0xF0 }, "The bar isn't white and opaque")

        #expect(document.activeImageCues(at: 1.0).map(\.id) == [cues[0].id])
        #expect(document.activeImageCues(at: 2.0).isEmpty)
        #expect(document.activeImageCues(at: 4.0).map(\.id) == [cues[1].id])
    }

    @Test("Premultiplying scales color by alpha and leaves unknown indices transparent")
    func premultiplies() {
        let region = SubtitleImageCue.Region(
            x: 0, y: 0, width: 3, height: 1, indices: Data([0, 1, 9]), palette: [0xFF20_4080, 0x8000_FF00])
        let pixels = [UInt8](region.premultipliedBGRA())
        #expect(Array(pixels[0..<4]) == [0x80, 0x40, 0x20, 0xFF])  // B G R A, opaque
        #expect(Array(pixels[4..<8]) == [0x00, 0x80, 0x00, 0x80])  // green at half alpha
        #expect(Array(pixels[8..<12]) == [0, 0, 0, 0])
    }

    @Test("The engine shows an image cue while it is due, and reports no text cues for it", .hostDependent)
    @MainActor
    func engineShowsImageCue() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .pgsSubtitlesMKV) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(engine.isLoaded)
        let track = try #require(engine.subtitleTracks.first)
        var textReports = 0
        engine.onSubtitleCuesChanged = { _ in textReports += 1 }

        engine.activeSubtitleDocument = SubtitleDocument(
            cues: [],
            imageCues: [
                SubtitleImageCue(id: 0, startTime: 1, endTime: 2, canvasWidth: 320, canvasHeight: 240, regions: [])
            ])
        engine.selectedSubtitleTrackId = track.id
        engine.updateActiveSubtitles(at: 1.5)
        #expect(engine.currentSubtitleImages.map(\.id) == [0])
        engine.updateActiveSubtitles(at: 2.5)
        #expect(engine.currentSubtitleImages.isEmpty)
        #expect(engine.currentSubtitleCues.isEmpty)
        #expect(textReports == 0)
    }
}

@Suite("External bitmap subtitle files")
struct ExternalBitmapSubtitleFileTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeVobSubIndex(to url: URL) throws {
        let palette = Array(repeating: "ffffff", count: 16).joined(separator: ", ")
        let index = """
            # VobSub index file, v7 (do not modify this line!)
            size: 720x480
            palette: \(palette)

            id: en, index: 0
            timestamp: 00:00:01:000, filepos: 000000000

            id: uk, index: 1
            timestamp: 00:00:02:000, filepos: 000000000

            """
        try index.write(to: url, atomically: true, encoding: .utf8)
        try Data().write(to: url.deletingPathExtension().appendingPathExtension("sub"))
    }

    @Test("Subtitle extensions: text, ASS and bitmap files load, a bare .sub resolves to its index")
    func classifiesExtensions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.srt", "a.VTT", "a.ass", "a.SSA", "a.sup", "a.idx"] {
            #expect(SidecarSubtitles.isSubtitleFile(directory.appendingPathComponent(name)), "\(name)")
        }
        #expect(SidecarSubtitles.isBitmapSubtitleFile(directory.appendingPathComponent("a.SUP")))
        #expect(!SidecarSubtitles.isBitmapSubtitleFile(directory.appendingPathComponent("a.srt")))
        for name in ["a.sub"] {
            let url = directory.appendingPathComponent(name)
            #expect(!SidecarSubtitles.isSubtitleFile(url) && SidecarSubtitles.isUnsupportedSubtitleFile(url), "\(name)")
        }

        let sub = directory.appendingPathComponent("movie.sub")
        #expect(SidecarSubtitles.vobSubIndex(forDataFile: sub) == nil, "No index next to it: MicroDVD text")
        try writeVobSubIndex(to: directory.appendingPathComponent("movie.idx"))
        #expect(SidecarSubtitles.vobSubIndex(forDataFile: sub)?.lastPathComponent == "movie.idx")
    }

    @Test("A .sup becomes one track and a two-language .idx two, each read from its own stream")
    @MainActor
    func addsTracks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sup = directory.appendingPathComponent("movie.en.sup")
        try SyntheticTestMediaFactory.pgsStream.write(to: sup)
        let index = directory.appendingPathComponent("disc.idx")
        try writeVobSubIndex(to: index)

        let engine = PlayerEngine.makeForTesting()
        let supIds = engine.addExternalSubtitles(url: sup)
        let idxIds = engine.addExternalSubtitles(url: index)
        #expect(supIds.count == 1 && idxIds.count == 2)
        #expect(engine.addExternalSubtitles(url: sup) == supIds, "Adding a file again reuses its tracks")

        let supTrack = try #require(engine.subtitleTracks.first { $0.id == supIds[0] })
        #expect(supTrack.format == .bitmap && supTrack.isExternal && supTrack.language == "en")
        let languages = idxIds.compactMap { id in engine.subtitleTracks.first { $0.id == id } }
        #expect(languages.map(\.language) == ["en", "uk"])
        #expect(languages.map(\.streamIndex) == [0, 1])
        #expect(Set(engine.subtitleTracks.map(\.id)).count == 3)
    }

    @Test("Selecting a .sup track reads its pictures in the background")
    @MainActor
    func selectingLoadsPictures() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sup = directory.appendingPathComponent("movie.sup")
        try SyntheticTestMediaFactory.pgsStream.write(to: sup)

        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: sup).first)
        engine.selectSubtitleTrack(id: id)
        for _ in 0..<100 where engine.activeSubtitleDocument == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let document = try #require(engine.activeSubtitleDocument)
        #expect(document.imageCues.count == 2)
        engine.updateActiveSubtitles(at: 1.0)
        #expect(engine.currentSubtitleImages.count == 1)
    }
}

@Suite("Bitmap subtitle list updates")
struct BitmapSubtitleListTests {
    private func cue(
        _ start: Double, _ end: Double, estimated: Bool = false, id: Int = SubtitleImageCue.makeID()
    ) -> SubtitleImageCue {
        SubtitleImageCue(
            id: id, startTime: start, endTime: end, canvasWidth: 320, canvasHeight: 240, regions: [],
            endIsEstimated: estimated)
    }

    @Test("A set with no end of its own stays until the set that clears it, however late")
    func openEndedSetLastsUntilCleared() {
        var cues = [cue(0, BitmapSubtitleDecoder.fallbackDuration, estimated: true)]
        let cleared = cues.apply(.init(truncatePreviousAt: 8, cue: nil))
        #expect(cleared)
        #expect(cues.map(\.endTime) == [8], "A cue longer than the guess was cut at the guess")
        let again = cues.apply(.init(truncatePreviousAt: 12, cue: nil))
        #expect(!again && cues.map(\.endTime) == [8], "Its end is known now")
    }

    @Test("An open-ended set is also ended by a replacing set, earlier or later than the guess")
    func openEndedSetEndsAtReplacement() {
        var cues = [cue(0, 5, estimated: true)]
        cues.apply(.init(truncatePreviousAt: 3, cue: cue(3, 8, estimated: true)))
        cues.apply(.init(truncatePreviousAt: 20, cue: cue(20, 25, estimated: true)))
        #expect(cues.map(\.endTime) == [3, 20, 25])
    }

    @Test("A set that replaces the one on screen cuts it where it starts")
    func cutsTheSetOnScreen() {
        var cues = [cue(0, 5), cue(10, 20)]
        let changed = cues.apply(.init(truncatePreviousAt: 12, cue: cue(12, 15)))
        #expect(changed)
        #expect(cues.map(\.endTime) == [5, 12, 15])
    }

    @Test("After a seek back, decoding an earlier set leaves the later ones their length")
    func seekBackKeepsLaterSets() {
        var cues = [cue(10, 20), cue(30, 40)]
        let changed = cues.apply(.init(truncatePreviousAt: 3, cue: cue(3, 6)), deduplicating: true)
        #expect(changed)
        #expect(cues.map(\.endTime) == [20, 40, 6], "The later sets were cut to nothing")
        #expect(cues.map(\.startTime) == [10, 30, 3])

        // The same set read again changes nothing.
        let again = cues.apply(.init(truncatePreviousAt: 3, cue: cue(3, 6)), deduplicating: true)
        #expect(!again && cues.count == 3)
    }

    @Test("A clearing set ends the set on screen and adds nothing")
    func clearingSet() {
        var cues = [cue(0, 9)]
        let cleared = cues.apply(.init(truncatePreviousAt: 4, cue: nil))
        #expect(cleared)
        #expect(cues.map(\.endTime) == [4])
        let late = cues.apply(.init(truncatePreviousAt: 8, cue: nil))
        #expect(!late, "Nothing was on screen at 8 s")
    }

    @Test("Cues the player makes get ids no other cue has")
    func uniqueIds() {
        #expect(Set((0..<100).map { _ in SubtitleImageCue.makeID() }).count == 100)
    }
}

@Suite("Bitmap subtitle loading")
@MainActor
struct BitmapSubtitleLoadingTests {
    private func makeSupFile() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("movie.sup")
        try SyntheticTestMediaFactory.pgsStream.write(to: file)
        return (directory, file)
    }

    @Test("A file read after another one was opened is not taken for a track of the same id")
    func staleReadIsDropped() async throws {
        let (directory, file) = try makeSupFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: file).first)
        engine.selectSubtitleTrack(id: id)

        // Another file is opened before the read ends: its tracks start at the same ids.
        engine.subtitleTracks = []
        engine.loadedSubtitleDocuments.removeAll()
        _ = engine.addExternalSubtitles(url: directory.appendingPathComponent("other.sup"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.loadedSubtitleDocuments[id] == nil)
        #expect(engine.loadingBitmapDocuments.isEmpty)
    }

    @Test("Selecting a track again while its file is read starts no second read")
    func readsOnce() throws {
        let (directory, file) = try makeSupFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: file).first)
        engine.selectSubtitleTrack(id: id)
        #expect(engine.loadingBitmapDocuments.count == 1)
        engine.selectSubtitleTrack(id: id)
        #expect(engine.loadingBitmapDocuments.count == 1)
    }

    @Test("Switching to another track takes the previous track's pictures off the screen, paused or not")
    func switchClearsPictures() throws {
        let engine = PlayerEngine.makeForTesting()
        engine.currentSubtitleImages = [
            SubtitleImageCue(id: 1, startTime: 0, endTime: 9, canvasWidth: 1, canvasHeight: 1, regions: [])
        ]
        engine.subtitleTracks = [SubtitleTrack(id: 7, title: "Other", language: "en")]
        engine.selectSubtitleTrack(id: 7)
        #expect(engine.currentSubtitleImages.isEmpty)
    }
}
