import CFFmpeg
import Foundation
import Testing

@testable import NitsCore

@Suite("CEA-608 closed captions in video pictures and MP4 caption tracks")
struct ClosedCaptionTests {
    private typealias Factory = SyntheticTestMediaFactory

    private func triplets(_ bytes: [UInt8], codec: VideoCodec) -> [UInt8] {
        bytes.withUnsafeBytes { ClosedCaptions.cea608Triplets(in: $0, codec: codec) }
    }

    private func lengthPrefixed(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { unit in withUnsafeBytes(of: UInt32(unit.count).bigEndian, Array.init) + unit }
    }

    private func annexB(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { [0, 0, 0, 1] + $0 }
    }

    /// A field 1 pair "HI" with parity, as `captionSEI` writes it beside field 2 padding and a 708 triplet.
    private let pair = (Factory.cea608Byte(0x48), Factory.cea608Byte(0x49))
    private var expected: [UInt8] { [0xFC, pair.0, pair.1, 0xFD, 0x80, 0x80] }

    @Test("H.264 SEI: Annex B and length-prefixed packets, 608 triplets only, nothing past the first slice")
    func readsH264SEI() {
        let delimiter: [UInt8] = [0x09, 0xF0]
        let slice: [UInt8] = [0x65, 0x88, 0x84, 0x00]
        let sei = Factory.captionSEI(pair: pair)
        #expect(triplets(annexB([delimiter, sei, slice]), codec: .h264) == expected)
        #expect(triplets(lengthPrefixed([delimiter, sei, slice]), codec: .h264) == expected)
        #expect(triplets(annexB([delimiter, slice, sei]), codec: .h264).isEmpty, "SEI after a slice isn't read")
        #expect(triplets(annexB([delimiter, sei, slice]), codec: .vp9).isEmpty)
    }

    @Test("Messages before the captions are skipped by their size, counted without emulation prevention bytes")
    func skipsOtherMessages() {
        // Payload type 5 (unregistered user data), 3 bytes `00 00 01`: written as `00 00 03 01`.
        let sei = Factory.captionSEI(pair: pair)
        let unit = [0x06] + Factory.emulationPrevented([0x05, 0x03, 0x00, 0x00, 0x01]) + sei.dropFirst()
        #expect(unit.count == sei.count + 6, "The prevention byte is there")
        #expect(triplets(annexB([unit]), codec: .h264) == expected)
    }

    @Test("HEVC prefix SEI and MPEG-2 picture user data")
    func readsHEVCAndMPEG2() {
        let rbsp = Array(Factory.captionSEI(pair: pair).dropFirst())
        let hevcSEI: [UInt8] = [39 << 1, 0x01] + rbsp
        let hevcSlice: [UInt8] = [0x02, 0x01, 0xD0]
        #expect(triplets(lengthPrefixed([hevcSEI, hevcSlice]), codec: .hevc) == expected)

        let userData: [UInt8] =
            [0, 0, 1, 0xB2, 0x47, 0x41, 0x39, 0x34, 0x03, 0x40 | 2, 0xFF] + expected + [0xFF]
        let picture: [UInt8] = [0, 0, 1, 0x00, 0x00, 0x0F, 0xFF, 0xF8]
        let mpeg2Slice: [UInt8] = [0, 0, 1, 0x01, 0x12]
        #expect(triplets(picture + userData + mpeg2Slice, codec: .mpeg2) == expected)
        #expect(triplets(picture + mpeg2Slice + userData, codec: .mpeg2).isEmpty)
    }

    @Test("Units behind 2-byte lengths, as an avcC with lengthSizeMinusOne 1 declares them")
    func readsShortUnitLengths() throws {
        let units = [[0x09, 0xF0], Factory.captionSEI(pair: pair), [0x65, 0x88, 0x84, 0x00]]
        let packet = units.flatMap { unit in withUnsafeBytes(of: UInt16(unit.count).bigEndian, Array.init) + unit }
        #expect(triplets(packet, codec: .h264).isEmpty)
        #expect(
            packet.withUnsafeBytes { ClosedCaptions.cea608Triplets(in: $0, codec: .h264, lengthSize: 2) } == expected)

