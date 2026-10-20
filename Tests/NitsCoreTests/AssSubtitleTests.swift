import CFFmpeg
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

    /// `script`'s header with "Hello" fading in over 0.5-2 s and shown to 3.5 s.
    static var fadeScript: String {
        header + "Dialogue: 0,0:00:00.50,0:00:03.50,Default,,0,0,0,,{\\fad(1500,0)}Hello\n"
    }

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

    private func style(_ mode: AssStyleOverride, font: String = "Menlo", color: String = "#FFFFFF")
        -> AssSubtitleRenderer.StyleOverride
    {
        AssSubtitleRenderer.StyleOverride(
            mode: mode, subtitleFontName: font, fontSize: 30, textColorHex: color, backgroundColorHex: "#000000",
            backgroundOpacity: 0)
    }

    private func pixels(_ output: AssSubtitleRenderer.Output) -> Data? {
        region(output)?.premultipliedBGRA()
    }

    @Test("The style override restyles dialogue, leaves positioned drawings alone, and turns off again")
    func overridesDialogueStyle() throws {
        let renderer = try makeRenderer()
        let authored = try #require(pixels(renderer.render(at: 1.0)))
        let box = try #require(pixels(renderer.render(at: 4.0)))

        renderer.setStyleOverride(style(.font))
        let restyled = try #require(pixels(renderer.render(at: 1.0)), "Nothing drawn after the override")
        #expect(restyled != authored, "The dialogue kept its font")
        #expect(pixels(renderer.render(at: 4.0)) == box, "The positioned drawing changed")

        renderer.setStyleOverride(style(.full, color: "#FF0000"))
        let red = try #require(region(renderer.render(at: 1.0)))
        let bytes = [UInt8](red.premultipliedBGRA())
        // Some opaque pixel is red: BGRA (0, 0, ≥ 0xF0, 0xFF).
        #expect(
            stride(from: 0, to: bytes.count, by: 4).contains {
                bytes[$0 + 3] == 0xFF && bytes[$0 + 2] >= 0xF0 && bytes[$0] < 0x10 && bytes[$0 + 1] < 0x10
            }, "No red in the dialogue")

        renderer.setStyleOverride(style(.none))
        #expect(pixels(renderer.render(at: 1.0)) == authored)
    }

    @Test("The system's rounded, serif and monospaced designs reach libass, which Core Text hides them from")
    func drawsSystemDesigns() throws {
        var drawn: [String: Data] = [:]
        for font in ["System Rounded", "System Serif", "System Monospaced", "System", "No Such Font"] {
            let renderer = try makeRenderer()
            renderer.setStyleOverride(style(.font, font: font))
            let picture: Data = try #require(pixels(renderer.render(at: 1.0)), "Nothing drawn in \(font)")
            drawn[font] = picture
        }
        // A font libass can't find falls back to its default; each design must differ from that and each other.
        #expect(Set(drawn.values).count == drawn.count, "Some designs were drawn in the fallback font")
    }

    @Test("A host's script made of the header and the cues' lines draws what the player draws")
    func hostScriptRoundTrips() throws {
        let document = SubtitleDocument.parseASS(Self.script)
        let script = try #require(document.assScript)
        let hostScript = script.hostHeader + document.cues.compactMap(\.rawPayload).joined(separator: "\n") + "\n"
        let host = try #require(
            AssSubtitleRenderer(script: AssScript(header: Data(hostScript.utf8), isCompleteFile: true)))
        host.configure(frameWidth: 640, frameHeight: 360, videoWidth: 640, videoHeight: 360, pixelAspect: 1)
        let player = try makeRenderer()
        let drawn = try #require(pixels(player.render(at: 1.0)))
        #expect(pixels(host.render(at: 1.0)) == drawn)
    }

    @Test("Scale and raise move and size dialogue, not positioned drawings")
    func placesDialogue() throws {
        let renderer = try makeRenderer()
        let line = try #require(region(renderer.render(at: 1.0)))
        let box = try #require(region(renderer.render(at: 4.0)))

        renderer.setPlacement(scale: 1.5, raise: 0.3)
        let placed = try #require(region(renderer.render(at: 1.0)))
        #expect(Double(placed.width) > Double(line.width) * 1.3, "Widths \(line.width) → \(placed.width)")
        let bottom = placed.y + placed.height
        #expect(bottom < line.y + line.height - 360 / 5, "Not raised: bottom \(line.y + line.height) → \(bottom)")
        let drawing = try #require(region(renderer.render(at: 4.0)))
        #expect((drawing.x, drawing.y, drawing.width, drawing.height) == (box.x, box.y, box.width, box.height))
    }

    @Test("Hex colors of the subtitle style keep their alpha, as the text overlay draws them")
    func parsesHexColors() throws {
        typealias Style = AssSubtitleRenderer.StyleOverride
        #expect(Style.rgba(hex: "#12AB34").map { [Double($0.rgb), $0.alpha] } == [Double(0x12AB34), 1])
        let translucent = try #require(Style.rgba(hex: "12AB3480"))
        #expect(translucent.rgb == 0x12AB34 && abs(translucent.alpha - 128.0 / 255) < 0.001)
        #expect(Style.rgba(hex: "#XYZ") == nil)
        #expect(Style.assColor(0x12AB34, opacity: 1) == 0x12AB_3400)

        let style = Style(
            mode: .full, subtitleFontName: "Menlo", fontSize: 30, textColorHex: "#FFFFFF80",
            backgroundColorHex: "#00000080", backgroundOpacity: 0.5)
        #expect(abs(style.textOpacity - 128.0 / 255) < 0.001)
        #expect(abs(style.backgroundOpacity - 0.5 * 128.0 / 255) < 0.001, "The box's opacity times the color's alpha")
    }

    @Test("Stored font names resolve through the one list of system designs, aliases included")
    func resolvesFontNames() {
        typealias Style = AssSubtitleRenderer.StyleOverride
        #expect(SubtitleSystemFont(fontName: "Serif") == .serif && SubtitleSystemFont(fontName: "") == .rounded)
        #expect(SubtitleSystemFont(fontName: "Standard") == .standard)
        #expect(SubtitleSystemFont(fontName: "Georgia") == nil)
        #expect(Style.libassFont(for: "Georgia").name == "Georgia" && Style.libassFont(for: "Georgia").file == nil)
        #expect(Style.libassFont(for: "Standard").name == Style.systemFontFamily)
        #expect(Style.libassFont(for: "Serif").name == Style.libassFont(for: SubtitleSystemFont.serif.rawValue).name)
    }

    @Test("A font file that can't be read draws in SF Pro, not in libass' default")
    func unreadableFontFileFallsBack() throws {
        func drawn(_ style: AssSubtitleRenderer.StyleOverride) throws -> Data {
            let renderer = try makeRenderer()
            renderer.setStyleOverride(style)
            return try #require(pixels(renderer.render(at: 1.0)))
        }
        var missing = style(.font, font: "System Rounded")
        missing.fontFile = URL(fileURLWithPath: "/nonexistent/Font.ttf")
        #expect(try drawn(missing) == drawn(style(.font, font: "System")))
    }

    @Test("A fade changes the picture every frame and a still line doesn't: what frame-rate redraws stop on")
    func reportsAnimationChanges() throws {
        let renderer = try #require(
            AssSubtitleRenderer(script: AssScript(header: Data(Self.fadeScript.utf8), isCompleteFile: true)))
        renderer.configure(frameWidth: 640, frameHeight: 360, videoWidth: 640, videoHeight: 360, pixelAspect: 1)
        for frame in 0..<10 {
            guard case .frame(.some) = renderer.render(at: 0.6 + Double(frame) / 24) else {
                Issue.record("Frame \(frame) of the fade reported no change")
                return
            }
        }
        _ = renderer.render(at: 2.5)
        guard case .unchanged = renderer.render(at: 2.5 + 1.0 / 24) else {
            Issue.record("A still line reported a change")
            return
        }
    }

    @Test("A forced aspect ratio's pixel aspect squeezes the text with the picture and redraws it")
    func followsPixelAspect() throws {
        let renderer = try makeRenderer()
        // 16:9 storage shown at 4:3: the frame drawn on is 480x360 and the video's pixels are 0.75 wide.
        renderer.configure(frameWidth: 480, frameHeight: 360, videoWidth: 640, videoHeight: 360, pixelAspect: 1)
        let square = try #require(region(renderer.render(at: 1.0)))
        renderer.configure(frameWidth: 480, frameHeight: 360, videoWidth: 640, videoHeight: 360, pixelAspect: 0.75)
        let squeezed = try #require(region(renderer.render(at: 1.0)), "The new pixel aspect wasn't drawn")
        // The outline and the region's margins don't scale with the glyphs, so the ratio is only near 0.75.
        let ratio = Double(squeezed.width) / Double(square.width)
        #expect(ratio > 0.7 && ratio < 0.88, "Widths \(square.width) → \(squeezed.width)")
        #expect(abs(squeezed.height - square.height) <= 2)
    }

    @Test("A sign at the top and dialogue at the bottom make two small pictures, not one the size of the frame")
    func composesSeparatePictures() throws {
        let both =
            Self.header + """
                Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Hello
                Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\\an7\\pos(100,20)\\1c&H0000FF&\\bord0\\p1}m 0 0 l 200 0 200 40 0 40{\\p0}
                """
        let renderer = try #require(
            AssSubtitleRenderer(script: AssScript(header: Data(both.utf8), isCompleteFile: true)))
        renderer.configure(frameWidth: 640, frameHeight: 360, videoWidth: 640, videoHeight: 360, pixelAspect: 1)
        guard case .frame(let cue) = renderer.render(at: 1.0) else {
            Issue.record("Nothing drawn")
            return
        }
        let regions = try #require(cue?.regions).sorted { $0.y < $1.y }
        try #require(regions.count == 2, "Regions: \(regions.map { ($0.x, $0.y, $0.width, $0.height) })")
        #expect(regions[0].y + regions[0].height < 100, "The drawing is at the top")
        #expect(regions[1].y > 360 / 2, "The text is in the lower half")
        let area = regions.reduce(0) { $0 + $1.width * $1.height }
        #expect(area < 640 * 360 / 4)
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

    @Test("Hosts get one field order: SSA's Marked and a reordered Format become standard Dialogue lines")
    func normalizesDialogueLines() {
        let ssa = """
            [Events]
            Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: Marked=0,0:00:01.00,0:00:02.50,Main,Bob,0010,0010,0020,,Well, yes
            """
        #expect(
            SubtitleDocument.parseASS(ssa).cues.first?.rawPayload
                == "Dialogue: 0,0:00:01.00,0:00:02.50,Main,Bob,0010,0010,0020,,Well, yes")
        let reordered = """
            [Events]
            Format: Start, End, Text, Style, Layer
            Dialogue: 0:01:02.03,0:01:04.00,Hi,Top,3
            """
        #expect(
            SubtitleDocument.parseASS(reordered).cues.first?.rawPayload
                == "Dialogue: 3,0:01:02.03,0:01:04.00,Top,,0,0,0,,Hi")
        #expect(
            AssScript.dialogueLine(matroskaEvent: "7,1,Sign,,0,0,0,fx,A, B", start: 3725.5, end: 3726)
                == "Dialogue: 1,1:02:05.50,1:02:06.00,Sign,,0,0,0,fx,A, B")
        #expect(
            AssScript.dialogueLine(
                matroskaEvent: "Dialogue: Marked=0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Old", start: 10, end: 11)
                == "Dialogue: 0,0:00:10.00,0:00:11.00,Default,,0,0,0,,Old")
        #expect(
            AssScript.dialogueLine(matroskaEvent: "too,few", start: 0, end: 1)
                == "Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,too,few", "A malformed event still reaches hosts")
    }

    @Test("The host header keeps everything but the events and ends in the format hosts' lines follow")
    func buildsHostHeader() {
        let script = AssScript(
            header: Data(
                (AssSubtitleTests.script + "\n\n[Fonts]\nfontname: x.ttf\nABCD\n").replacingOccurrences(
                    of: "\n", with: "\r\n"
                ).utf8), isCompleteFile: true)
        let header = script.hostHeader
        #expect(header.contains("[V4+ Styles]") && header.contains("PlayResX: 640"))
        #expect(header.contains("[Fonts]\nfontname: x.ttf"), "Embedded fonts stay for libass in the host")
        #expect(!header.contains("Dialogue:") && !header.contains("\r"))
        #expect(header.hasSuffix("[Events]\nFormat: \(AssScript.eventFormat)\n"))
        #expect(header.components(separatedBy: "[Events]").count == 2, "One events section")
    }

    @Test("A packet with no duration lasts as long for libass as its text cue does")
    func eventWithoutDuration() throws {
        var payload = Array("0,0,Default,,0,0,0,,Late".utf8)
        try payload.withUnsafeMutableBufferPointer { bytes in
            var packet = AVPacket()
            packet.data = bytes.baseAddress
            packet.size = Int32(bytes.count)
            packet.pts = 3000
            packet.duration = 0
            let timebase = AVRational(num: 1, den: 1000)
            let event = try #require(EmbeddedSubtitleReader.assEvent(from: &packet, timebase: timebase))
            let cue = try #require(
                EmbeddedSubtitleReader.parseSubtitleCue(
                    pkt: &packet, timebase: timebase, codecId: AV_CODEC_ID_ASS, cueIndex: 1))
            #expect(event.start == 3 && event.duration == EmbeddedSubtitleReader.fallbackCueDuration)
            #expect(cue.startTime == event.start && cue.endTime - cue.startTime == event.duration)
        }
    }

    @Test("An embedded ASS track keeps its header and events for libass next to the plain text")
    func extractsEmbeddedTrack() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        #expect(track.format == .ass)
        let document = try #require(
            EmbeddedSubtitleReader.extractEmbeddedSubtitles(url: path, headers: [:], streamIndex: track.streamIndex))

        #expect(document.cues.map(\.text) == ["Hello"], "Only the dialogue is text")
        let line = "Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Hello"
        #expect(document.cues.first?.rawPayload == line)
        #expect(
            SubtitleDocument.parseASS(AssSubtitleTests.script).cues.first?.rawPayload == line,
            "A file gives hosts the same line as the stream")
        let script = try #require(document.assScript)
        #expect(!script.isCompleteFile)
        #expect(String(decoding: script.header, as: UTF8.self).contains("PlayResX: 640"))
        #expect(script.events.count == 2, "Both events, the drawing too")
        #expect(abs(script.events[0].duration - 2) < 0.01 && abs(script.events[1].start - 3) < 0.01)
    }

    @Test("A local file's ASS track is collected as packets pass, like a network one's")
    func localFileCollectsLive() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        let script = try #require(demuxer.getLiveSubtitleDocument().assScript, "No script to collect events into")
        #expect(String(decoding: script.header, as: UTF8.self).contains("PlayResX: 640"))
    }

    @Test(
        "The window to read runs from the preroll up to where playback reads, and is skipped where nothing is missing")
    func windowToRead() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        #expect(demuxer.subtitleWindow(around: 0) == nil, "Opened and not read yet: playback reads from 0")

        demuxer.seek(to: 3, exact: false)
        #expect(demuxer.subtitleWindow(around: 3) == 0...3, "From the preroll up to where reads restart")
        let selection = demuxer.liveSubtitleSelection
        #expect(demuxer.mergeLiveSubtitles(.init(), covering: 0...3, selection: selection.id, span: selection.span))
        #expect(demuxer.subtitleWindow(around: 3) == nil)

        // A forward keyframe seek landed past its target: what it jumped over wasn't read, what was read isn't again.
        demuxer.noteSubtitleReadsStart(at: 5)
        #expect(demuxer.subtitleWindow(around: 5) == 3...5)

        // A negative delay: the track is due past everything read, so it is read ahead, in steps.
        #expect(demuxer.subtitleWindow(around: 20) == 10...30)
        #expect(demuxer.mergeLiveSubtitles(.init(), covering: 10...30, selection: selection.id, span: selection.span))
        #expect(demuxer.subtitleWindow(around: 21) == nil, "Most of the lookahead is left")
        #expect(demuxer.subtitleWindow(around: 26) == 30...36)
    }

    @Test("A window read finds the cue on screen and joins what playback collected once, for its own selection only")
    func windowReadMerges() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        let selection = demuxer.liveSubtitleSelection
        let packets = try #require(
            EmbeddedSubtitleReader.readSubtitles(
                url: path, headers: [:], streamIndex: selection.streamIndex, in: 0...2))
        #expect(packets.cues.map(\.text) == ["Hello"])
        #expect(packets.assEvents.contains { $0.payload.hasSuffix("Hello") })

        // Playback reads on from 2 s: the window up to there is missing until merged.
        demuxer.seek(to: 2, exact: false)
        let postSeek = demuxer.liveSubtitleSelection
        #expect(demuxer.subtitleWindow(around: 2) == 0...2)
        #expect(demuxer.mergeLiveSubtitles(packets, covering: 0...2, selection: postSeek.id, span: postSeek.span))
        #expect(demuxer.mergeLiveSubtitles(packets, covering: 0...2, selection: postSeek.id, span: postSeek.span))
        let document = demuxer.getLiveSubtitleDocument()
        #expect(document.cues.map(\.text) == ["Hello"], "Merged twice, listed once")
        #expect(document.assScript?.events.count == packets.assEvents.count)
        #expect(demuxer.subtitleWindow(around: 2) == nil)

        // A read for a track since chosen again (another selection) or an earlier stretch (before a seek) is dropped.
        demuxer.selectSubtitleTrack(trackId: demuxer.subtitleTracks.first?.id)
        let reselected = demuxer.liveSubtitleSelection
        #expect(!demuxer.mergeLiveSubtitles(packets, covering: 0...2, selection: postSeek.id, span: reselected.span))
        #expect(demuxer.getLiveSubtitleDocument().cues.isEmpty)

        demuxer.seek(to: 2, exact: false)
        #expect(
            !demuxer.mergeLiveSubtitles(
                packets, covering: 0...2, selection: reselected.id, span: reselected.span))
        #expect(demuxer.getLiveSubtitleDocument().cues.isEmpty)
        #expect(demuxer.subtitleWindow(around: 2) == 0...2, "A dropped window must not mark its range as covered")
    }

    @Test("Choosing a style override, then changing the style, redraws the ASS dialogue", .hostDependent)
    @MainActor
    func engineRedrawsOnStyleOverride() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(engine.isLoaded)
        let track = try #require(engine.subtitleTracks.first)
        engine.subtitleRenderSize = CGSize(width: 640, height: 360)
        engine.selectSubtitleTrack(id: track.id)
        for _ in 0..<100 where engine.activeSubtitleDocument == nil { try await Task.sleep(for: .milliseconds(50)) }
        try #require(engine.isDrawingAuthoredSubtitles)
        engine.currentTime = 1.0
        engine.updateActiveSubtitles(at: 1.0)
        for _ in 0..<100 where engine.currentSubtitleImages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let authored = try #require(engine.currentSubtitleImages.first)

        func redrawn(after previous: SubtitleImageCue) async throws -> SubtitleImageCue {
            for _ in 0..<100 where engine.currentSubtitleImages.first?.id == previous.id {
                try await Task.sleep(for: .milliseconds(20))
            }
            return try #require(engine.currentSubtitleImages.first, "Not redrawn")
        }
        engine.subtitleFontName = "Menlo"
        engine.assStyleOverride = .font
        let restyled = try await redrawn(after: authored)
        #expect(restyled.id != authored.id)
        engine.subtitleFontSize = 40
        let larger = try await redrawn(after: restyled)
        #expect(larger.regions.first.map(\.width) ?? 0 > restyled.regions.first.map(\.width) ?? 0)
    }

    @Test("A fade is drawn at the video's frame rate during playback, not at the 20 Hz time tick", .realtimePlayback)
    @MainActor
    func engineDrawsFadeAtFrameRate() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assFadeSubtitlesMKV) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(engine.isLoaded)
        let track = try #require(engine.subtitleTracks.first)
        engine.subtitleRenderSize = CGSize(width: 640, height: 360)
        engine.selectSubtitleTrack(id: track.id)
        for _ in 0..<100 where engine.activeSubtitleDocument == nil { try await Task.sleep(for: .milliseconds(50)) }
        try #require(engine.isDrawingAuthoredSubtitles)

        engine.play()
        // Distinct pictures shown during a second of the fade (0.75-1.75 s): about 60 at the frame rate, 20 at the tick.
        var frames = Set<Int>()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline, engine.currentTime < 1.75 {
            if engine.currentTime >= 0.75, let image = engine.currentSubtitleImages.first { frames.insert(image.id) }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(frames.count >= 35, "Pictures in a second of the fade: \(frames.count)")
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
        #expect(engine.subtitleAssHeader?.contains("PlayResX: 640") == true, "Hosts get the script header")
        #expect(engine.currentSubtitleCues.first?.rawPayload?.hasPrefix("Dialogue: 0,0:00:00.00") == true)

        engine.usesAuthoredSubtitleStyles = false
        #expect(!engine.isDrawingAuthoredSubtitles && engine.currentSubtitleImages.isEmpty)
        engine.usesAuthoredSubtitleStyles = true
        #expect(engine.isDrawingAuthoredSubtitles)

        engine.selectSubtitleTrack(id: nil)
        #expect(!engine.isDrawingAuthoredSubtitles && engine.currentSubtitleImages.isEmpty)
        #expect(engine.subtitleAssHeader == nil)
    }

    @Test("A time asked for while a replaced renderer was busy is still drawn, by the new one", .hostDependent)
    @MainActor
    func pendingRenderSurvivesRendererSwitch() async throws {
        let script = AssScript(header: Data(AssSubtitleTests.script.utf8), isCompleteFile: true)
        let engine = PlayerEngine.makeForTesting()
        engine.subtitleRenderSize = CGSize(width: 640, height: 360)
        let replaced = try #require(AssSubtitleRenderer(script: script))
        let current = try #require(AssSubtitleRenderer(script: script))
        engine.authoredRenderer = replaced
        engine.renderAuthoredSubtitles(at: 1.0)
        // Paused: no time tick follows, so only the pending request can draw the new renderer's first frame.
        engine.authoredRenderer = current
        engine.renderAuthoredSubtitles(at: 1.0)
        try #require(engine.pendingAuthoredRenderTime == 1.0)
        for _ in 0..<100 where engine.currentSubtitleImages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!engine.currentSubtitleImages.isEmpty)
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
