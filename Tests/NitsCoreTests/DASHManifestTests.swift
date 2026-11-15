import Foundation
import Testing

@testable import NitsCore
@testable import NitsStreaming

/// What the resolver reads of DASH manifests (`DASHManifest`), from minimal manifests that have
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

    /// The ids of the sounds a manifest plays as added files, in order: a sound of segments is told to the client by the
    /// manifest's address with its id as the choice (`DASHSelection`), one that is a file by its address.
    static func soundIDs(_ manifest: DASHManifest?) -> [String] {
        (manifest?.sounds() ?? []).map { sound in
            let url = URL(string: sound.path)
            return DASHSelection(fragment: url?.fragment).audio ?? "file:" + (url?.lastPathComponent ?? "")
        }
    }

    @Test("The pictures of the best one's codec and range are a ladder; the others are left out of it")
    func buildsTheLadder() throws {
        let manifest = try #require(
            Self.manifest(
                """
                <AdaptationSet contentType="video"><SegmentTemplate media="s/$Number$" timescale="1" duration="1"/>
                \(Self.video("hi", 1920, 1080, bandwidth: 5_000_000))
                \(Self.video("mid", 1280, 720, bandwidth: 2_500_000))
                \(Self.video("lo", 640, 360, bandwidth: 800_000))
                \(Self.video("vp9", 1280, 720, codecs: "vp09.00.31.08", bandwidth: 1_000_000))
                \(Self.video("hevc", 1280, 720, codecs: "hvc1.2.4.L120", bandwidth: 1_500_000))
                </AdaptationSet>
                <AdaptationSet contentType="audio" lang="en"><Representation id="a" mimeType="audio/mp4" bandwidth="64000"/></AdaptationSet>
                """))
        #expect(manifest.ladder.map(\.id) == ["hi", "mid", "lo"], "One codec: a switch needs no new decoder")
        // The one picture of a manifest is no ladder.
        let single = try #require(
            Self.manifest(
                #"<AdaptationSet contentType="video">\#(Self.video("only", 1280, 720, bandwidth: 1))</AdaptationSet>"#))
        #expect(single.ladder.isEmpty)
        // A rung without a bitrate can't be told from the others by the network.
        let unknown = try #require(
            Self.manifest(
                #"<AdaptationSet contentType="video">\#(Self.video("a", 1280, 720, bandwidth: 0))\#(Self.video("b", 640, 360, bandwidth: 5))</AdaptationSet>"#
            ))
        #expect(unknown.ladder.isEmpty)
    }

    @Test("A picture is chosen by the manifest's address with its id; the sound of each language is the best")
    func addressesOnePictureAndKeepsTheBestAudio() throws {
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
        let best = try #require(manifest.address())
        #expect(
            best == "https://cdn.example/show/dash/manifest.mpd?token=abc#nits-video=hi", "The best, with the query")
        #expect(manifest.address(videoID: "lo")?.hasSuffix("#nits-video=lo") == true)
        #expect(manifest.address(videoID: "missing") == nil)
        // The best of the language, the main one's language first.
        #expect(Self.soundIDs(manifest) == ["en-96", "uk-128"])
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
        let ids = Set(Self.soundIDs(manifest))
        #expect(ids.contains("aac") && !ids.contains("ac4"), "AAC over the AC-4 of a higher bitrate")
        #expect(!ids.contains("mpegh") && ids.contains("unknown"), "A codec not known is tried")
        #expect(ids.isSuperset(of: ["eac3", "opus", "untold"]))
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
        #expect(Self.soundIDs(manifest) == ["aac"])
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

        let main = Self.manifest(
            "\(sound("commentary", 192_000, role("commentary")))\(sound("main", 128_000, role("main")))\(sound("plain", 160_000, ""))"
        )
        #expect(Self.soundIDs(main) == ["main"])

        // Without a main one, one without a role; a description only when there is nothing else.
        let plain = Self.manifest("\(sound("described", 192_000, description))\(sound("plain", 64_000, ""))")
        #expect(Self.soundIDs(plain) == ["plain"])
        let onlyDescribed = Self.manifest(
            "\(sound("alt", 64_000, role("alternate")))\(sound("described", 192_000, description))")
        #expect(Self.soundIDs(onlyDescribed).count == 1)
        // A dub is the sound of its language.
        #expect(Self.soundIDs(Self.manifest(sound("dub", 64_000, role("dub")))) == ["dub"])
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
        #expect(Self.soundIDs(manifest) == ["main"])
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
        #expect(Self.soundIDs(manifest) == ["en", "uk"])
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

    @Test("A manifest of no streams has nothing to play")
    func hasNothingForNoStreams() throws {
        let manifest = try #require(Self.manifest(#"<AdaptationSet contentType="text"></AdaptationSet>"#))
        #expect(manifest.videos.isEmpty && !manifest.hasAudio)
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

    @Test("What is not played is left out: text tracks (TTML), images, and the I-frame tracks of trick play")
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
        #expect(manifest.videos.map(\.id) == ["main"])
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
        for video in manifest.videos { #expect(manifest.address(videoID: video.id) != nil) }
    }

    // MARK: - Addresses

    @Test("The resolver and the client name the representations alike, repeated ids too, and group pictures alike")
    func namesAndGroupsAsTheClientDoes() throws {
        // Two sets with a representation "1" each: the second is named by its place, as the client does.
        let body = """
            <AdaptationSet contentType="video"><SegmentTemplate media="a/$Number$" duration="1"/>\
            \(Self.video("1", 1280, 720, bandwidth: 4_000_000))</AdaptationSet>\
            <AdaptationSet contentType="video"><SegmentTemplate media="b/$Number$" duration="1"/>\
            \(Self.video("1", 1280, 720, codecs: "hvc1.1.6.L120", bandwidth: 3_000_000))</AdaptationSet>\
            <AdaptationSet contentType="audio" lang="en"><SegmentTemplate media="e/$Number$" duration="1"/>\
            <Representation id="1" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>
            """
        let data = Self.mpd(period: body)
        let manifest = try #require(DASHManifest(data: data, url: Self.url))
        let presentation = try DASHPresentation.parse(data, url: Self.url)
        #expect(
            Set(manifest.videos.map(\.id)) == Set(presentation.representations.filter { $0.kind == .video }.map(\.id)))
        #expect(Set(manifest.videos.map(\.id)).count == 2)
        #expect(presentation.representations.map(\.id) == ["1", "1.1", "2.1"])
        // What each choice plays is the picture it names.
        for video in manifest.videos {
            let chosen = try DASHPlaylists.pictures(
                of: presentation.representations.filter { $0.kind == .video }, selection: DASHSelection(video: video.id)
            )
            #expect(chosen.map(\.id) == [video.id])
            #expect(chosen.first?.codecs.flatMap(CodecFamily.video(in:)) == video.family)
        }
        #expect(Self.soundIDs(manifest) == ["2.1"])

        // PQ and HLG of one codec are two groups for both.
        func hdr(_ id: String, _ value: String) -> String {
            Self.video(
                id, 1920, 1080, codecs: "hvc1.2.4.L120", bandwidth: 5_000_000,
                inside:
                    #"<SupplementalProperty schemeIdUri="urn:mpeg:mpegB:cicp:TransferCharacteristics" value="\#(value)"/>"#
            )
        }
        let ranges = try #require(
            DASHManifest(
                data: Self.mpd(
                    period:
                        #"<AdaptationSet contentType="video"><SegmentTemplate media="a/$Number$" duration="1"/>"#
                        + hdr("pq", "16") + hdr("hlg", "18") + "</AdaptationSet>"), url: Self.url))
        #expect(ranges.codecGroups.map(\.id).count == 2)
    }

    @Test(
        "A repeated id names the representation apart, but its templates' $RepresentationID$ stays the manifest's own")
    func templatesKeepTheManifestsID() throws {
        let body = """
            <AdaptationSet contentType="video"><SegmentTemplate media="v/$RepresentationID$/$Number$.m4s" duration="1"/>\
            \(Self.video("1", 1280, 720, bandwidth: 4_000_000))</AdaptationSet>\
            <AdaptationSet contentType="audio" lang="en"><SegmentTemplate media="a/$RepresentationID$/$Number$.m4s" duration="1"/>\
            <Representation id="1" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>
            """
        let presentation = try DASHPresentation.parse(Self.mpd(period: body), url: Self.url)
        #expect(presentation.representations.map(\.id) == ["1", "1.1"])
        let urls = presentation.representations.map { $0.segments.first?.url.path ?? "" }
        #expect(urls == ["/show/dash/v/1/1.m4s", "/show/dash/a/1/1.m4s"], "\(urls)")
    }

    @Test("A manifest without a type is a static one")
    func readsAManifestWithoutAType() throws {
        let data = Data(
            """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT1S"><Period>\
            <AdaptationSet contentType="video">\(Self.video("v", 640, 360, bandwidth: 1))</AdaptationSet></Period></MPD>
            """.utf8)
        #expect(DASHManifest(data: data, url: Self.url)?.videos.map(\.id) == ["v"])
    }

    @Test("A choice is the manifest's address with the picture's or sound's id in its fragment, and reads back from it")
    func choosesByTheFragment() throws {
        let manifest = URL(string: "https://cdn.example/a/manifest.mpd?token=abc&x=1#old")!
        #expect(DASHSelection().address(of: manifest) == "https://cdn.example/a/manifest.mpd?token=abc&x=1")
        for id in ["v", "1080p", "a&b=c", "x#y %", "0.1", "é"] {
            let video = try #require(URL(string: DASHSelection(video: id).address(of: manifest)))
            #expect(video.query == "token=abc&x=1")
            #expect(DASHPlaylists(media: video.absoluteString)?.selection == DASHSelection(video: id), "\(id)")
            let audio = try #require(URL(string: DASHSelection(audio: id).address(of: manifest)))
            #expect(DASHPlaylists(media: audio.absoluteString)?.selection == DASHSelection(audio: id), "\(id)")
        }
        #expect(DASHSelection(fragment: nil).isEmpty && DASHSelection(fragment: "section-2").isEmpty)
    }

    // MARK: - What is left to the client

    @Test(
        "A live manifest, one of several periods, and one that cannot be read are not handled: the client opens them as they are"
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
    }

    @Test("A manifest of sound alone plays; the picture is none")
    func playsAudioOnly() throws {
        let manifest = try #require(
            Self.manifest(
                #"<AdaptationSet contentType="audio" lang="en"><Representation id="a" mimeType="audio/mp4" bandwidth="64000"/></AdaptationSet>"#
            ))
        #expect(manifest.videos.isEmpty && manifest.hasAudio)
        #expect(manifest.address() == "https://cdn.example/show/dash/manifest.mpd?token=abc")
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
        #expect(DASHElements.duration(of: "PT0H9M54.00S") == 594)
        #expect(DASHElements.duration(of: "PT1H") == 3600)
        #expect(DASHElements.duration(of: "P1DT2H") == 93600)
        #expect(DASHElements.duration(of: "PT1.5S") == 1.5)
        #expect(DASHElements.duration(of: "10") == nil)
        #expect(DASHElements.duration(of: "PT10") == nil)
    }
}