        let parameters = try #require(avcodec_parameters_alloc())
        var freed: UnsafeMutablePointer<AVCodecParameters>? = parameters
        defer { avcodec_parameters_free(&freed) }
        #expect(ClosedCaptions.nalLengthSize(of: parameters, codec: .h264) == 4, "No extradata")
        // configurationVersion, profile, compatibility, level, then six reserved bits and lengthSizeMinusOne.
        let avcC: [UInt8] = [0x01, 0x64, 0x00, 0x1F, 0xFD, 0xE0]
        let extradata = try #require(av_mallocz(avcC.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            .assumingMemoryBound(to: UInt8.self)
        extradata.update(from: avcC, count: avcC.count)
        parameters.pointee.extradata = extradata
        parameters.pointee.extradata_size = Int32(avcC.count)
        #expect(ClosedCaptions.nalLengthSize(of: parameters, codec: .h264) == 2)
    }

    @Test("Field 2 is listed only with more than null padding")
    func listsFields() {
        #expect(ClosedCaptions.fields(of: expected) == [0])
        #expect(ClosedCaptions.fields(of: [0xFD, pair.0, pair.1]) == [1])
        #expect(ClosedCaptions.fields(of: []).isEmpty)
    }

    @Test(
        "Pictures in decode order (B-frames) give their captions in presentation order, with decode times or without",
        arguments: [true, false])
    func reordersPictures(withDecodeTimes: Bool) throws {
        let context = avformat_alloc_context()
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_H264
        stream.pointee.codecpar.pointee.video_delay = 2
        stream.pointee.time_base = AVRational(num: 1, den: 30)
        let decoder = try #require(ClosedCaptionDecoder(field: 0, stream: stream))

        // Each P picture is decoded before the two B pictures shown ahead of it.
        let pairs = Factory.captionPairsPerPicture
        let order = stride(from: 0, to: pairs.count, by: 3).flatMap { [$0 + 2, $0, $0 + 1] }
        var screens: [ClosedCaptionDecoder.Screen] = []
        for (decodeIndex, picture) in order.enumerated() {
            let bytes = annexB([Factory.captionSEI(pair: pairs[picture])])
            let packet = try #require(av_packet_alloc())
            var freed: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&freed) }
            try #require(av_new_packet(packet, Int32(bytes.count)) == 0)
            bytes.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: $0.count) }
            packet.pointee.pts = Int64(picture)
            packet.pointee.dts = withDecodeTimes ? Int64(decodeIndex - 2) : Int64.min
            screens += decoder.decode(packet)
        }
        screens += decoder.finish()

        let expected = Factory.captionScript.flatMap { [($0.shown, $0.text), ($0.cleared, "")] }
        #expect(screens.map(\.text) == expected.map(\.1))
        #expect(zip(screens, expected).allSatisfy { abs($0.time - $1.0) < 0.001 }, "\(screens.map(\.time))")
    }

    /// Two-row roll-up captions, a line every second: roll-up, carriage return and preamble for row 15, then the
    /// line typed two characters a picture, as live broadcasts send them. One field 1 pair a picture at 30 fps.
    private static let rollUpLines = ["ALPHA ONE", "BRAVO TWO", "CHARLIE THREE"]
    private static var rollUpPairs: [(UInt8, UInt8)] {
        var pictures = Array(repeating: (Factory.cea608Byte(0), Factory.cea608Byte(0)), count: 120)
        for (line, text) in rollUpLines.enumerated() {
            let characters = Array(text.utf8)
            let typed = stride(from: 0, to: characters.count, by: 2).map {
                (characters[$0], $0 + 1 < characters.count ? characters[$0 + 1] : 0)
            }
            let pairs: [(UInt8, UInt8)] = [(0x14, 0x25), (0x14, 0x2D), (0x14, 0x60)] + typed
            for (offset, pair) in pairs.enumerated() {
                pictures[15 + line * 30 + offset] = (Factory.cea608Byte(pair.0), Factory.cea608Byte(pair.1))
            }
        }
        return pictures
    }

    /// A decoder of field 1 of an MP4 caption track (`c608`) counting 30 pictures a second.
    private func captionTrackDecoder() throws -> ClosedCaptionDecoder {
        let context = avformat_alloc_context()
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_EIA_608
        stream.pointee.time_base = AVRational(num: 1, den: 30)
        return try #require(ClosedCaptionDecoder(field: 0, stream: stream))
    }

    /// Hands the decoder a caption track packet of field 1 `pairs` at picture `pts`.
    private func decode(
        _ pairs: [(UInt8, UInt8)], at pts: Int64, duration: Int64 = 0, with decoder: ClosedCaptionDecoder
    ) throws -> [ClosedCaptionDecoder.Screen] {
        let bytes: [UInt8] = pairs.flatMap { [0xFC, $0.0, $0.1] }
        let packet = try #require(av_packet_alloc())
        var freed: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&freed) }
        try #require(av_new_packet(packet, Int32(bytes.count)) == 0)
        bytes.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: $0.count) }
        packet.pointee.pts = pts
        packet.pointee.duration = duration
        return decoder.decode(packet)
    }

    /// The screens of a caption track carrying `pairs`, a packet a picture, from picture `first` on.
    private func screens(of pairs: [(UInt8, UInt8)], from first: Int) throws -> [ClosedCaptionDecoder.Screen] {
        let decoder = try captionTrackDecoder()
        var screens: [ClosedCaptionDecoder.Screen] = []
        for (picture, pair) in pairs.enumerated().dropFirst(first) {
            screens += try decode([pair], at: Int64(picture), duration: 1, with: decoder)
        }
        return screens + decoder.finish()
    }

    /// The screens of `rollUpPairs` from picture `first` on.
    private func rollUpScreens(from first: Int) throws -> [ClosedCaptionDecoder.Screen] {
        try screens(of: Self.rollUpPairs, from: first)
    }

    @Test("Roll-up captions: a screen a step, the last one too, in the same steps for a decoder started later")
    func rollUpScreensByStep() throws {
        let screens = try rollUpScreens(from: 0)
        #expect(screens.last?.text == "BRAVO TWO\nCHARLIE THREE", "The line typed last comes out at the end")
        #expect(screens.contains { $0.text == "ALPHA ONE\nBRAVO TWO" })
        #expect(zip(screens, screens.dropFirst()).allSatisfy { $0.step < $1.step }, "\(screens.map(\.time))")

        // Started on the second line: it doesn't know the first.
        let late = try rollUpScreens(from: 45)
        #expect(late.contains { $0.text == "BRAVO TWO" })
        #expect(late.last?.text == screens.last?.text)
        #expect(Set(late.map(\.step)).isSubset(of: screens.map(\.step)))
    }

    @Test("The screens of a decoder started mid-caption don't cut into fuller ones, in either order")
    func fullerScreensWin() throws {
        let full = try rollUpScreens(from: 0)
        let late = try rollUpScreens(from: 45)
        func cues(_ screens: [ClosedCaptionDecoder.Screen]) -> [String] {
            var state = LiveSubtitleTracker.LiveSubtitleState()
            for screen in screens { LiveSubtitleTracker.addCaption(screen, to: &state) }
            return state.cues.sorted { $0.startTime < $1.startTime }.map { "\($0.startTime)-\($0.endTime) \($0.text)" }
        }
        let expected = cues(full)
        #expect(expected.count > 3)
        #expect(cues(late + full) == expected)
        #expect(cues(full + late) == expected)
    }

    @Test("A decoder started while a pop-on caption loads shows nothing until a caption mode command")
    func waitsForCaptionMode() throws {
        let pairs = Factory.captionPairsPerPicture
        // Picture 25 is within the text of the first caption, loaded from picture 20 for picture 30.
        let screens = try screens(of: pairs, from: 25)
        let second = try #require(Factory.captionScript.last)
        #expect(screens.map(\.text) == [second.text, ""], "\(screens.map { ($0.time, $0.text) })")
        #expect(abs((screens.first?.time ?? 0) - second.shown) < 0.001)
    }

    @Test("Screens read up to a seek or a window's end are provisional; a screen read through the step replaces them")
    func provisionalScreens() throws {
        let pairs = Factory.captionPairsPerPicture
        let decoder = try captionTrackDecoder()
        for picture in 0...31 { _ = try decode([pairs[picture]], at: Int64(picture), duration: 1, with: decoder) }
        let held = decoder.reset()
        #expect(held.map(\.text) == ["HELLO WORLD"] && held.allSatisfy(\.isProvisional), "Its step hasn't passed")
        for picture in 0...31 { _ = try decode([pairs[picture]], at: Int64(picture), duration: 1, with: decoder) }
        let finished = decoder.finish(provisional: true)
        #expect(!finished.isEmpty && finished.allSatisfy(\.isProvisional))

        typealias Screen = ClosedCaptionDecoder.Screen
        var state = LiveSubtitleTracker.LiveSubtitleState()
        LiveSubtitleTracker.addCaption(Screen(time: 1.0, text: "HELLO WORLD", alignment: .bottomCenter), to: &state)
        let stale = Screen(time: 2.5, text: "HELLO WORLD", alignment: .bottomCenter, isProvisional: true)
        #expect(LiveSubtitleTracker.addCaption(stale, to: &state))
        // Within the step of 2.5: the clear read through it wins though it has no text.
        #expect(LiveSubtitleTracker.addCaption(Screen(time: 2.55, text: "", alignment: .bottomCenter), to: &state))
        let late = Screen(time: 2.58, text: "OTHER", alignment: .bottomCenter, isProvisional: true)
        #expect(
            !LiveSubtitleTracker.addCaption(late, to: &state), "A provisional screen doesn't replace one read through")
        let cues = state.cues.filter { !$0.text.isEmpty }
        #expect(cues.map { "\($0.startTime)-\($0.endTime) \($0.text)" } == ["1.0-2.55 HELLO WORLD"])
    }

    @Test("A caption track's screen comes out with its packet when nothing follows within the step")
    func captionTrackScreenWithItsPacket() throws {
        let caption = Factory.popOnPairs(row: 15, text: "HELLO WORLD")
        let decoder = try captionTrackDecoder()
        // The packet lasts until the clear 1.5 s later, as FFmpeg muxes an SCC file into MOV.
        let shown = try decode(caption, at: 30, duration: 45, with: decoder)
        #expect(shown.map(\.text) == ["HELLO WORLD"])
        // One without a duration says nothing of what follows.
        let cleared = try decode(Factory.clearPairs, at: 75, with: decoder)
        #expect(cleared.map(\.text) == [""])
        // One that ends within its step leaves the screen for the next packet.
        let held = try decode(caption, at: 90, duration: 1, with: decoder)
        #expect(held.isEmpty)
        let next = try decode(Factory.clearPairs, at: 135, with: decoder)
        #expect(next.map(\.text) == ["HELLO WORLD", ""])
    }

    /// Plays the demuxer's packets to the end with the track selected; the cues it collected.
    private func collect(_ demuxer: MediaDemuxer, track: SubtitleTrack) -> [SubtitleCue] {
        demuxer.selectSubtitleTrack(trackId: track.id)
        while demuxer.nextVideoSample() != nil {}
        return demuxer.getLiveSubtitleDocument().cues.sorted { $0.startTime < $1.startTime }
    }

    private func expectScript(_ cues: [SubtitleCue], tolerance: Double = 0.05) {
        let script = Factory.captionScript
        #expect(cues.map(\.text) == script.map(\.text), "Cues: \(cues.map { ($0.startTime, $0.endTime, $0.text) })")
        for (cue, caption) in zip(cues, script) {
            #expect(abs(cue.startTime - caption.shown) < tolerance, "\(cue.text) from \(cue.startTime)")
            #expect(abs(cue.endTime - caption.cleared) < tolerance, "\(cue.text) to \(cue.endTime)")
            #expect(cue.alignment == (caption.row == 1 ? .topCenter : .bottomCenter))
        }
    }

    @Test("Captions in the pictures of MPEG-TS and Matroska H.264 are a CC1 track, timed by the pictures")
    func readsCaptionsFromPictures() throws {
        for preset in [Factory.Preset.captionsH264TS, .captionsH264MKV] {
            guard let path = Factory.ensureMedia(preset: preset) else { return }
            let demuxer = try #require(MediaDemuxer(url: path))
            #expect(demuxer.subtitleTracks.count == 1, "Field 2 carries padding only: no CC3")
            let track = try #require(demuxer.subtitleTracks.first)
            #expect(track.title == "CC1" && track.closedCaptionField == 0 && track.isSDH)
            #expect(track.streamIndex == demuxer.videoStreamIndex)
            expectScript(collect(demuxer, track: track))
        }
    }

    @Test("Captions read again after a seek back aren't listed twice")
    func seekBackKeepsCaptions() throws {
        guard let path = Factory.ensureMedia(preset: .captionsH264TS) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        _ = collect(demuxer, track: track)
        demuxer.seek(to: 0.5, exact: false)
        while demuxer.nextVideoSample() != nil {}
        expectScript(demuxer.getLiveSubtitleDocument().cues.sorted { $0.startTime < $1.startTime })
    }

    @Test("A window read takes the captions from the video stream and joins what playback collected")
    func readsWindow() throws {
        guard let path = Factory.ensureMedia(preset: .captionsH264TS) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        let selection = demuxer.liveSubtitleSelection
        #expect(selection.captionField == 0 && selection.streamIndex == demuxer.videoStreamIndex)
        let packets = try #require(
            EmbeddedSubtitleReader.readSubtitles(
                url: path, headers: [:], streamIndex: selection.streamIndex, captionField: selection.captionField,
                in: 0...6))
        #expect(packets.captionScreens.filter { !$0.text.isEmpty }.map(\.text) == Factory.captionScript.map(\.text))

        #expect(demuxer.mergeLiveSubtitles(packets, covering: 0...6, selection: selection.id, span: selection.span))
        expectScript(demuxer.getLiveSubtitleDocument().cues.sorted { $0.startTime < $1.startTime })
    }

    @Test("Selecting the captions doesn't take the video stream's packets from playback")
    func playbackKeepsPictures() throws {
        guard let path = Factory.ensureMedia(preset: .captionsH264TS) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        demuxer.seek(to: 3, exact: true)
        var pictures = 0
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures > 60, "Only \(pictures) pictures after the seek")
    }

    @Test("A stream number never picks captions in the video's pictures; an MP4 caption track has its own")
    func streamNumberSkipsVideoCaptions() {
        let tracks = [
            SubtitleTrack(
                id: 5, streamIndex: 0, title: "CC1", language: "", closedCaptionField: 0, captionsInVideo: true),
            SubtitleTrack(
                id: 6, streamIndex: 0, title: "CC3", language: "", closedCaptionField: 1, captionsInVideo: true),
            SubtitleTrack(id: 7, streamIndex: 2, title: "CC1", language: "", closedCaptionField: 0),
        ]
        #expect(PlayerEngine.resolveSubtitleSelection("stream:0", in: tracks) == nil)
        #expect(PlayerEngine.resolveSubtitleSelection("0", in: tracks) == nil)
        #expect(PlayerEngine.resolveSubtitleSelection("stream:2", in: tracks) == .select(trackId: 7))
        #expect(PlayerEngine.resolveSubtitleSelection("6", in: tracks) == .select(trackId: 6))
    }

    @Test("An MP4 caption track (c608) is a CC track decoded the same way")
    func readsC608Track() throws {
        guard let path = Factory.ensureMedia(preset: .captionsC608MOV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        #expect(demuxer.subtitleTracks.count == 1, "The H.264 pictures carry no captions of their own")
        #expect(track.closedCaptionField == 0 && track.isSDH && track.streamIndex != demuxer.videoStreamIndex)
        // SCC counts 29.97 frames a second: the clears land a few milliseconds early.
        expectScript(collect(demuxer, track: track), tolerance: 0.06)
    }
}
