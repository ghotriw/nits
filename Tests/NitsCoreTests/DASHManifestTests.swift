import Foundation
import Testing

@testable import NitsCore

/// DASH manifests read and written again for FFmpeg's demuxer (`DASHManifest`), from minimal manifests that have
/// what each case is about.
@Suite("DASH manifest")
struct DASHManifestTests {
    static let url = URL(string: "https://cdn.example/show/dash/manifest.mpd?token=abc")!

    /// A manifest of `body` (the contents of a period of `duration`).
    static func mpd(
        period body: String, duration: String = "PT10S", attributes: String = "", base: String = ""
    ) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="\(duration)"\
             \(attributes)>\(base)<Period id="0">\(body)</Period></MPD>
            """.utf8)
    }

    static func video(
        _ id: String, _ width: Int, _ height: Int, codecs: String = "avc1.4d401f", bandwidth: Int,
        inside: String = #"<BaseURL>v.mp4</BaseURL>"#, attributes: String = ""
    ) -> String {
        """
        <Representation id="\(id)" mimeType="video/mp4" codecs="\(codecs)" width="\(width)" height="\(height)" \
        bandwidth="\(bandwidth)" \(attributes)>\(inside)</Representation>
        """
    }

    static func manifest(_ period: String, duration: String = "PT10S", base: String = "") -> DASHManifest? {
        DASHManifest(data: mpd(period: period, duration: duration, base: base), url: url)
    }

    @Test(
        "The pictures are listed best first: the larger one, at one size the HDR one, the preferred codec, then the higher bitrate"
    )
    func ranksPictures() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video">
                \(Self.video("sd", 640, 360, bandwidth: 800_000))
                \(Self.video("hd-low", 1920, 1080, bandwidth: 3_000_000))
                \(Self.video("hd-high", 1920, 1080, bandwidth: 5_000_000))
                \(Self.video("hd-hdr", 1920, 1080, codecs: "hvc1.2.4.L120", bandwidth: 4_000_000, attributes: #"frameRate="30000/1001""#))
                \(Self.video("unknown", 3840, 2160, codecs: "xyz1", bandwidth: 9_000_000))
                </AdaptationSet>
                """))
        // A codec that is not told ranks below the others whatever its size. The HDR flag comes from the manifest's
        // properties and Dolby Vision's codecs, not from HEVC alone.
        // (HEVC is the codec preferred over H.264 by default, whatever the bitrates.)
        #expect(manifest.videos.map(\.id) == ["hd-hdr", "hd-high", "hd-low", "sd", "unknown"])
        #expect(manifest.videos[0].codec == "HEVC")
        #expect(abs((manifest.videos[0].frameRate ?? 0) - 29.97) < 0.01)
    }

    @Test("A Dolby Vision or PQ picture ranks over an SDR one of its size")
    func ranksHDRFirst() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video">
                \(Self.video("sdr", 1920, 1080, bandwidth: 9_000_000))
                \(Self.video("dv", 1920, 1080, codecs: "dvh1.05.06", bandwidth: 5_000_000))
                \(Self.video("pq", 1920, 1080, bandwidth: 4_000_000, inside: #"<SupplementalProperty schemeIdUri="urn:mpeg:mpegB:cicp:TransferCharacteristics" value="16"/>"#))
                </AdaptationSet>
                """))
        #expect(manifest.videos.map(\.id) == ["dv", "pq", "sdr"])
        #expect(manifest.videos.map(\.isHDR) == [true, true, false])
    }

    @Test("A picture's codec that FFmpeg's DASH manifests tell as `vp9` is read as VP9")
    func readsVP9() throws {
        let manifest = try #require(
            Self.manifest(
                #"<AdaptationSet contentType="video">\#(Self.video("v", 640, 360, codecs: "vp9", bandwidth: 1))</AdaptationSet>"#
            ))
        #expect(manifest.videos.map(\.codec) == ["VP9"])
    }

    @Test("The pictures of the best one's codec and range are a ladder; the others are left out of it")
    func buildsTheLadder() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video">
                \(Self.video("hi", 1920, 1080, bandwidth: 5_000_000))
                \(Self.video("mid", 1280, 720, bandwidth: 2_500_000))
                \(Self.video("lo", 640, 360, bandwidth: 800_000))
                \(Self.video("vp9", 1280, 720, codecs: "vp09.00.31.08", bandwidth: 1_000_000))
                \(Self.video("hevc", 1280, 720, codecs: "hvc1.2.4.L120", bandwidth: 1_500_000))
                </AdaptationSet>
                <AdaptationSet contentType="audio" lang="en"><Representation id="a" mimeType="audio/mp4" bandwidth="64000"/></AdaptationSet>
                """))
        #expect(manifest.ladder.map(\.id) == ["hi", "mid", "lo"], "One codec: a switch needs no new decoder")
        let text = try #require(manifest.ladderText())
        for id in ["hi", "mid", "lo", "a"] { #expect(text.contains(#"id="\#(id)""#), "\(id)") }
        #expect(!text.contains(#"id="vp9""#) && !text.contains(#"id="hevc""#))
        // The one picture of a manifest is no ladder.
        let single = try #require(
            Self.manifest(
                #"<AdaptationSet contentType="video">\#(Self.video("only", 1280, 720, bandwidth: 1))</AdaptationSet>"#))
        #expect(single.ladder.isEmpty && single.ladderText() == nil)
        // A rung without a bitrate can't be told from the others by the network.
        let unknown = try #require(
            Self.manifest(
                #"<AdaptationSet contentType="video">\#(Self.video("a", 1280, 720, bandwidth: 0))\#(Self.video("b", 640, 360, bandwidth: 5))</AdaptationSet>"#
            ))
        #expect(unknown.ladder.isEmpty)
    }

    @Test(
        "Of the pictures a manifest lists, the written one has the chosen alone; the audio of each language, the best")
    func keepsOnePictureAndTheBestAudio() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video">
                \(Self.video("hi", 1920, 1080, bandwidth: 4_000_000))
                \(Self.video("lo", 640, 360, bandwidth: 500_000))
                </AdaptationSet>
                <AdaptationSet contentType="audio" lang="uk">
                <Representation id="uk-64" mimeType="audio/mp4" bandwidth="64000"/>
                <Representation id="uk-128" mimeType="audio/mp4" bandwidth="128000"/>
                </AdaptationSet>
                <AdaptationSet contentType="audio" lang="en"><Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
                <Representation id="en-96" mimeType="audio/mp4" bandwidth="96000"/>
                </AdaptationSet>
                """))
        let best = try #require(manifest.text())
        #expect(best.contains(#"id="hi""#) && !best.contains(#"id="lo""#))
        #expect(best.contains(#"id="uk-128""#) && !best.contains(#"id="uk-64""#), "The best of the language")
        // The main one's language first: the demuxer lists the streams in the order of the manifest.
        #expect(
            try #require(best.range(of: #"id="en-96""#)).lowerBound
                < (try #require(best.range(of: #"id="uk-128""#))).lowerBound)
        let other = try #require(manifest.text(videoID: "lo"))
        #expect(other.contains(#"id="lo""#) && !other.contains(#"id="hi""#))
        #expect(manifest.text(videoID: "missing") == nil)
    }

    @Test("A sound the build has no decoder for (AC-4, MPEG-H) is not played, however high its bitrate")
    func dropsAudioWithoutDecoder() throws {
        let sound = { (id: String, codecs: String, bandwidth: Int, lang: String) in
            """
            <AdaptationSet contentType="audio" lang="\(lang)"><Representation id="\(id)" mimeType="audio/mp4" \
            codecs="\(codecs)" bandwidth="\(bandwidth)"/></AdaptationSet>
            """
        }
        let manifest = try #require(
            Self.manifest(
                """
                \(sound("aac", "mp4a.40.2", 128_000, "en"))\(sound("ac4", "ac-4.02.01.01", 320_000, "en"))\
                \(sound("mpegh", "mhm1.0x0D", 400_000, "uk"))\(sound("unknown", "xyz9", 64_000, "uk"))\
                \(sound("eac3", "ec-3", 192_000, "de"))\(sound("opus", "opus", 96_000, "fr"))\
                \(sound("untold", "", 96_000, "es"))
                """))
        let text = try #require(manifest.text())
        #expect(text.contains(#"id="aac""#) && !text.contains(#"id="ac4""#), "AAC over the AC-4 of a higher bitrate")
        #expect(!text.contains(#"id="mpegh""#) && text.contains(#"id="unknown""#), "A codec not known is tried")
        #expect(text.contains(#"id="eac3""#) && text.contains(#"id="opus""#) && text.contains(#"id="untold""#))
    }

    @Test("Of a language, a decoder known beats one not known, whatever the bitrate")
    func prefersAKnownAudioCodec() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="audio" lang="en"><Representation id="odd" mimeType="audio/mp4" \
                codecs="xyz9" bandwidth="500000"/><Representation id="aac" mimeType="audio/mp4" codecs="mp4a.40.2" \
                bandwidth="64000"/></AdaptationSet>
                """))
        let text = try #require(manifest.text())
        #expect(text.contains(#"id="aac""#) && !text.contains(#"id="odd""#))
    }

    @Test("Of a language, the main sound is its sound: a commentary or a description of a higher bitrate is not")
    func prefersTheMainSound() throws {
        let sound = { (id: String, bandwidth: Int, extra: String) in
            """
            <AdaptationSet contentType="audio" lang="en">\(extra)<Representation id="\(id)" mimeType="audio/mp4" \
            bandwidth="\(bandwidth)"/></AdaptationSet>
            """
        }
        let role = { (value: String) in #"<Role schemeIdUri="urn:mpeg:dash:role:2011" value="\#(value)"/>"# }
        let description = #"<Accessibility schemeIdUri="urn:tva:metadata:cs:AudioPurposeCS:2007" value="1"/>"#

        let main = try #require(
            Self.manifest(
                "\(sound("commentary", 192_000, role("commentary")))\(sound("main", 128_000, role("main")))\(sound("plain", 160_000, ""))"
            )?.text())
        #expect(main.contains(#"id="main""#) && !main.contains(#"id="commentary""#) && !main.contains(#"id="plain""#))

        // Without a main one, one without a role; a description only when there is nothing else.
        let plain = try #require(
            Self.manifest("\(sound("described", 192_000, description))\(sound("plain", 64_000, ""))")?.text())
        #expect(plain.contains(#"id="plain""#) && !plain.contains(#"id="described""#))
        let onlyDescribed = try #require(
            Self.manifest("\(sound("alt", 64_000, role("alternate")))\(sound("described", 192_000, description))")?
                .text())
        #expect(onlyDescribed.contains(#"id="alt""#) || onlyDescribed.contains(#"id="described""#))
        // A dub is the sound of its language.
        let dub = try #require(Self.manifest(sound("dub", 64_000, role("dub")))?.text())
        #expect(dub.contains(#"id="dub""#))
    }

    @Test("A role or an accessibility descriptor on the representation counts as one on the set")
    func readsRolesOfRepresentations() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="audio" lang="en">\
                <Representation id="commentary" mimeType="audio/mp4" bandwidth="192000">\
                <Role schemeIdUri="urn:mpeg:dash:role:2011" value="commentary"/></Representation>\
                <Representation id="described" mimeType="audio/mp4" bandwidth="160000">\
                <Accessibility schemeIdUri="urn:tva:metadata:cs:AudioPurposeCS:2007" value="1"/></Representation>\
                <Representation id="main" mimeType="audio/mp4" bandwidth="64000">\
                <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/></Representation></AdaptationSet>
                """))
        let text = try #require(manifest.text())
        #expect(
            text.contains(#"id="main""#) && !text.contains(#"id="commentary""#) && !text.contains(#"id="described""#))
    }

    @Test("The languages are in the order the main sound's comes first")
    func ordersLanguagesByTheMainSound() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="audio" lang="uk"><Representation id="uk" mimeType="audio/mp4" bandwidth="1"/></AdaptationSet>
                <AdaptationSet contentType="audio" lang="en"><Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>\
                <Representation id="en" mimeType="audio/mp4" bandwidth="1"/></AdaptationSet>
                """))
        let text = try #require(manifest.text())
        #expect(
            try #require(text.range(of: #"id="en""#)).lowerBound
                < (try #require(text.range(of: #"id="uk""#))).lowerBound)
    }

    @Test("A manifest without a type is a static one, and is written so: FFmpeg wants it said")
    func writesTheType() throws {
        let data = Data(
            """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT1S"><Period>\
            <AdaptationSet contentType="video">\(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet></Period></MPD>
            """.utf8)
        let text = try #require(DASHManifest(data: data, url: Self.url)?.text())
        #expect(text.contains(#"type="static""#))
    }

    @Test("The kind of a set is told in any case, or by the content component some generators use")
    func readsKindsLoosely() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet mimeType="VIDEO/mp4">\(Self.video("upper", 1280, 720, bandwidth: 2))</AdaptationSet>
                <AdaptationSet><ContentComponent contentType="video"/>\(Self.video("component", 640, 360, bandwidth: 1))</AdaptationSet>
                <AdaptationSet contentType="Audio" lang="en"><Representation id="a" mimeType="audio/mp4" bandwidth="1"/></AdaptationSet>
                """))
        #expect(manifest.videos.map(\.id) == ["upper", "component"])
        #expect(manifest.hasAudio)
    }

    @Test("Text in a CDATA section joins the text around it")
    func joinsCDATA() throws {
        let element = try #require(
            XMLTreeElement.parse(Data("<a>one <![CDATA[two <b>]]> three</a>".utf8), limit: 1000))
        #expect(element.children.count == 1)
        #expect(element.text == "one two <b> three")
    }

    @Test("A manifest of no streams has nothing to write")
    func writesNothingForNoStreams() throws {
        let manifest = try #require(Self.manifest(#"<AdaptationSet contentType="text"></AdaptationSet>"#))
        #expect(manifest.videos.isEmpty && !manifest.hasAudio)
        #expect(manifest.text() == nil)
    }

    @Test("The codec of an audio is told by the build's decoders")
    func readsAudioCodecs() {
        #expect(CodecFamily.canDecodeAudio(in: "mp4a.40.2") == true)
        #expect(CodecFamily.canDecodeAudio(in: "mp4a.40.5, avc1.4d401f") == true)
        #expect(CodecFamily.canDecodeAudio(in: "mp4a.69") == true)
        #expect(CodecFamily.canDecodeAudio(in: "ec-3") == true)
        #expect(CodecFamily.canDecodeAudio(in: "Opus") == true)
        #expect(CodecFamily.canDecodeAudio(in: "ac-4.02.01.01") == false)
        #expect(CodecFamily.canDecodeAudio(in: "mhm1.0x0D") == false)
        #expect(CodecFamily.canDecodeAudio(in: "mp4a.7f") == nil)
        #expect(CodecFamily.canDecodeAudio(in: "mp4a") == nil)
        #expect(CodecFamily.canDecodeAudio(in: "") == nil)
        #expect(CodecFamily.canDecodeAudio(in: "xyz9") == nil)
    }

    @Test("A manifest larger than one is read to be is not read")
    func limitsTheSize() {
        let padding = String(repeating: " ", count: DASHManifest.sizeLimit)
        let big = Data(
            """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1S"><Period>\
            <AdaptationSet contentType="video">\(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet></Period>\
            </MPD>\(padding)
            """.utf8)
        #expect(DASHManifest(data: big, url: Self.url) == nil)
    }

    @Test("What FFmpeg cannot read is left out: text tracks (TTML), images, and the I-frame tracks of trick play")
    func dropsWhatCannotBeRead() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="text" lang="en"><Representation id="t" bandwidth="256" \
                mimeType="application/ttml+xml"><BaseURL>s-eng.ttml</BaseURL></Representation></AdaptationSet>
                <AdaptationSet mimeType="image/jpeg"><Representation id="thumbs" bandwidth="1"/></AdaptationSet>
                <AdaptationSet contentType="video"><EssentialProperty schemeIdUri="http://dashif.org/guidelines/trickmode" \
                value="main"/>\(Self.video("iframes", 1920, 1080, bandwidth: 100))</AdaptationSet>
                <AdaptationSet contentType="video">\(Self.video("main", 1280, 720, bandwidth: 2_000_000))</AdaptationSet>
                """))
        let text = try #require(manifest.text())
        #expect(!text.contains("ttml") && !text.contains("thumbs") && !text.contains("iframes"))
        #expect(manifest.videos.map(\.id) == ["main"])
    }

    @Test("A single file addressed by byte ranges (SegmentBase with an index) is kept as it is")
    func keepsSegmentBase() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video">\(Self.video("v", 1280, 720, bandwidth: 1, inside: #"<BaseURL>v.mp4</BaseURL><SegmentBase indexRange="828-3067" timescale="12288"><Initialization range="0-827"/></SegmentBase>"#))</AdaptationSet>
                """))
        let text = try #require(manifest.text())
        #expect(text.contains(#"<SegmentBase indexRange="828-3067" timescale="12288">"#))
        #expect(text.contains(#"<Initialization range="0-827"/>"#))
    }

    @Test("Protected (DRM) pictures and sounds are not played, and the manifest says it had them")
    func dropsProtectedStreams() throws {
        let protected = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video"><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>\
                \(Self.video("drm", 1920, 1080, bandwidth: 1))</AdaptationSet>
                """))
        #expect(protected.videos.isEmpty && !protected.hasAudio && protected.hasProtectedStreams)

        let mixed = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video">\(Self.video("clear", 640, 360, bandwidth: 1))\
                <Representation id="drm" mimeType="video/mp4" width="1920" height="1080" bandwidth="9">\
                <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"/></Representation></AdaptationSet>
                """))
        #expect(mixed.videos.map(\.id) == ["clear"] && mixed.hasProtectedStreams)
    }

    @Test("A representation with the same size, codec and bitrate in two sets is offered once; ids stay unique")
    func keepsIDsUnique() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video">\(Self.video("1", 1280, 720, bandwidth: 5))</AdaptationSet>
                <AdaptationSet contentType="video">\(Self.video("1", 1280, 720, bandwidth: 5))\(Self.video("1", 640, 360, bandwidth: 2))</AdaptationSet>
                """))
        #expect(manifest.videos.count == 2)
        #expect(Set(manifest.videos.map(\.id)).count == 2)
        for video in manifest.videos { #expect(manifest.text(videoID: video.id) != nil) }
    }

    // MARK: - Addresses

    @Test("Relative addresses are made absolute from the manifest's folder, or its own BaseURL")
    func makesBaseURLAbsolute() throws {
        let body = #"<AdaptationSet contentType="video">\#(Self.video("v", 1280, 720, bandwidth: 1))</AdaptationSet>"#
        let folder = try #require(Self.manifest(body)?.text())
        #expect(folder.contains("<BaseURL>https://cdn.example/show/dash/</BaseURL>"), "The query is not part of it")

        let relative = try #require(Self.manifest(body, base: "<BaseURL>../media/</BaseURL>")?.text())
        #expect(relative.contains("<BaseURL>https://cdn.example/show/media/</BaseURL>"))
        let absolute = try #require(Self.manifest(body, base: "<BaseURL>https://other.example/m/</BaseURL>")?.text())
        #expect(absolute.contains("<BaseURL>https://other.example/m/</BaseURL>"))
        #expect(absolute.components(separatedBy: "<BaseURL>https://other.example/").count == 2, "Only one at the top")
        // The ones below it stay relative to it.
        #expect(absolute.contains("<BaseURL>v.mp4</BaseURL>"))
    }

    @Test("Characters of addresses and templates survive the rewrite")
    func keepsTemplates() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video"><Representation id="a&amp;b" mimeType="video/mp4" bandwidth="1" width="2" height="2">\
                <SegmentTemplate media="seg/$RepresentationID$/$Number$.m4s?a=1&amp;b=2" startNumber="1" duration="2"/>\
                </Representation></AdaptationSet>
                """))
        let text = try #require(manifest.text())
        #expect(text.contains(#"media="seg/$RepresentationID$/$Number$.m4s?a=1&amp;b=2""#))
        #expect(text.contains(#"id="a&amp;b""#))
    }

    // MARK: - Timelines

    @Test("A timeline that repeats a segment to the end of the period ends at it")
    func expandsRepeatsToTheEnd() throws {
        let timeline = { (s: String, duration: String) in
            Self.manifest(
                """
                <AdaptationSet contentType="video"><SegmentTemplate timescale="1000" media="v_$Time$.m4s" initialization="i.mp4">\
                <SegmentTimeline>\(s)</SegmentTimeline></SegmentTemplate>\(Self.video("v", 1280, 720, bandwidth: 1, inside: ""))</AdaptationSet>
                """, duration: duration)?.text()
        }
        // Ten seconds of two: five segments, the first and four repeats.
        #expect(try #require(timeline(#"<S d="2000" r="-1"/>"#, "PT10S")).contains(#"<S d="2000" r="4"/>"#))
        // A last segment the period ends in the middle of is one too.
        #expect(try #require(timeline(#"<S d="2000" r="-1"/>"#, "PT9S")).contains(#"<S d="2000" r="4"/>"#))
        // Up to the next segment that says where it starts.
        let text = try #require(timeline(#"<S t="0" d="1000" r="-1"/><S t="5000" d="1000"/>"#, "PT10S"))
        #expect(text.contains(#"<S d="1000" r="4" t="0"/>"#), "\(text)")
        // Repeats counted are left as they are.
        #expect(try #require(timeline(#"<S d="2000" r="2"/>"#, "PT10S")).contains(#"r="2""#))
    }

    @Test("The timeline of a representation takes the timescale of the template above it, and a period's offset")
    func expandsWithInheritedTimescale() throws {
        // Akamai's: 12288 ticks a second, segments of five seconds, 9 min 54 s: 119 segments (118 repeats).
        let text = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video"><SegmentTemplate timescale="12288" media="v_$Time$.mp4">\
                <SegmentTimeline><S d="61440" r="-1"/></SegmentTimeline></SegmentTemplate>\
                \(Self.video("v", 1280, 720, bandwidth: 1, inside: ""))</AdaptationSet>
                """, duration: "PT0H9M54.00S")?.text())
        #expect(text.contains(#"r="118""#))
        // A template of the representation that has no timescale of its own.
        let inner = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video"><SegmentTemplate timescale="90000"/>\
                <Representation id="v" mimeType="video/mp4" bandwidth="1" width="2" height="2">\
                <SegmentTemplate media="v_$Time$.mp4"><SegmentTimeline><S d="180000" r="-1"/></SegmentTimeline>\
                </SegmentTemplate></Representation></AdaptationSet>
                """, duration: "PT10S")?.text())
        #expect(inner.contains(#"r="4""#))
    }

    @Test("A period's own length and start are what its timeline ends at")
    func usesThePeriodsLength() throws {
        let data = Data(
            """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT60S"><Period start="PT10S" duration="PT6S">\
            <AdaptationSet contentType="video"><SegmentTemplate timescale="1" media="v_$Time$.mp4"><SegmentTimeline>\
            <S d="2" r="-1"/></SegmentTimeline></SegmentTemplate>\(Self.video("v", 1280, 720, bandwidth: 1, inside: ""))\
            </AdaptationSet></Period></MPD>
            """.utf8)
        let text = try #require(DASHManifest(data: data, url: Self.url)?.text())
        #expect(text.contains(#"r="2""#), "Six seconds of two")

        let fromTheManifest = Data(
            """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT16S"><Period start="PT10S">\
            <AdaptationSet contentType="video"><SegmentTemplate timescale="1" media="v_$Time$.mp4"><SegmentTimeline>\
            <S d="2" r="-1"/></SegmentTimeline></SegmentTemplate>\(Self.video("v", 1280, 720, bandwidth: 1, inside: ""))\
            </AdaptationSet></Period></MPD>
            """.utf8)
        #expect(try #require(DASHManifest(data: fromTheManifest, url: Self.url)?.text()).contains(#"r="2""#))
    }

    // MARK: - What is left to the demuxer

    @Test(
        "A live manifest, one of several periods, one that cannot be read, and a timeline of an unknown length are not handled"
    )
    func declinesWhatItCannotHandle() {
        let video = #"<AdaptationSet contentType="video">\#(Self.video("v", 1280, 720, bandwidth: 1))</AdaptationSet>"#
        let live = Data(
            #"<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic"><Period>\#(video)</Period></MPD>"#.utf8)
        #expect(DASHManifest(data: live, url: Self.url) == nil)
        let periods = Data(
            #"<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"><Period>\#(video)</Period><Period>\#(video)</Period></MPD>"#
                .utf8)
        #expect(DASHManifest(data: periods, url: Self.url) == nil)
        #expect(DASHManifest(data: Data("not xml <".utf8), url: Self.url) == nil)
        #expect(DASHManifest(data: Data("<html/>".utf8), url: Self.url) == nil)
        // `r="-1"` with no length of the period to count to.
        let unknown = Data(
            """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"><Period><AdaptationSet contentType="video">\
            <SegmentTemplate timescale="1" media="v_$Time$.mp4"><SegmentTimeline><S d="2" r="-1"/></SegmentTimeline>\
            </SegmentTemplate>\(Self.video("v", 1280, 720, bandwidth: 1, inside: ""))</AdaptationSet></Period></MPD>
            """.utf8)
        #expect(DASHManifest(data: unknown, url: Self.url) == nil)
    }

    @Test("A manifest of sound alone plays; the picture is none")
    func playsAudioOnly() throws {
        let manifest = try #require(
            Self.manifest(
                #"<AdaptationSet contentType="audio" lang="en"><Representation id="a" mimeType="audio/mp4" bandwidth="64000"/></AdaptationSet>"#
            ))
        #expect(manifest.videos.isEmpty && manifest.hasAudio)
        #expect(try #require(manifest.text()).contains(#"id="a""#))
    }

    @Test("The title comes from the manifest's program information")
    func readsTheTitle() throws {
        let data = Data(
            """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1S">\
            <ProgramInformation><Title> Sintel </Title></ProgramInformation><Period>\
            <AdaptationSet contentType="video">\(Self.video("v", 1280, 720, bandwidth: 1))</AdaptationSet></Period></MPD>
            """.utf8)
        #expect(DASHManifest(data: data, url: Self.url)?.title == "Sintel")
        #expect(Self.manifest(#"<AdaptationSet contentType="video"></AdaptationSet>"#)?.title == nil)
    }

    @Test("Durations are read as ISO 8601 gives them")
    func readsDurations() {
        #expect(DASHManifest.duration(of: "PT0H9M54.00S") == 594)
        #expect(DASHManifest.duration(of: "PT1H") == 3600)
        #expect(DASHManifest.duration(of: "P1DT2H") == 93600)
        #expect(DASHManifest.duration(of: "PT1.5S") == 1.5)
        #expect(DASHManifest.duration(of: "10") == nil)
        #expect(DASHManifest.duration(of: "PT10") == nil)
    }
}
