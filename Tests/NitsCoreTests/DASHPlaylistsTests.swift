import Foundation
import Testing

@testable import NitsCore
@testable import NitsStreaming

/// A DASH manifest told to the client as HLS playlists (`DASHPresentation`, `DASHPlaylists`), from minimal manifests
/// that have what each case is about.
@Suite("DASH playlists")
struct DASHPlaylistsTests {
    static let url = URL(string: "https://cdn.example/show/dash/manifest.mpd?token=abc")!

    /// A manifest of `body` (the contents of a period).
    static func mpd(
        _ body: String, duration: String = "PT10S", type: String = "static", base: String = "", periods: Int = 1
    ) -> Data {
        let period = (0..<periods).map { #"<Period id="\#($0)">\#(body)</Period>"# }.joined()
        return Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="\(type)" mediaPresentationDuration="\(duration)">\
            \(base)\(period)</MPD>
            """.utf8)
    }

    static func parse(_ data: Data) throws -> DASHPresentation {
        try DASHPresentation.parse(data, url: url)
    }

    /// A picture of `width`×`height` with `inside` (its segment information) and `attributes`.
    static func video(
        _ id: String, _ width: Int, _ height: Int, bandwidth: Int, codecs: String = "avc1.4d401f", inside: String = "",
        attributes: String = ""
    ) -> String {
        """
        <Representation id="\(id)" codecs="\(codecs)" width="\(width)" height="\(height)" bandwidth="\(bandwidth)" \
        \(attributes)>\(inside)</Representation>
        """
    }

    static let template = """
        <SegmentTemplate timescale="1000" initialization="$RepresentationID$/init.mp4" \
        media="$RepresentationID$/seg-$Number%03d$.m4s" startNumber="5">\
        <SegmentTimeline><S t="0" d="4000" r="-1"/></SegmentTimeline></SegmentTemplate>
        """

    static func playlists(_ data: Data) throws -> DASHPlaylists.Built {
        try DASHPlaylists.build(try parse(data), id: "test")
    }

    static func master(_ built: DASHPlaylists.Built) throws -> HLSMasterPlaylist {
        guard let master = built.master else { throw HLSPlaylistError.mixedTypes }
        return master
    }

    // MARK: - Segments

    @Test(
        "A template's timeline repeated to the period's end: numbered from startNumber, addresses padded and relative")
    func timelineToPeriodEnd() throws {
        let presentation = try Self.parse(
            Self.mpd(
                #"<AdaptationSet contentType="video">\#(Self.template)\#(Self.video("v1", 1280, 720, bandwidth: 2_000_000))</AdaptationSet>"#
            ))
        let video = try #require(presentation.representations.first)
        // 10 s of 4 s segments: three, the last ending with the period.
        #expect(video.segments.map(\.number) == [5, 6, 7])
        #expect(video.segments.map(\.start) == [0, 4, 8])
        #expect(video.segments.map(\.duration) == [4, 4, 2])
        #expect(video.segments[0].url.absoluteString == "https://cdn.example/show/dash/v1/seg-005.m4s")
        #expect(video.initSection?.url.absoluteString == "https://cdn.example/show/dash/v1/init.mp4")
    }

    @Test("$Time$ addresses, a presentation time offset, BaseURL at every level")
    func timeAddresses() throws {
        let presentation = try Self.parse(
            Self.mpd(
                """
                <BaseURL>media/</BaseURL>\
                <AdaptationSet contentType="audio" lang="uk"><BaseURL>audio/</BaseURL>\
                <SegmentTemplate timescale="48000" presentationTimeOffset="96000" media="$Bandwidth$_$Time$.m4s">\
                <SegmentTimeline><S t="96000" d="96000" r="1"/><S d="48000"/></SegmentTimeline></SegmentTemplate>\
                <Representation id="a" codecs="mp4a.40.2" bandwidth="128000"/></AdaptationSet>
                """, base: "<BaseURL>https://media.example/root/</BaseURL>"))
        let audio = try #require(presentation.representations.first)
        #expect(audio.kind == .audio && audio.language == "uk")
        #expect(audio.presentationTimeOffset == 2)
        #expect(audio.segments.map(\.start) == [0, 2, 4])
        #expect(audio.segments.map(\.duration) == [2, 2, 1])
        #expect(
            audio.segments.map(\.url.absoluteString) == [
                "https://media.example/root/media/audio/128000_96000.m4s",
                "https://media.example/root/media/audio/128000_192000.m4s",
                "https://media.example/root/media/audio/128000_288000.m4s",
            ])
    }

    @Test("A template counted by @duration over the period: the last segment ends with it; endNumber caps the count")
    func durationTemplate() throws {
        func segments(_ extra: String) throws -> [DASHPresentation.Segment] {
            let data = Self.mpd(
                """
                <AdaptationSet contentType="video">\
                <SegmentTemplate timescale="10" duration="40" media="s$Number$.m4s" \(extra)/>\
                \(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet>
                """)
            return try #require(try Self.parse(data).representations.first).segments
        }
        let counted = try segments("")
        #expect(counted.map(\.number) == [1, 2, 3])
        #expect(counted.map(\.duration) == [4, 4, 2])
        #expect(try segments(#"endNumber="2""#).map(\.number) == [1, 2])
    }

    @Test("A segment list: byte ranges of one file, an initialization range, lengths from @duration")
    func segmentList() throws {
        let presentation = try Self.parse(
            Self.mpd(
                """
                <AdaptationSet contentType="video">\
                \(Self.video("v", 640, 360, bandwidth: 1, inside: """
                <BaseURL>v.mp4</BaseURL><SegmentList timescale="1000" duration="5000">\
                <Initialization range="0-799"/>\
                <SegmentURL mediaRange="800-1999"/><SegmentURL mediaRange="2000-2999"/></SegmentList>
                """))</AdaptationSet>
                """))
        let video = try #require(presentation.representations.first)
        #expect(video.initSection?.url.absoluteString == "https://cdn.example/show/dash/v.mp4")
        #expect(video.initSection?.byteRange == HLSByteRange(offset: 0, length: 800))
        #expect(
            video.segments.map(\.byteRange) == [
                HLSByteRange(offset: 800, length: 1200), HLSByteRange(offset: 2000, length: 1000),
            ])
        #expect(video.segments.map(\.start) == [0, 5])
        #expect(video.segments.map(\.duration) == [5, 5])
    }

    @Test("A set's template is the representation's, its own attributes overriding")
    func inheritedTemplate() throws {
        let presentation = try Self.parse(
            Self.mpd(
                """
                <AdaptationSet contentType="video">\(Self.template)\
                \(Self.video("a", 640, 360, bandwidth: 1))\
                \(Self.video("b", 1280, 720, bandwidth: 2, inside: #"<SegmentTemplate media="b/$Number$.mp4" startNumber="1"/>"#))\
                </AdaptationSet>
                """))
        let b = try #require(presentation.representations.last)
        #expect(b.segments.map(\.number) == [1, 2, 3])
        #expect(b.segments[0].url.lastPathComponent == "1.mp4")
        #expect(b.initSection?.url.absoluteString == "https://cdn.example/show/dash/b/init.mp4")
    }

    @Test("Template identifiers: $$, widths, and ones it does not know")
    func expandsIdentifiers() {
        #expect(DASHPresentation.expand("$$x$Number%05d$", id: "r", bandwidth: 1, number: 42) == "$x00042")
        #expect(DASHPresentation.expand("$RepresentationID$-$Bandwidth$", id: "r", bandwidth: 7) == "r-7")
        #expect(DASHPresentation.expand("$SubNumber$", id: "r", bandwidth: 1, number: 1) == nil)
        #expect(DASHPresentation.expand("$Time$", id: "r", bandwidth: 1) == nil)
        #expect(DASHPresentation.expand("open$Number", id: "r", bandwidth: 1, number: 1) == nil)
        #expect(
            DASHPresentation.expand(
                "$Number%08x$-$Time%X$-$Bandwidth%o$", id: "r", bandwidth: 8, number: 255, time: 255)
                == "000000ff-FF-10")
        #expect(DASHPresentation.expand("$Number%5d$", id: "r", bandwidth: 1, number: 1) == nil)
        #expect(DASHPresentation.expand("$RepresentationID%05d$", id: "r", bandwidth: 1) == nil)
    }

    // MARK: - Periods

    /// A manifest of periods, each (start, duration, directory, picture's id): a picture of 4 s segments and a sound in each.
    static func periods(_ periods: [(start: String?, duration: String, directory: String, videoID: String)]) -> Data {
        let body = periods.map { period in
            let start = period.start.map { " start=\"\($0)\"" } ?? ""
            return """
                <Period duration="\(period.duration)"\(start)>\
                <AdaptationSet contentType="video"><SegmentTemplate timescale="1000" \
                initialization="\(period.directory)/$RepresentationID$/init.mp4" \
                media="\(period.directory)/$RepresentationID$/$Number$.m4s" startNumber="1">\
                <SegmentTimeline><S t="0" d="4000" r="-1"/></SegmentTimeline></SegmentTemplate>\
                \(video(period.videoID, 1280, 720, bandwidth: 2_000_000))</AdaptationSet>\
                <AdaptationSet contentType="audio" lang="uk"><SegmentTemplate timescale="1000" \
                initialization="\(period.directory)/a/init.mp4" media="\(period.directory)/a/$Number$.m4s" \
                duration="4000"/><Representation id="a" codecs="mp4a.40.2" bandwidth="128000"/></AdaptationSet></Period>
                """
        }.joined()
        return Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT20S">\(body)</MPD>
            """.utf8)
    }

    @Test("Periods run on as one timeline: numbered across them, placed by their starts, each a discontinuity")
    func severalPeriods() throws {
        let built = try Self.playlists(
            Self.periods([(nil, "PT10S", "p0", "v"), (nil, "PT6S", "p1", "v"), ("PT20S", "PT4S", "p2", "v")]))
        let picture = try #require(built.entries.first { $0.representation.kind == .video })
        // 10 s: 4 + 4 + 2; the second lasts up to the third's start (10 s: 4 + 4 + 2, its 6 s extended); 4 s: one.
        #expect(picture.representation.segments.map(\.number) == [1, 2, 3, 4, 5, 6, 7])
        #expect(picture.representation.segments.map(\.period) == [0, 0, 0, 1, 1, 1, 2])
        #expect(picture.representation.segments.map(\.start) == [0, 4, 8, 10, 14, 18, 20])
        let playlist = try #require(picture.playlist)
        #expect(playlist.segments.map(\.sequence) == [1, 2, 3, 4, 5, 6, 7])
        #expect(playlist.segments.map(\.discontinuitySequence) == [0, 0, 0, 1, 1, 1, 2])
        #expect(playlist.segments[0].initSection?.url.absoluteString.hasSuffix("p0/v/init.mp4") == true)
        #expect(playlist.segments[3].initSection?.url.absoluteString.hasSuffix("p1/v/init.mp4") == true)
        #expect(playlist.segments[6].url.absoluteString.hasSuffix("p2/v/1.m4s"))
        #expect(built.entries.contains { $0.representation.kind == .audio })
    }

    /// `periods` with the sound of the given periods taken out (an advertisement's slate).
    static func silent(_ data: Data, periods silent: Set<Int>) throws -> Data {
        let text = try #require(String(data: data, encoding: .utf8))
        var parts = text.components(separatedBy: "<Period ")
        for number in silent {
            let part = parts[number + 1]
            let start = try #require(part.range(of: "<AdaptationSet contentType=\"audio\""))
            let end = try #require(part.range(of: "</AdaptationSet>", range: start.upperBound..<part.endIndex))
            parts[number + 1] = part.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "")
        }
        return Data(parts.joined(separator: "<Period ").utf8)
    }

    @Test("A period with no sound beside others that have some plays silent: the sound keeps its place by gaps")
    func silentPeriods() throws {
        let three = Self.periods([(nil, "PT10S", "p0", "v"), (nil, "PT10S", "p1", "v"), (nil, "PT10S", "p2", "v")])
        // In the middle: 4 + 4 + 2 s of sound, gaps as long as the segments (4 + 4 + 2 s), 4 + 4 + 2 s of sound.
        let middle = try Self.playlists(Self.silent(three, periods: [1]))
        let sound = try #require(middle.entries.first { $0.representation.kind == .audio })
        #expect(
            sound.representation.segments.map(\.isGap) == [false, false, false, true, true, true, false, false, false])
        #expect(sound.representation.segments.map(\.start) == [0, 4, 8, 10, 14, 18, 20, 24, 28])
        #expect(sound.representation.segments.map(\.period) == [0, 0, 0, 1, 1, 1, 2, 2, 2])
        #expect(sound.representation.segments.map(\.duration) == [4, 4, 2, 4, 4, 2, 4, 4, 2])
        let playlist = try #require(sound.playlist)
        #expect(playlist.segments.map(\.isGap) == sound.representation.segments.map(\.isGap))
        #expect(playlist.segments.map(\.discontinuitySequence) == [0, 0, 0, 1, 1, 1, 2, 2, 2])
        #expect(playlist.targetDuration == 4)

        // First: a slate before the film. Last: nothing after the sound needs its place kept.
        let leading = try Self.playlists(Self.silent(three, periods: [0]))
        let film = try #require(leading.entries.first { $0.representation.kind == .audio }).representation
        #expect(film.segments.prefix(3).allSatisfy(\.isGap) && film.segments.dropFirst(3).allSatisfy { !$0.isGap })
        #expect(film.segments.count == 9 && film.segments[3].start == 10)
        let trailing = try Self.playlists(Self.silent(three, periods: [2]))
        let early = try #require(trailing.entries.first { $0.representation.kind == .audio }).representation
        #expect(early.segments.count == 6 && early.segments.allSatisfy { !$0.isGap })

        // A period whose sound is told but not played (here protected) is not silent: refused, not played with a hole.
        let protected = try Self.changedInSecond(
            three, "<AdaptationSet contentType=\"audio\" lang=\"uk\">",
            "<AdaptationSet contentType=\"audio\" lang=\"uk\"><ContentProtection schemeIdUri=\"urn:x\"/>")
        #expect(Self.refusal(protected) == "sound that does not continue through every period")

        // No sound anywhere: no sound entry, the picture plays.
        let none = try Self.playlists(Self.silent(three, periods: [0, 1, 2]))
        #expect(!none.entries.contains { $0.representation.kind == .audio })
    }

    /// `of` replaced by `with` in the periods' text from the second period's first address on.
    static func changedInSecond(_ data: Data, _ of: String, _ with: String) throws -> Data {
        let text = try #require(String(data: data, encoding: .utf8))
        let second = try #require(text.range(of: "p1/"))
        return Data(text.replacingOccurrences(of: of, with: with, range: second.upperBound..<text.endIndex).utf8)
    }

    @Test("A representation continues by its id, else by the nearest of its kind and codec: an ad's ladder is its own")
    func continuation() throws {
        let same = Self.periods([(nil, "PT10S", "p0", "v"), (nil, "PT10S", "p1", "v")])
        // Named its own way: the same picture continues it.
        let named = try Self.playlists(Self.periods([(nil, "PT10S", "p0", "v"), (nil, "PT10S", "p1", "other")]))
        #expect(named.entries.filter { $0.representation.kind == .video }.map(\.representation.segments.count) == [6])
        // Another size and bitrate, the same codec: the nearest, so it continues.
        let smaller = try Self.changedInSecond(same, "width=\"1280\" height=\"720\"", "width=\"640\" height=\"360\"")
        let built = try Self.playlists(smaller)
        #expect(built.entries.filter { $0.representation.kind == .video }.map(\.representation.segments.count) == [6])
        // Two entries only: the sound and the one picture, which the other period's smaller one continues.
        #expect(built.entries.count == 2)
    }

    @Test(
        "A codec's family is never crossed: another codec in a period leaves the picture out, and a sound that does not continue refuses"
    )
    func continuationKeepsTheCodec() throws {
        let same = Self.periods([(nil, "PT10S", "p0", "v"), (nil, "PT10S", "p1", "v")])
        let otherPicture = try Self.changedInSecond(same, "avc1.4d401f", "hvc1.1.6.L93.B0")
        #expect(Self.refusal(otherPicture)?.contains("not in every period") == true)
        // The picture plays; the film's one sound found no continuation: refused, not played silent.
        let otherSound = try Self.changedInSecond(same, "mp4a.40.2", "ec-3")
        #expect(Self.refusal(otherSound) == "sound that does not continue through every period")
    }

    @Test("A period lasts up to the next one's start, not its own @duration; one of no length is not played")
    func periodLengths() throws {
        // The first says 10 s, the second starts at 8 s: no overlap.
        let built = try Self.playlists(Self.periods([(nil, "PT10S", "p0", "v"), ("PT8S", "PT10S", "p1", "v")]))
        let picture = try #require(built.entries.first { $0.representation.kind == .video }).representation
        #expect(picture.segments.map(\.start) == [0, 4, 8, 12, 16])
        #expect(picture.segments.map(\.duration) == [4, 4, 4, 4, 2])

        let skipped = try Self.playlists(
            Self.periods([(nil, "PT10S", "p0", "v"), (nil, "PT0S", "p1", "v"), (nil, "PT10S", "p2", "v")]))
        let kept = try #require(skipped.entries.first { $0.representation.kind == .video }).representation
        #expect(kept.segments.map(\.period) == [0, 0, 0, 1, 1, 1])
    }

    // MARK: - Refusals

    @Test("What is not played yet is refused with its reason: live, periods, one WebM file, offsets that differ")
    func refusals() throws {
        let video =
            #"<AdaptationSet contentType="video">\#(Self.template)\#(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet>"#
        func reason(_ data: Data) -> String? {
            let presentation: DASHPresentation
            do {
                presentation = try DASHPresentation.parse(data, url: Self.url)
            } catch {
                if case .unsupported(let reason) = error { return reason }
                return "\(error)"
            }
            do {
                _ = try DASHPlaylists.build(presentation, id: "t")
                return nil
            } catch {
                if case .unsupported(let reason) = error { return reason }
                return "\(error)"
            }
        }
        #expect(reason(Self.mpd(video, type: "dynamic"))?.contains("dynamic") == true)
        #expect(reason(Self.mpd(video, periods: 2)) == "a period whose length is not told")
        // The second starts before the first does: refused, not the first dropped as one of negative length.
        #expect(
            reason(Self.periods([("PT10S", "PT10S", "p0", "v"), ("PT5S", "PT10S", "p1", "v")]))
                == "periods out of order")
        #expect(reason(Self.mpd(video, type: "dynamic", periods: 2))?.contains("periods") == true)
        #expect(
            reason(
                Self.mpd(
                    #"<AdaptationSet contentType="video">\#(Self.video("v", 640, 360, bandwidth: 1, inside: #"<BaseURL>v.webm</BaseURL><SegmentBase indexRange="800-999"/>"#, attributes: #"mimeType="video/webm""#))</AdaptationSet>"#
                        // A sound it plays does not make it a stream of sound alone.
                        + #"<AdaptationSet contentType="audio"><SegmentTemplate media="a$Number$.m4s" duration="4"/><Representation id="a" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>"#
                ))?.contains("WebM") == true)
        let offsets = Self.mpd(
            video + """
                <AdaptationSet contentType="audio"><SegmentTemplate timescale="1000" presentationTimeOffset="500" \
                media="a$Number$.m4s" duration="4000"/><Representation id="a" codecs="mp4a.40.2" bandwidth="1"/>\
                </AdaptationSet>
                """)
        #expect(reason(offsets)?.contains("presentation time offsets that differ") == true)
        let protected = Self.mpd(
            #"<AdaptationSet contentType="video"><ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"/>\#(Self.template)\#(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet>"#
        )
        #expect(reason(protected)?.contains("DRM") == true)
        // Pictures whose every sound is left out are not played silent; one sound played beside it is enough.
        let webMSound = """
            <AdaptationSet contentType="audio"><Representation id="w" codecs="opus" bandwidth="1" mimeType="audio/webm">\
            <BaseURL>a.webm</BaseURL><SegmentBase indexRange="800-999"/></Representation></AdaptationSet>
            """
        #expect(reason(Self.mpd(video + webMSound))?.contains("WebM") == true)
        let mp4Sound = """
            <AdaptationSet contentType="audio"><SegmentTemplate media="a$Number$.m4s" duration="4"/>\
            <Representation id="a" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>
            """
        #expect(reason(Self.mpd(video + webMSound + mp4Sound)) == nil)
        // A picture that carries its sound (muxed) has it whatever else is left out.
        let muxed = video.replacingOccurrences(of: #"codecs="avc1.4d401f""#, with: #"codecs="avc1.4d401f,mp4a.40.2""#)
        #expect(reason(Self.mpd(muxed + webMSound)) == nil)
        #expect(throws: DASHPresentationError.unreadable) { try Self.parse(Data("<html/>".utf8)) }
    }