extension DASHManifestTests {
    /// A WebM file of `id` (its index is its `Cues`, which the client does not read).
    static func webmFile(_ id: String, _ width: Int, _ height: Int, bandwidth: Int) -> String {
        video(
            id, width, height, codecs: "vp09.00.40.08", bandwidth: bandwidth,
            inside:
                #"<BaseURL>\#(id).webm</BaseURL><SegmentBase indexRange="800-1500"><Initialization range="0-799"/></SegmentBase>"#
        ).replacingOccurrences(of: "video/mp4", with: "video/webm")
    }

    static let fileSound = """
        <AdaptationSet contentType="audio" lang="en"><Representation id="en" mimeType="audio/webm" codecs="opus" \
        bandwidth="1"><BaseURL>en.webm</BaseURL><SegmentBase indexRange="300-400"><Initialization range="0-299"/>\
        </SegmentBase></Representation></AdaptationSet>
        """
    static let segmentedSound = """
        <AdaptationSet contentType="audio" lang="uk"><SegmentTemplate media="uk/$Number$.m4s" duration="4"/>\
        <Representation id="uk" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>
        """

    @Test(
        "Pictures that are files the client reads no index of play as files with their sounds; beside one it reads, left out"
    )
    func filesWithoutAnIndex() throws {
        let mp4 = Self.video(
            "m", 1280, 720, bandwidth: 2_000_000,
            inside:
                #"<BaseURL>m.mp4</BaseURL><SegmentBase indexRange="800-1500"><Initialization range="0-799"/></SegmentBase>"#
        )
        let mixed = try #require(
            DASHManifest(
                data: Self.mpd(
                    period: #"<AdaptationSet contentType="video">"#
                        + Self.webmFile("w", 1920, 1080, bandwidth: 3_000_000)
                        + mp4 + "</AdaptationSet>" + Self.fileSound), url: Self.url))
        #expect(mixed.videos.map(\.id) == ["m"], "The larger WebM file is left out beside the MP4 the client reads")
        #expect(!mixed.playsAsFiles)

