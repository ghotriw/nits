import Foundation
import Testing

@testable import NitsCore

@Suite("ASS subtitles (libass)", .hostDependent)
struct AssSubtitleTests {
    /// A 640x360 script: white "Hello" at the bottom for 0-2 s, and a red box (a vector drawing) at the top from 3 s.
    static let script = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 640
        PlayResY: 360

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Hello
        Dialogue: 0,0:00:03.00,0:00:05.00,Default,,0,0,0,,{\\an7\\pos(100,20)\\1c&H0000FF&\\bord0\\p1}m 0 0 l 200 0 200 40 0 40{\\p0}
        """

    /// The script up to its events: what a Matroska track keeps as codec private data.
    static var header: String {
        String(script.prefix(upTo: script.range(of: "Dialogue:")!.lowerBound))
    }

    private func makeRenderer() throws -> AssSubtitleRenderer {
        let renderer = try #require(
            AssSubtitleRenderer(script: AssScript(header: Data(Self.script.utf8), isCompleteFile: true)))
        renderer.configure(frameWidth: 640, frameHeight: 360, videoWidth: 640, videoHeight: 360, pixelAspect: 1)
        return renderer
    }

    private func region(_ output: AssSubtitleRenderer.Output) -> SubtitleImageCue.Region? {
        guard case .frame(let cue) = output else { return nil }
        return cue?.regions.first
    }

    @Test("A text event is drawn near the bottom, then goes away, and an unchanged frame says so")
    func drawsTextEvent() throws {
        let renderer = try makeRenderer()
        let hello = try #require(region(renderer.render(at: 1.0)), "Nothing drawn for the text event")
        #expect(hello.y > 360 / 2, "Bottom-aligned text starts in the lower half: \(hello.y)")
        #expect(hello.x > 0 && hello.x + hello.width < 640)
        let pixels = [UInt8](hello.premultipliedBGRA())
        #expect(pixels.count == hello.width * hello.height * 4)
        #expect(pixels.contains { $0 > 0xF0 }, "No white pixels")

        guard case .unchanged = renderer.render(at: 1.0) else {
            Issue.record("A second render at the same time reported a change")
            return
        }
        guard case .frame(nil) = renderer.render(at: 2.5) else {
            Issue.record("Nothing should be on screen at 2.5 s")
            return
        }
    }

    @Test("A vector drawing is placed where the script says, in the frame's pixels")
    func drawsVectorDrawing() throws {
        let renderer = try makeRenderer()
        let box = try #require(region(renderer.render(at: 4.0)), "Nothing drawn for the drawing")
        let pixels = [UInt8](box.premultipliedBGRA())
        // The region has margins of nothing around the drawing; its opaque part is the drawing.
        let opaque = (0..<(box.width * box.height)).filter { pixels[$0 * 4 + 3] > 128 }
        let columns = opaque.map { $0 % box.width }
        let rows = opaque.map { $0 / box.width }
        let left = box.x + (columns.min() ?? 0)
        let top = box.y + (rows.min() ?? 0)
        #expect(abs(left - 100) <= 2 && abs(top - 20) <= 2, "Drawing at \(left),\(top)")
        #expect(abs((columns.max() ?? 0) - (columns.min() ?? 0) + 1 - 200) <= 3)
        #expect(abs((rows.max() ?? 0) - (rows.min() ?? 0) + 1 - 40) <= 3)
        // Red, opaque: BGRA (0, 0, 255, 255) in the middle.
        let middle = ((box.height / 2) * box.width + box.width / 2) * 4
        #expect(Array(pixels[middle..<(middle + 4)]) == [0, 0, 255, 255])
    }

    @Test("The picture follows the frame size: scripts scale to the area they are drawn on")
    func scalesToFrame() throws {
        let renderer = try makeRenderer()
        let small = try #require(region(renderer.render(at: 4.0)))
        renderer.configure(frameWidth: 1280, frameHeight: 720, videoWidth: 640, videoHeight: 360, pixelAspect: 1)
        let large = try #require(region(renderer.render(at: 4.0)))
        #expect(abs(large.width - small.width * 2) <= 4 && abs(large.x - small.x * 2) <= 4)
    }

    @Test("Stream events are fed once, whatever the number of times the list is passed")
    func feedsStreamEventsOnce() throws {
        var script = AssScript(header: Data(Self.header.utf8), events: [])
        let renderer = try #require(AssSubtitleRenderer(script: script))
        renderer.configure(frameWidth: 640, frameHeight: 360, videoWidth: 640, videoHeight: 360, pixelAspect: 1)
        #expect(region(renderer.render(at: 1.0)) == nil, "Events appeared from nowhere")
        script.events = [AssScript.Event(payload: "0,0,Default,,0,0,0,,Streamed", start: 0.5, duration: 2)]
        renderer.addEvents(script.events)
        renderer.addEvents(script.events)
        let streamed = try #require(region(renderer.render(at: 1.0)))
        #expect(streamed.width > 0)
    }
}

@Suite("ASS subtitle tracks")
struct AssSubtitleTrackTests {
    @Test("An ASS script becomes plain-text cues for hosts, and drawings are not text")
    func parsesScript() throws {
        let document = SubtitleDocument.parseASS(AssSubtitleTests.script)
        #expect(document.cues.map(\.text) == ["Hello"])
        let cue = try #require(document.cues.first)
        #expect(cue.startTime == 0 && cue.endTime == 2)
        #expect(cue.rawPayload?.hasPrefix("Dialogue: 0,0:00:00.00") == true)

        let script = try #require(document.assScript)
        #expect(script.isCompleteFile)
        #expect(String(decoding: script.header, as: UTF8.self).contains("[V4+ Styles]"))
    }

    @Test("Commas in the text stay in it, and comments are not dialogue")
    func keepsCommasInText() {
        let script = """
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,Well, {\\i1}yes{\\i0}, indeed\\Nsecond line
            Comment: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,not shown
            """
        let document = SubtitleDocument.parseASS(script)
        #expect(document.cues.map(\.text) == ["Well, yes, indeed\nsecond line"])
        #expect(document.cues.first?.endTime == 2.5)
    }

    @Test("An embedded ASS track keeps its header and events for libass next to the plain text")
    func extractsEmbeddedTrack() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        #expect(track.format == .ass)
        let document = try #require(demuxer.loadSubtitleDocument(for: track.id, url: path, headers: [:]))

        #expect(document.cues.map(\.text) == ["Hello"], "Only the dialogue is text")
        #expect(document.cues.first?.rawPayload?.contains("Default") == true)
        let script = try #require(document.assScript)
        #expect(!script.isCompleteFile)
        #expect(String(decoding: script.header, as: UTF8.self).contains("PlayResX: 640"))
        #expect(script.events.count == 2, "Both events, the drawing too")
        #expect(abs(script.events[0].duration - 2) < 0.01 && abs(script.events[1].start - 3) < 0.01)
    }

    @Test("A local file collects no live events or pictures: it is read whole instead")
    func localFileKeepsNoLiveList() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        #expect(demuxer.getLiveSubtitleDocument().assScript == nil)
    }

    @Test(
        "The engine draws a selected ASS track with libass, keeps text cues for hosts, and the setting turns it off",
        .hostDependent)
    @MainActor
    func engineDrawsAuthoredStyles() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(engine.isLoaded)
        let track = try #require(engine.subtitleTracks.first)

        engine.subtitleRenderSize = CGSize(width: 1280, height: 720)
        engine.selectSubtitleTrack(id: track.id)
        for _ in 0..<100 where engine.activeSubtitleDocument == nil { try await Task.sleep(for: .milliseconds(50)) }
        try #require(engine.isDrawingAuthoredSubtitles)

        engine.updateActiveSubtitles(at: 1.0)
        for _ in 0..<100 where engine.currentSubtitleImages.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let image = try #require(engine.currentSubtitleImages.first)
        #expect((image.canvasWidth, image.canvasHeight) == (1280, 720))
        #expect(engine.currentSubtitleCues.map(\.text) == ["Hello"], "Hosts still get the text")

        engine.usesAuthoredSubtitleStyles = false
        #expect(!engine.isDrawingAuthoredSubtitles && engine.currentSubtitleImages.isEmpty)
        engine.usesAuthoredSubtitleStyles = true
        #expect(engine.isDrawingAuthoredSubtitles)

        engine.selectSubtitleTrack(id: nil)
        #expect(!engine.isDrawingAuthoredSubtitles && engine.currentSubtitleImages.isEmpty)
    }

    @Test("Without a render size an ASS file shows as plain text, and with one it is drawn")
    @MainActor
    func fallsBackToText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("movie.ass")
        try AssSubtitleTests.script.write(to: file, atomically: true, encoding: .utf8)

        let engine = PlayerEngine.makeForTesting()
        let id = try #require(engine.addExternalSubtitles(url: file).first)
        #expect(engine.subtitleTracks.first?.format == .ass)
        engine.selectSubtitleTrack(id: id)
        engine.updateActiveSubtitles(at: 1.0)
        #expect(!engine.isDrawingAuthoredSubtitles)
        #expect(engine.currentSubtitleCues.map(\.text) == ["Hello"])

        engine.subtitleRenderSize = CGSize(width: 640, height: 360)
        #expect(engine.isDrawingAuthoredSubtitles, "A complete script file is drawn once the size is known")
    }
}