    // MARK: - Master and numbers

    @Test("A ladder across sets is numbered by the best picture's segments; a rung of other boundaries is left out")
    func ladderNumbersByTime() throws {
        let built = try Self.playlists(
            Self.mpd(
                """
                <AdaptationSet contentType="video">\
                <SegmentTemplate timescale="1000" media="hi/$Number$.m4s" startNumber="100">\
                <SegmentTimeline><S t="0" d="4000" r="-1"/></SegmentTimeline></SegmentTemplate>\
                \(Self.video("hi", 1920, 1080, bandwidth: 5_000_000))</AdaptationSet>\
                <AdaptationSet contentType="video">\
                <SegmentTemplate timescale="90000" media="lo/$Number$.m4s" startNumber="1">\
                <SegmentTimeline><S t="0" d="360000" r="-1"/></SegmentTimeline></SegmentTemplate>\
                \(Self.video("lo", 640, 360, bandwidth: 800_000))</AdaptationSet>\
                <AdaptationSet contentType="video">\
                <SegmentTemplate timescale="1000" media="odd/$Number$.m4s">\
                <SegmentTimeline><S t="0" d="5000" r="-1"/></SegmentTimeline></SegmentTemplate>\
                \(Self.video("odd", 1280, 720, bandwidth: 2_000_000))</AdaptationSet>
                """))
        let master = try Self.master(built)
        #expect(master.variants.map(\.bandwidth) == [5_000_000, 800_000])
        #expect(master.variants.allSatisfy { $0.audioGroup == nil })
        // Both numbered as the best one's: the lower rung's own numbers (1, 2, 3) would join a switch at another time.
        #expect(built.told.map { $0.segments.map(\.sequence) } == [[100, 101, 102], [100, 101, 102]])
        #expect(built.told[1].segments[0].url.absoluteString == "https://cdn.example/show/dash/lo/1.m4s")
        #expect(built.told[1].mediaSequence == 100 && built.told[1].hasEnded && built.told[1].type == .vod)
        #expect(master.variants[1].resolution == HLSResolution(width: 640, height: 360))
    }