        let files = try #require(
            DASHManifest(
                data: Self.mpd(
                    period: #"<AdaptationSet contentType="video">"#
                        + Self.webmFile("hi", 1920, 1080, bandwidth: 3_000_000)
                        + Self.webmFile("lo", 1280, 720, bandwidth: 1_000_000) + "</AdaptationSet>" + Self.fileSound
                        + Self.segmentedSound), url: Self.url))
        #expect(files.playsAsFiles)
        #expect(files.videos.map(\.id) == ["hi", "lo"])
        #expect(files.file(videoID: "hi") == URL(string: "hi.webm", relativeTo: Self.url)?.absoluteURL)
        let sounds = files.sounds()
        #expect(sounds.map(\.language) == ["en", "uk"])
        #expect(sounds.first?.path == URL(string: "en.webm", relativeTo: Self.url)?.absoluteURL.absoluteString)
        // A sound of segments is the manifest's address with it as the choice: no picture, no other sound.
        #expect(Self.soundIDs(files) == ["file:en.webm", "uk"])
        #expect(sounds.last?.path == "https://cdn.example/show/dash/manifest.mpd?token=abc#nits-audio=uk")
    }
}

extension DASHManifestTests {
    @Test("A file beside the same picture told by segments does not take its place: the segments' one is kept")
    func fileBesideTheSamePicture() throws {
        // Same size, codec and bitrate: one picture listed twice, as a WebM file and by a template.
        let template = Self.video(
            "t", 1920, 1080, codecs: "vp09.00.40.08", bandwidth: 3_000_000,
            inside: #"<SegmentTemplate media="t/$Number$.webm" duration="4"/>"#
        ).replacingOccurrences(of: "video/mp4", with: "video/webm")
        for order in [
            [Self.webmFile("w", 1920, 1080, bandwidth: 3_000_000), template],
            [template, Self.webmFile("w", 1920, 1080, bandwidth: 3_000_000)],
        ] {
            let manifest = try #require(
                DASHManifest(
                    data: Self.mpd(
                        period: #"<AdaptationSet contentType="video">"# + order.joined() + "</AdaptationSet>"),
                    url: Self.url))
            #expect(manifest.videos.map(\.id) == ["t"])
        }
    }

