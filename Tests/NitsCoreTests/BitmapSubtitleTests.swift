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
        let document = try #require(
            EmbeddedSubtitleReader.extractEmbeddedSubtitles(url: path, headers: [:], streamIndex: track.streamIndex))

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

    @Test("A window of an MPEG-TS stream is read on its rebased timeline, from past its start")
    func readsTransportStreamWindow() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .dvbSubtitlesTS) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        #expect(track.format == .bitmap)
        let whole = try #require(
            EmbeddedSubtitleReader.readSubtitles(url: path, headers: [:], streamIndex: track.streamIndex, in: 0...10))
        let first = try #require(whole.bitmapOutputs.compactMap(\.cue).first)
        #expect(abs(first.startTime) < 0.05, "The bar is at \(first.startTime) s, not on the stream's own clock")
        let clears = whole.bitmapOutputs.filter { $0.cue == nil }.compactMap(\.truncatePreviousAt)
        #expect(clears.contains { abs($0 - 5.13) < 0.05 }, "Clears: \(clears)")

        // From 4 s on: the seek goes to the stream's own 5.5 s or so, and finds the clear, not the bar.
        let late = try #require(
            EmbeddedSubtitleReader.readSubtitles(url: path, headers: [:], streamIndex: track.streamIndex, in: 4...10))
        #expect(late.bitmapOutputs.compactMap(\.cue).isEmpty)
        #expect(late.bitmapOutputs.contains { ($0.truncatePreviousAt ?? 0) > 5 })
    }

    @Test("A window of a Matroska stream from past its start finds the packets in it")
    func readsMatroskaWindow() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .pgsSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        let sets = try #require(
            EmbeddedSubtitleReader.readSubtitles(url: path, headers: [:], streamIndex: track.streamIndex, in: 1...3))
        let times = sets.bitmapOutputs.compactMap(\.truncatePreviousAt).map { ($0 * 10).rounded() / 10 }
        #expect(times.contains(1.5) && times.contains(2.5), "Read: \(times)")
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
        // The document above stands for what the demuxer collected.
        engine.lastObservedLiveSubtitleVersion = try #require(engine.demuxer?.liveSubtitleVersion)
        engine.updateActiveSubtitles(at: 1.5)
        #expect(engine.currentSubtitleImages.map(\.id) == [0])
        engine.updateActiveSubtitles(at: 2.5)
        #expect(engine.currentSubtitleImages.isEmpty)
        #expect(engine.currentSubtitleCues.isEmpty)
        #expect(textReports == 0)
    }

    @Test(
        "A PGS track of a local file shows at once, from a window read, not after reading the whole file",
        .hostDependent)
    @MainActor
    func engineShowsEmbeddedTrackAtOnce() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .pgsSubtitlesMKV) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(engine.isLoaded)
        engine.pause()
        // Playback has read past the set at 0 s and its clear at 1.5 s (which the file keeps after the picture at
        // 1.67 s): only a window read reaching where playback reads from can bring both back.
        let demuxer = try #require(engine.demuxer)
        for _ in 0..<100 where demuxer.readAheadSeconds < 1.7 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(demuxer.readAheadSeconds >= 1.7, "Read ahead only to \(demuxer.readAheadSeconds) s")
        engine.selectSubtitleTrack(id: try #require(engine.subtitleTracks.first).id)
        #expect(engine.subtitleLoads.isEmpty, "No whole-file read")
        for _ in 0..<100 where engine.currentSubtitleImages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let shown = try #require(engine.currentSubtitleImages.first, "The set at 0 s never showed")
        #expect(abs(shown.startTime) < 0.01)
        #expect(abs(shown.endTime - 1.5) < 0.01, "The set ends at \(shown.endTime) s, not at its clear")
    }

    @Test("A negative delay shows a set playback hasn't read yet, read ahead in a window", .hostDependent)
    @MainActor
    func negativeDelayReadsAhead() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .pgsSubtitlesMKV) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(engine.isLoaded)
        // Paused once playing: a pause before the load starts playback is overridden by it.
        for _ in 0..<100 where !engine.isPlaying { try await Task.sleep(for: .milliseconds(10)) }
        engine.pause()
        try #require(!engine.isPlaying)
        engine.selectSubtitleTrack(id: try #require(engine.subtitleTracks.first).id)
        // Under load playback may have read past the set at 2.5 s before the pause: then it isn't missing, and there is
        // nothing to check here.
        guard let demuxer = engine.demuxer, demuxer.readAheadSeconds < 2.5 else { return }

        // At 0 s with a delay of -3 s the track is due at 3 s: the set at 2.5 s.
        engine.setSubtitleDelay(-3)
        for _ in 0..<100 where engine.currentSubtitleImages.first.map({ $0.startTime < 2 }) ?? true {
            try await Task.sleep(for: .milliseconds(20))
        }
        let shown = try #require(engine.currentSubtitleImages.first, "Nothing shown at -3 s")
        #expect(abs(shown.startTime - 2.5) < 0.01)
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

    @Test("Subtitle extensions: text, ASS and bitmap files load, a .sub resolves to its index when it has one")
    func classifiesExtensions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.srt", "a.VTT", "a.ass", "a.SSA", "a.sup", "a.idx", "a.sub", "a.SMI", "a.sami"] {
            #expect(SidecarSubtitles.isSubtitleFile(directory.appendingPathComponent(name)), "\(name)")
        }
        #expect(SidecarSubtitles.isBitmapSubtitleFile(directory.appendingPathComponent("a.SUP")))
        #expect(!SidecarSubtitles.isBitmapSubtitleFile(directory.appendingPathComponent("a.srt")))

        let sub = directory.appendingPathComponent("movie.sub")
        #expect(
            SidecarSubtitles.vobSubIndex(forDataFile: sub) == nil, "No index next to it: MicroDVD or SubViewer text")
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
        let data = directory.appendingPathComponent("disc.sub")
        #expect(engine.addExternalSubtitles(url: data) == idxIds, "A picked .sub loads through its .idx")
        let lone = directory.appendingPathComponent("microdvd.sub")
        try Data("{0}{25}Hello\n{50}{75}Second\n{100}{125}Third\n".utf8).write(to: lone)
        let loneIds = engine.addExternalSubtitles(url: lone)
        #expect(loneIds.count == 1, "A .sub with no index is text (MicroDVD)")
        #expect(engine.subtitleTracks.first { $0.id == loneIds.first }?.format == .text)

        // History restores the saved language of the index; an unknown or missing stream falls back to the first.
        #expect(engine.externalSubtitleTrack(among: idxIds, streamIndex: 1) == idxIds[1])
        #expect(engine.externalSubtitleTrack(among: idxIds, streamIndex: 7) == idxIds[0])
        #expect(engine.externalSubtitleTrack(among: idxIds, streamIndex: nil) == idxIds[0])

        let supTrack = try #require(engine.subtitleTracks.first { $0.id == supIds[0] })
        #expect(supTrack.format == .bitmap && supTrack.isExternal && supTrack.language == "en")
        let languages = idxIds.compactMap { id in engine.subtitleTracks.first { $0.id == id } }
        #expect(languages.map(\.language) == ["en", "uk"])
        #expect(languages.map(\.streamIndex) == [0, 1])
        #expect(Set(engine.subtitleTracks.map(\.id)).count == 4)
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

    @Test("A clear playback read before the window brought its set still ends that set, and applies once")
    func windowMergeReplaysEnds() {
        // Playback decoded the clear at 1.5 s (nothing to end yet) and a set at 30 s; the window brings the set at 0.
        var later = cue(30, 35, estimated: true)
        later.readSpan = 1
        var cues = [later]
        let truncations = [1.5, 30]
        let window = [BitmapSubtitleDecoder.Output(truncatePreviousAt: 0, cue: cue(0, 5, estimated: true))]
        cues.merge(window: window, span: 1, replaying: truncations)
        let sorted = cues.sorted { $0.startTime < $1.startTime }
        #expect(sorted.map(\.endTime) == [1.5, 35], "The set at 0 s lasted until 30 s")

        cues.merge(window: window, span: 1, replaying: truncations)
        #expect(cues.count == 2 && cues.sorted { $0.startTime < $1.startTime }.map(\.endTime) == [1.5, 35])
    }

    @Test("A set isn't ended by one read after a seek, which may have skipped what really ended it")
    func endsOnlyWithinStretch() {
        var cues: [SubtitleImageCue] = []
        cues.apply(.init(truncatePreviousAt: 5, cue: cue(5, 10, estimated: true)), span: 1)
        // A seek to 100: the first set there is at 103.
        cues.apply(.init(truncatePreviousAt: 103, cue: cue(103, 108, estimated: true)), span: 2)
        #expect(cues.first { $0.startTime == 5 }?.endTime == 10, "The set at 5 s lasted until 103 s")

        // Read again after a seek back, nothing skipped this time: its clear ends it.
        cues.apply(.init(truncatePreviousAt: 5, cue: cue(5, 10, estimated: true)), deduplicating: true, span: 3)
        cues.apply(.init(truncatePreviousAt: 7), span: 3)
        #expect(cues.first { $0.startTime == 5 }?.endTime == 7)
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
        #expect(engine.subtitleLoads.isEmpty)
    }

    @Test("Forced only shows the sets a full track marks forced, and a track forced as a whole in full")
    func showsForcedSetsOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("movie.sup")
        try SyntheticTestMediaFactory.pgsStream(forcedAt: 2.5).write(to: file)

        let document = try #require(
            EmbeddedSubtitleReader.extractEmbeddedSubtitles(url: file.path, headers: [:], streamIndex: 0))
        try #require(document.imageCues.count == 2)
        #expect(document.imageCues.map { $0.regions.map(\.isForced) } == [[false], [true]])

        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: file).first)
        engine.selectedSubtitleTrackId = id
        engine.activeSubtitleDocument = document
        engine.showsOnlyForcedSubtitles = true
        engine.updateActiveSubtitles(at: 1.0)
        #expect(engine.currentSubtitleImages.isEmpty, "A set not marked forced was shown")
        engine.updateActiveSubtitles(at: 3.0)
        #expect(engine.currentSubtitleImages.map(\.id) == [document.imageCues[1].id])

        engine.showsOnlyForcedSubtitles = false
        engine.updateActiveSubtitles(at: 1.0)
        #expect(engine.currentSubtitleImages.map(\.id) == [document.imageCues[0].id])

        // A track flagged forced as a whole shows every set, marked or not.
        let index = try #require(engine.subtitleTracks.firstIndex { $0.id == id })
        let track = engine.subtitleTracks[index]
        engine.subtitleTracks[index] = SubtitleTrack(
            id: track.id, streamIndex: track.streamIndex, title: track.title, language: track.language,
            externalURL: track.externalURL, isForced: true, format: track.format)
        engine.showsOnlyForcedSubtitles = true
        engine.updateActiveSubtitles(at: 1.0)
        #expect(engine.currentSubtitleImages.map(\.id) == [document.imageCues[0].id])
    }

    @Test("A set's forced regions keep a stable id of their own; a set with none gives nothing")
    func forcedOnlyCue() {
        func region(_ forced: Bool) -> SubtitleImageCue.Region {
            SubtitleImageCue.Region(x: 0, y: 0, width: 1, height: 1, indices: Data([0]), palette: [], isForced: forced)
        }
        func cue(_ regions: [SubtitleImageCue.Region]) -> SubtitleImageCue {
            SubtitleImageCue(id: 7, startTime: 0, endTime: 1, canvasWidth: 0, canvasHeight: 0, regions: regions)
        }
        #expect(cue([region(false)]).forcedOnly() == nil)
        #expect(cue([region(true)]).forcedOnly()?.id == 7)
        let mixed = cue([region(false), region(true)]).forcedOnly()
        #expect(mixed?.id == -7 && mixed?.regions.count == 1)
    }

    @Test("Selecting a track again while its file is read starts no second read")
    func readsOnce() throws {
        let (directory, file) = try makeSupFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: file).first)
        engine.selectSubtitleTrack(id: id)
        let load = try #require(engine.subtitleLoads[id])
        engine.selectSubtitleTrack(id: id)
        #expect(engine.subtitleLoads.count == 1 && engine.subtitleLoads[id]?.interrupt === load.interrupt)
    }

    @Test("Selecting another track, or none, cancels the read of the track left")
    func cancelsReadOfTrackLeft() throws {
        let (directory, file) = try makeSupFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = directory.appendingPathComponent("other.sup")
        try SyntheticTestMediaFactory.pgsStream.write(to: other)
        let engine = PlayerEngine.makeForTesting()
        let first = try #require(engine.addExternalSubtitles(url: file).first)
        let second = try #require(engine.addExternalSubtitles(url: other).first)

        engine.selectSubtitleTrack(id: first)
        let firstLoad = try #require(engine.subtitleLoads[first])
        engine.selectSubtitleTrack(id: second)
        #expect(firstLoad.interrupt.isCancelled)
        #expect(Array(engine.subtitleLoads.keys) == [second])

        let secondLoad = try #require(engine.subtitleLoads[second])
        engine.selectSubtitleTrack(id: nil)
        #expect(secondLoad.interrupt.isCancelled && engine.subtitleLoads.isEmpty)
    }

    @Test("Stopping takes the subtitles off the screen, tells the host, and cancels reads")
    func stopClearsSubtitles() throws {
        let (directory, sup) = try makeSupFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: sup).first)
        engine.selectSubtitleTrack(id: id)
        let load = try #require(engine.subtitleLoads[id])
        // What a track had put on screen.
        engine.currentSubtitleCues = [SubtitleCue(id: 1, startTime: 0, endTime: 5, text: "Hello")]
        engine.currentSubtitleImages = [
            SubtitleImageCue(id: 1, startTime: 0, endTime: 9, canvasWidth: 1, canvasHeight: 1, regions: [])
        ]

        var reported: [[SubtitleCue]] = []
        engine.onSubtitleCuesChanged = { reported.append($0) }
        engine.stop()
        #expect(reported.last == [])
        #expect(engine.currentSubtitleCues.isEmpty && engine.currentSubtitleImages.isEmpty)
        #expect(engine.activeSubtitleDocument == nil && engine.loadedSubtitleDocuments.isEmpty)
        #expect(load.interrupt.isCancelled && engine.subtitleLoads.isEmpty)
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