    @Test("Pictures of another codec are a group of their own, numbered as their manifest says")
    func codecGroups() throws {
        let built = try Self.playlists(
            Self.mpd(
                """
                <AdaptationSet contentType="video">\(Self.template)\
                \(Self.video("avc", 1920, 1080, bandwidth: 5_000_000))\
                \(Self.video("hevc", 1920, 1080, bandwidth: 3_000_000, codecs: "hvc1.2.4.L120", attributes: "")) \
                </AdaptationSet>
                """))
        #expect(built.told.map { $0.segments.map(\.sequence) } == [[5, 6, 7], [5, 6, 7]])
        #expect(try Self.master(built).variants.map(\.codecs) == ["avc1.4d401f", "hvc1.2.4.L120"])
    }

    private static let twoCodecs = Self.mpd(
        """
        <AdaptationSet contentType="video">\(Self.template)\
        \(Self.video("avc-hi", 1920, 1080, bandwidth: 5_000_000))\
        \(Self.video("avc-lo", 960, 540, bandwidth: 1_000_000))\
        \(Self.video("hevc-hi", 1920, 1080, bandwidth: 3_000_000, codecs: "hvc1.2.4.L120"))\
        \(Self.video("hevc-lo", 960, 540, bandwidth: 600_000, codecs: "hvc1.2.4.L120"))\
        </AdaptationSet>
        <AdaptationSet contentType="audio" lang="en">\(Self.template)\
        <Representation id="en" codecs="mp4a.40.2" bandwidth="64000"/></AdaptationSet>
        """)