    @Test("Pictures played as files: a sound with an MP4 index, or of segments, goes to the client as the choice")
    func soundsBesideFiles() throws {
        let indexedSound = """
            <AdaptationSet contentType="audio" lang="de"><Representation id="de" mimeType="audio/mp4" codecs="mp4a.40.2" \
            bandwidth="1"><BaseURL>de.mp4</BaseURL><SegmentBase indexRange="700-800"><Initialization range="0-699"/>\
            </SegmentBase></Representation></AdaptationSet>
            """
        let endless = """
            <AdaptationSet contentType="audio" lang="uk"><SegmentTemplate media="uk/$Number$.m4s" timescale="1">\
            <SegmentTimeline><S t="0" d="4" r="-1"/></SegmentTimeline></SegmentTemplate>\
            <Representation id="uk" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="1"/></AdaptationSet>
            """
        // No length told: a timeline that repeats to the end has nothing to count to; its sound is left out, as it would be
        // a required one the client refuses.
        let manifest = try #require(
            DASHManifest(
                data: Self.mpd(
                    period: #"<AdaptationSet contentType="video">"# + Self.webmFile("hi", 1920, 1080, bandwidth: 1)
                        + "</AdaptationSet>" + Self.fileSound + indexedSound + endless, duration: ""),
                url: Self.url))
        #expect(manifest.playsAsFiles)
        let sounds = manifest.sounds()
        #expect(sounds.map(\.language) == ["en", "de"])
        #expect(Self.soundIDs(manifest) == ["file:en.webm", "de"])
        #expect(sounds[1].path.hasSuffix("#nits-audio=de"))
    }
}