    @Test("A choice by the address plays the picture named with the ladder of its codec, and the sounds")
    func choosesALadder() throws {
        let presentation = try Self.parse(Self.twoCodecs)
        func variants(_ selection: DASHSelection) throws -> [String?] {
            let built = try DASHPlaylists.build(presentation, id: "t", selection: selection)
            #expect(try Self.master(built).renditions.count == 1, "The sound stays")
            return try Self.master(built).variants.map(\.codecs)
        }
        #expect(try variants(DASHSelection()).count == 4, "No choice: the manifest as it is")
        #expect(try variants(DASHSelection(video: "hevc-hi")) == ["hvc1.2.4.L120", "hvc1.2.4.L120"])
        #expect(
            try variants(DASHSelection(video: "avc-lo")) == ["avc1.4d401f", "avc1.4d401f"], "Any rung names its ladder")
    }

    @Test("A picture without a bitrate told is no ladder: the choice plays it alone; one the manifest lacks is refused")
    func choosesOnePicture() throws {
        let data = Self.mpd(
            """
            <AdaptationSet contentType="video">\(Self.template)\
            \(Self.video("a", 1920, 1080, bandwidth: 0))\(Self.video("b", 960, 540, bandwidth: 0))</AdaptationSet>
            """)
        let built = try DASHPlaylists.build(try Self.parse(data), id: "t", selection: DASHSelection(video: "b"))
        #expect(try Self.master(built).variants.map(\.resolution?.height) == [540])
        #expect(throws: HLSPlaylistSourceError.self) {
            try DASHPlaylists.build(try Self.parse(data), id: "t", selection: DASHSelection(video: "missing"))
        }
    }

    @Test("A sound chosen by the address is the stream alone, whichever the manifest's best is")
    func choosesASound() throws {
        let data = Self.mpd(
            """
            <AdaptationSet contentType="video">\(Self.template)\(Self.video("v", 1280, 720, bandwidth: 1))</AdaptationSet>
            <AdaptationSet contentType="audio" lang="en">\(Self.template)\
            <Representation id="en-hi" codecs="mp4a.40.2" bandwidth="128000"/>\
            <Representation id="en-lo" codecs="mp4a.40.2" bandwidth="64000"/></AdaptationSet>
            """)
        let presentation = try Self.parse(data)
        let best = try DASHPlaylists.build(presentation, id: "t")
        #expect(best.entries.map(\.representation.id) == ["en-hi", "v"])
        let chosen = try DASHPlaylists.build(presentation, id: "t", selection: DASHSelection(audio: "en-lo"))
        #expect(chosen.master == nil && chosen.entries.map(\.representation.id) == ["en-lo"])
        #expect(throws: HLSPlaylistSourceError.self) {
            try DASHPlaylists.build(presentation, id: "t", selection: DASHSelection(audio: "v"))
        }
    }

    @Test("The best sound of each language as an audio rendition, the main one first; the variants name the group")
    func soundsAsRenditions() throws {
        func sound(_ id: String, lang: String, bandwidth: Int, codecs: String = "mp4a.40.2", role: String = "")
            -> String
        {
            """
            <AdaptationSet contentType="audio" lang="\(lang)">\(role)\
            <SegmentTemplate timescale="1000" media="\(id)/$Number$.m4s" duration="4000"/>\
            <Representation id="\(id)" codecs="\(codecs)" bandwidth="\(bandwidth)"/></AdaptationSet>
            """
        }
        let built = try Self.playlists(
            Self.mpd(
                #"<AdaptationSet contentType="video">\#(Self.template)\#(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet>"#
                    + sound("en-low", lang: "en", bandwidth: 64_000)
                    + sound("en-high", lang: "en", bandwidth: 128_000)
                    + sound("en-ac4", lang: "en", bandwidth: 512_000, codecs: "ac-4.02.01.01")
                    + sound(
                        "uk", lang: "uk", bandwidth: 96_000,
                        role: #"<Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>"#)
                    + #"<AdaptationSet contentType="text" lang="uk"><Representation id="t" mimeType="application/ttml+xml" bandwidth="1"/></AdaptationSet>"#
            ))
        let master = try Self.master(built)
        #expect(master.renditions.map(\.language) == ["uk", "en"])
        #expect(master.renditions.map(\.isDefault) == [true, false])
        #expect(master.renditions.allSatisfy { $0.type == .audio && $0.groupID == "a" })
        #expect(master.variants.map(\.audioGroup) == ["a"])
        #expect(built.told[1].segments[0].url.lastPathComponent == "1.m4s")
        #expect(built.told[1].segments[0].url.deletingLastPathComponent().lastPathComponent == "en-high")
    }

    @Test("Sound alone is the stream's media playlist")
    func soundAlone() throws {
        let built = try Self.playlists(
            Self.mpd(
                #"<AdaptationSet contentType="audio"><SegmentTemplate media="$Number$.m4s" duration="4"/><Representation id="a" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>"#
            ))
        #expect(built.master == nil, "A master")
        #expect(built.media.first??.segments.count == 3)
    }

    // MARK: - The source

    @Test(
        "Keys of the source's own: the master, each playlist by its index; another source's or an unknown one is not served"
    )
    func keys() throws {
        let data = Self.mpd(
            #"<AdaptationSet contentType="video">\#(Self.template)\#(Self.video("v 1", 640, 360, bandwidth: 1))</AdaptationSet>"#
        )
        let source = DASHPlaylists(address: Self.url, inline: data)
        let transport = HTTPSessionTransport(source: Self.url.absoluteString, headers: [:]) { false }
        let loader = SegmentLoader(transport: transport)
        #expect(source.masterURL.scheme == "nits-dash")
        guard case .master(let master) = try source.playlist(at: source.masterURL, variables: [:], loader: loader)
        else {
            Issue.record("not a master")
            return
        }
        let variant = try #require(master.variants.first)
        #expect(variant.url.absoluteString.hasPrefix(source.masterURL.absoluteString + "0/"))
        #expect(variant.url.lastPathComponent == "v 1")
        guard case .media(let media) = try source.playlist(at: variant.url, variables: [:], loader: loader) else {
            Issue.record("not a media playlist")
            return
        }
        #expect(media.segments.count == 3)
        let other = DASHPlaylists(address: Self.url, inline: data)
        #expect(throws: HLSPlaylistSourceError.load(.notServed(variant.url))) {
            try other.playlist(at: variant.url, variables: [:], loader: loader)
        }
        let unknown = source.masterURL.appendingPathComponent("9")
        #expect(throws: HLSPlaylistSourceError.load(.notServed(unknown))) {
            try source.playlist(at: unknown, variables: [:], loader: loader)
        }
    }

    // MARK: - What a manifest's numbers may be

    /// The reason `data` is refused for, nil when it is read.
    static func refusal(_ data: Data) -> String? {
        do {
            _ = try DASHPresentation.parse(data, url: url)
            return nil
        } catch {
            if case .unsupported(let reason) = error { return reason }
            return "\(error)"
        }
    }

    static func timeline(_ entries: String, timescale: Int = 1000) -> Data {
        mpd(
            """
            <AdaptationSet contentType="video"><SegmentTemplate timescale="\(timescale)" media="$Number$.m4s">\
            <SegmentTimeline>\(entries)</SegmentTimeline></SegmentTemplate>\
            \(video("v", 640, 360, bandwidth: 1))</AdaptationSet>
            """)
    }

    @Test("Numbers past what a time or a count holds are refused, not a crash")
    func hugeNumbers() {
        #expect(Self.refusal(Self.timeline(#"<S d="10" r="9223372036854775807"/>"#)) != nil)
        #expect(Self.refusal(Self.timeline(#"<S t="9223372036854775800" d="100" r="1"/>"#)) != nil)
        // A repeat up to a start at the end of what a time holds counts more segments than an Int does.
        #expect(Self.refusal(Self.timeline(#"<S t="0" d="1" r="-1"/><S t="9223372036854775807" d="1"/>"#)) != nil)
        #expect(
            Self.refusal(
                Self.mpd(
                    #"<AdaptationSet contentType="video"><SegmentTemplate timescale="1000" duration="4000" media="$Number$.m4s"/>\#(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet>"#,
                    duration: "P300000000Y")) != nil)
        #expect(
            Self.refusal(
                Self.mpd(
                    #"<AdaptationSet contentType="video"><SegmentTemplate duration="4" startNumber="9223372036854775807" media="$Number$.m4s"/>\#(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet>"#
                )) == nil)
    }

    @Test(
        "A gap or an overlap in a timeline moves the end of the segment before it, as shaka-player does; time going back is refused; an S without a length is skipped"
    )
    func timelineGaps() throws {
        func durations(_ entries: String) throws -> [Double] {
            try #require(try Self.parse(Self.timeline(entries)).representations.first).segments.map(\.duration)
        }
        func starts(_ entries: String) throws -> [Double] {
            try #require(try Self.parse(Self.timeline(entries)).representations.first).segments.map(\.start)
        }
        #expect(try durations(#"<S t="0" d="2000"/><S t="6000" d="2000"/>"#) == [6, 2])
        #expect(try starts(#"<S t="0" d="2000"/><S t="6000" d="2000"/>"#) == [0, 6])
        #expect(try durations(#"<S t="0" d="2000"/><S t="1500" d="2000"/>"#) == [1.5, 2])
        #expect(try durations(#"<S t="0" d="2000"/><S d="0"/><S d="1000"/>"#) == [2, 1])
        #expect(Self.refusal(Self.timeline(#"<S t="4000" d="2000"/><S t="1000" d="2000"/>"#))?.contains("back") == true)
    }

    @Test("A repeat to the next S that says no start, or a later one, ends the timeline there")
    func repeatsThatCannotBeTold() throws {
        func count(_ entries: String) throws -> Int {
            try #require(try Self.parse(Self.timeline(entries)).representations.first).segments.count
        }
        #expect(try count(#"<S t="0" d="2000"/><S d="2000" r="-1"/><S d="2000"/>"#) == 1)
        #expect(try count(#"<S t="0" d="2000"/><S t="2000" d="2000" r="-1"/><S t="2000" d="1000"/>"#) == 1)
        // The period's 10 s: the last repeats up to it.
        #expect(try count(#"<S t="0" d="2000" r="-1"/>"#) == 5)
    }

    @Test(
        "A representation the client does not play is left out, not the manifest; with nothing left its reason refuses it"
    )
    func leavesOutOneRepresentation() throws {
        let presentation = try Self.parse(
            Self.mpd(
                #"<AdaptationSet contentType="video">\#(Self.template)\#(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet>"#
                    + #"<AdaptationSet contentType="audio"><Representation id="one-file" codecs="ac-4.02.01.01" bandwidth="1"><BaseURL>a.mp4</BaseURL><SegmentBase indexRange="0-9"/></Representation></AdaptationSet>"#
                    + #"<AdaptationSet contentType="audio"><SegmentList duration="4"/><Representation id="empty" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>"#
            ))
        #expect(presentation.representations.map(\.id) == ["v"])
        #expect(
            Self.refusal(
                Self.mpd(
                    #"<AdaptationSet contentType="audio"><SegmentList duration="4"/><Representation id="empty" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>"#
                )) == "empty: no segments")
    }

    @Test("With a picture of a codec it does not know, all are numbered as one ladder, as the client groups them then")
    func unknownCodecMakesOneLadder() throws {
        let built = try Self.playlists(
            Self.mpd(
                """
                <AdaptationSet contentType="video">\(Self.template)\
                \(Self.video("avc", 1920, 1080, bandwidth: 5_000_000))</AdaptationSet>\
                <AdaptationSet contentType="video">\
                <SegmentTemplate timescale="1000" media="x/$Number$.m4s" startNumber="0">\
                <SegmentTimeline><S t="0" d="4000" r="-1"/></SegmentTimeline></SegmentTemplate>\
                \(Self.video("unknown", 640, 360, bandwidth: 800_000, codecs: "xyz1"))</AdaptationSet>
                """))
        #expect(built.told.map { $0.segments.map(\.sequence) } == [[5, 6, 7], [5, 6, 7]])
    }

    @Test("A timeline that lists segments past the period's end ends with the period")
    func timelinePastPeriodEnd() throws {
        let segments = try #require(
            try Self.parse(Self.timeline(#"<S t="0" d="2000" r="9"/>"#)).representations.first
        ).segments
        #expect(segments.count == 5)
        #expect(segments.last?.duration == 2)
    }

    @Test(
        "What the representation tells wins over its set: its language, its own Initialization over the set's template's"
    )
    func lowerLevelWins() throws {
        let presentation = try Self.parse(
            Self.mpd(
                """
                <AdaptationSet contentType="audio" lang="en">\
                <SegmentTemplate initialization="init-$RepresentationID$.mp4" media="$Number$.m4s" duration="4"/>\
                <Representation id="uk" lang="uk" codecs="mp4a.40.2" bandwidth="1">\
                <SegmentTemplate><Initialization sourceURL="special.mp4"/></SegmentTemplate></Representation>\
                <Representation id="en" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>
                """))
        #expect(presentation.representations.map(\.language) == ["uk", "en"])
        #expect(
            presentation.representations.map { $0.initSection?.url.lastPathComponent } == [
                "special.mp4", "init-en.mp4",
            ])
    }

    @Test("A representation without an id is named as the resolver names it: its set's place and its own")
    func idlessRepresentation() throws {
        let presentation = try Self.parse(
            Self.mpd(
                #"<BaseURL>b/</BaseURL><AdaptationSet contentType="video"><SegmentTemplate media="$Number$.m4s" duration="4"/><Representation codecs="avc1.4d401f" bandwidth="1"/></AdaptationSet>"#
            ))
        let manifest = try #require(
            DASHManifest(
                data: Self.mpd(
                    #"<BaseURL>b/</BaseURL><AdaptationSet contentType="video"><SegmentTemplate media="$Number$.m4s" duration="4"/><Representation codecs="avc1.4d401f" bandwidth="1"/></AdaptationSet>"#
                ), url: Self.url))
        #expect(presentation.representations.map(\.id) == manifest.videos.map(\.id))
    }

    @Test("Protected streams are the reason given when nothing can be played, before one left out for another")
    func protectionIsTheReason() {
        let data = Self.mpd(
            #"<AdaptationSet contentType="video"><ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"/>\#(Self.template)\#(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet>"#
                + #"<AdaptationSet contentType="audio"><Representation id="a" codecs="mp4a.40.2" bandwidth="1"><BaseURL>a.mp4</BaseURL><SegmentBase indexRange="0-9"/></Representation></AdaptationSet>"#
        )
        #expect(Self.refusal(data)?.contains("DRM") == true)
    }
}

extension DASHPlaylistsTests {
    @Test("A demuxer's location names the source: an inline manifest, or an address that ends in .mpd, with its choice")
    func sourceOfALocation() throws {
        let text = "<MPD>https://signed.example/videoplayback?sig=secret</MPD>"
        let told = MediaURL.inlineDASHManifest(text)
        #expect(MediaURL.isInlineDASHManifest(told))
        let contents = try #require(StreamingURL.inlineDASHManifestContents(told))
        #expect(String(decoding: contents, as: UTF8.self) == text)
        // The manifest is not logged.
        let logged = MediaURL.loggable(told)
        #expect(!logged.contains("secret"), "\(logged)")

        // An inline manifest tells no address: relative addresses are relative to the master's key, none is served.
        let bare = try #require(DASHPlaylists(media: told))
        #expect(bare.address == bare.masterURL && !bare.allowsFiles && bare.selection.isEmpty)

        // The fragment is the choice, not a part of the address the requests go to.
        let chosen = try #require(
            DASHPlaylists(media: DASHSelection(video: "hd").address(of: Self.url)))
        #expect(chosen.address == Self.url && chosen.selection == DASHSelection(video: "hd"))
        let sound = try #require(DASHPlaylists(media: DASHSelection(audio: "uk").address(of: Self.url)))
        #expect(sound.address == Self.url && sound.selection == DASHSelection(audio: "uk"))

        let network = try #require(DASHPlaylists(media: "https://cdn.example/a/.mpd"))
        #expect(network.address.absoluteString == "https://cdn.example/a/.mpd" && !network.allowsFiles)
        let upper = try #require(DASHPlaylists(media: "HTTPS://cdn.example/a/manifest.mpd"))
        #expect(upper.address.absoluteString == "https://cdn.example/a/manifest.mpd" && !upper.allowsFiles)
        let file = try #require(DASHPlaylists(media: "/tmp/show/manifest.MPD"))
        #expect(file.address.isFileURL && file.allowsFiles)
        #expect(DASHPlaylists(media: "https://cdn.example/a/master.m3u8") == nil)
        #expect(DASHPlaylists(media: "data:text/plain;base64,AAAA") == nil)
    }
}

extension DASHPlaylists.Built {
    /// The playlists the manifest tells (none here is one file, told by its index).
    var told: [HLSMediaPlaylist] { media.compactMap { $0 } }
}
