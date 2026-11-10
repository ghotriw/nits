import Foundation
import Testing

@testable import NitsCore

/// `HLSPlaylist`: master and media playlists read from their text (RFC 8216 / 8216bis).
@Suite("HLS playlist")
struct HLSPlaylistTests {
    static let base = URL(string: "https://cdn.example.com/show/master.m3u8?token=abc")!

    static func master(_ text: String, url: URL = base) throws -> HLSMasterPlaylist {
        guard case .master(let playlist) = try HLSPlaylist.parse(text, url: url) else {
            Issue.record("not a master playlist")
            throw HLSPlaylistError.mixedTypes
        }
        return playlist
    }

    static func media(_ text: String, url: URL = base, variables: [String: String] = [:]) throws -> HLSMediaPlaylist {
        guard case .media(let playlist) = try HLSPlaylist.parse(text, url: url, variables: variables) else {
            Issue.record("not a media playlist")
            throw HLSPlaylistError.mixedTypes
        }
        return playlist
    }

    // MARK: Attribute lists

    @Test("Attribute lists: quoted strings keep their commas, names are matched whole, types read as the RFC says")
    func attributeLists() {
        let list = HLSAttributeList(
            #"BANDWIDTH=1280000, CODECS="avc1.4d401f,mp4a.40.2",SUPPLEMENTAL-CODECS="dvh1.08.07/db4h",RESOLUTION=1920x1080,FRAME-RATE=29.970,IV=0x1A2b,CLOSED-CAPTIONS=NONE,JUNK,DEFAULT=YES"#[
                ...]
        )
        #expect(list.integer("BANDWIDTH") == 1_280_000)
        #expect(list["CODECS"] == "avc1.4d401f,mp4a.40.2")
        #expect(list["SUPPLEMENTAL-CODECS"] == "dvh1.08.07/db4h")
        #expect(list.resolution("RESOLUTION") == HLSResolution(width: 1920, height: 1080))
        #expect(list.float("FRAME-RATE") == 29.97)
        #expect(list.hexadecimal("IV") == [0x1A, 0x2B])
        // An enumerated string isn't a quoted one.
        #expect(!list.isQuoted("CLOSED-CAPTIONS") && list["CLOSED-CAPTIONS"] == "NONE" && list.isQuoted("CODECS"))
        // A word without `=` is dropped, the pair after it kept.
        #expect(list.bool("DEFAULT") == true && list["JUNK"] == nil)
        #expect(HLSAttributeList(#"URI="never closed"#[...])["URI"] == "never closed")
        #expect(HLSAttributeList("IV=0x123"[...]).hexadecimal("IV") == [0x01, 0x23])
        #expect(HLSAttributeList("IV=123"[...]).hexadecimal("IV") == nil)
        #expect(HLSAttributeList("IV=0x+1"[...]).hexadecimal("IV") == nil)
        #expect(HLSAttributeList("IV=0x-01"[...]).hexadecimal("IV") == nil)
    }

    @Test("Byte ranges: a length and an optional offset")
    func byteRanges() {
        #expect(HLSByteRange.parse("1000@200").map { [$0.length, $0.offset ?? -1] } == [1000, 200])
        #expect(HLSByteRange.parse("1000").map { [$0.length, $0.offset ?? -1] } == [1000, -1])
        #expect(HLSByteRange.parse("1000@") == nil)
        #expect(HLSByteRange.parse("-5") == nil)
        #expect(HLSByteRange.parse("1@2@3") == nil)
        // Past Int64.max.
        #expect(HLSByteRange.parse("10@9223372036854775800") == nil)
        #expect(HLSByteRange(offset: Int64.max, length: 1) == nil)
    }

    // MARK: Master playlists

    @Test("A master playlist: variants with their attributes, renditions of groups, URIs resolved against it")
    func masterPlaylist() throws {
        let playlist = try Self.master(
            """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-START:TIME-OFFSET=-12.5,PRECISE=YES
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="keys/session.key"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",LANGUAGE="en",DEFAULT=YES,CHANNELS="2",URI="audio/en.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Українська",LANGUAGE="uk",AUTOSELECT=YES,CHANNELS="16/JOC",URI="audio/uk.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English (forced)",LANGUAGE="en",FORCED=YES,CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog, public.easy-to-read",URI="/subs/en.m3u8"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",INSTREAM-ID="CC1"
            #EXT-X-MEDIA:TYPE=AUDIO,NAME="no group"
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=86000,URI="iframes.m3u8"

            #EXT-X-STREAM-INF:BANDWIDTH=8000000,AVERAGE-BANDWIDTH=6000000,CODECS="hvc1.2.4.L150.B0,mp4a.40.2",SUPPLEMENTAL-CODECS="dvh1.08.07/db4h",RESOLUTION=3840x2160,FRAME-RATE=23.976,VIDEO-RANGE=PQ,HDCP-LEVEL=TYPE-1,AUDIO="aac",SUBTITLES="subs",CLOSED-CAPTIONS="cc",SCORE=2.5
            video/2160p.m3u8
            # a comment between
            #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=640x360,AUDIO="aac",CLOSED-CAPTIONS=NONE
            https://other.example.com/360p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=1
            """)
        #expect(playlist.version == 7 && playlist.hasIndependentSegments)
        #expect(playlist.start == HLSStart(timeOffset: -12.5, isPrecise: true))
        #expect(playlist.sessionKeys.map(\.url?.absoluteString) == ["https://cdn.example.com/show/keys/session.key"])

        // The variant without a URI line is dropped; the I-frame playlist isn't a variant.
        #expect(playlist.variants.count == 2)
        let uhd = playlist.variants[0]
        #expect(uhd.url.absoluteString == "https://cdn.example.com/show/video/2160p.m3u8")
        #expect(uhd.bandwidth == 8_000_000 && uhd.averageBandwidth == 6_000_000 && uhd.score == 2.5)
        #expect(uhd.codecs == "hvc1.2.4.L150.B0,mp4a.40.2" && uhd.supplementalCodecs == "dvh1.08.07/db4h")
        #expect(uhd.resolution == HLSResolution(width: 3840, height: 2160) && uhd.frameRate == 23.976)
        #expect(uhd.videoRange == .pq && uhd.hdcpLevel == "TYPE-1")
        #expect(uhd.audioGroup == "aac" && uhd.subtitlesGroup == "subs" && uhd.closedCaptionsGroup == "cc")
        let low = playlist.variants[1]
        #expect(low.url.absoluteString == "https://other.example.com/360p.m3u8")
        #expect(low.closedCaptionsGroup == "" && low.videoRange == nil && low.averageBandwidth == nil)

        // The rendition without a group is dropped.
        #expect(playlist.renditions.count == 4)
        let audio = playlist.renditions(.audio, group: "aac")
        #expect(audio.map(\.name) == ["English", "Українська"])
        #expect(
            audio.map(\.url?.absoluteString) == [
                "https://cdn.example.com/show/audio/en.m3u8", "https://cdn.example.com/show/audio/uk.m3u8",
            ])
        // DEFAULT makes AUTOSELECT.
        #expect(audio[0].isDefault && audio[0].autoselect && !audio[1].isDefault && audio[1].autoselect)
        #expect(audio.map(\.channels) == ["2", "16/JOC"] && audio.map(\.language) == ["en", "uk"])
        let subtitles = try #require(playlist.renditions(.subtitles, group: "subs").first)
        #expect(subtitles.isForced && subtitles.url?.absoluteString == "https://cdn.example.com/subs/en.m3u8")
        #expect(
            subtitles.characteristics == [
                "public.accessibility.transcribes-spoken-dialog", "public.easy-to-read",
            ])
        let captions = try #require(playlist.renditions(.closedCaptions, group: "cc").first)
        #expect(captions.instreamID == "CC1" && captions.url == nil)
    }

    @Test("A rendition without a URI is carried in the variant's segments")
    func muxedRendition() throws {
        let playlist = try Self.master(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",DEFAULT=YES
            #EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO="a"
            v.m3u8
            """)
        #expect(playlist.renditions.first?.url == nil)
    }

    // MARK: Media playlists

    @Test("A finished media playlist: segments numbered from the media sequence, durations, titles skipped")
    func vodPlaylist() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:10
            #EXT-X-MEDIA-SEQUENCE:5
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:9.009,
            first.ts
            #EXTINF:10, a title, with commas
            second.ts

            #EXTINF:3.003
            /abs/third.ts
            #EXT-X-ENDLIST
            """)
        #expect(playlist.version == 3 && playlist.targetDuration == 10 && playlist.mediaSequence == 5)
        #expect(playlist.type == .vod && playlist.hasEnded && !playlist.isLive)
        #expect(playlist.segments.map(\.sequence) == [5, 6, 7])
        #expect(playlist.segments.map(\.duration) == [9.009, 10, 3.003])
        #expect(
            playlist.segments.map(\.url.absoluteString) == [
                "https://cdn.example.com/show/first.ts", "https://cdn.example.com/show/second.ts",
                "https://cdn.example.com/abs/third.ts",
            ])
        #expect(abs(playlist.duration - 22.012) < 1e-9)
    }

    @Test("Media playlists served elsewhere resolve their segments against where they were served from")
    func resolvesAgainstServedURL() throws {
        let served = URL(string: "https://edge-7.example.net/live/abc/index.m3u8")!
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            seg1.ts?sig=1
            #EXTINF:4,
            ../other/seg2.ts
            """, url: served)
        #expect(
            playlist.segments.map(\.url.absoluteString) == [
                "https://edge-7.example.net/live/abc/seg1.ts?sig=1", "https://edge-7.example.net/live/other/seg2.ts",
            ])
        // Live: no end, no type.
        #expect(playlist.isLive && playlist.type == nil)
    }

    @Test("Discontinuities number runs from the discontinuity sequence; dates continue within a run only")
    func discontinuitiesAndDates() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MEDIA-SEQUENCE:100
            #EXT-X-DISCONTINUITY-SEQUENCE:7
            #EXT-X-PROGRAM-DATE-TIME:2026-11-10T12:00:00.000Z
            #EXTINF:6,
            a.ts
            #EXTINF:6,
            b.ts
            #EXT-X-DISCONTINUITY
            #EXTINF:5,
            ad1.ts
            #EXT-X-DISCONTINUITY
            #EXT-X-PROGRAM-DATE-TIME:2026-11-10T14:00:17+02:00
            #EXTINF:6,
            c.ts
            #EXT-X-GAP
            #EXTINF:6,
            d.ts
            """)
        #expect(playlist.discontinuitySequence == 7)
        #expect(playlist.segments.map(\.discontinuitySequence) == [7, 7, 8, 9, 9])
        #expect(playlist.segments.map(\.isDiscontinuity) == [false, false, true, true, false])
        #expect(playlist.segments.map(\.isGap) == [false, false, false, false, true])
        let noon = try #require(HLSPlaylist.date("2026-11-10T12:00:00Z"))
        #expect(
            playlist.segments.map(\.programDateTime) == [
                noon, noon.addingTimeInterval(6), nil, noon.addingTimeInterval(17), noon.addingTimeInterval(23),
            ])
    }

    @Test("Byte ranges: an offset given, or following the previous range of the same file, else from its start")
    func byteRangeSegments() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-VERSION:7
            #EXT-X-MAP:URI="main.mp4",BYTERANGE="720@0"
            #EXTINF:6,
            #EXT-X-BYTERANGE:1000@720
            main.mp4
            #EXTINF:6,
            #EXT-X-BYTERANGE:2000
            main.mp4
            #EXTINF:6,
            #EXT-X-BYTERANGE:500
            other.mp4
            #EXTINF:6,
            main.mp4
            """)
        #expect(
            playlist.segments.map(\.byteRange) == [
                HLSByteRange(offset: 720, length: 1000), HLSByteRange(offset: 1720, length: 2000),
                HLSByteRange(offset: 0, length: 500), nil,
            ])
        let initSection = try #require(playlist.segments.first?.initSection)
        #expect(initSection.byteRange == HLSByteRange(offset: 0, length: 720))
        #expect(initSection.url.absoluteString == "https://cdn.example.com/show/main.mp4")
        #expect(playlist.segments.allSatisfy { $0.initSection == initSection })
    }

    @Test("An init section applies until the next; one without a byte range is the whole file")
    func initSections() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MAP:URI="init-a.mp4"
            #EXTINF:4,
            a1.m4s
            #EXTINF:4,
            a2.m4s
            #EXT-X-DISCONTINUITY
            #EXT-X-MAP:URI="init-b.mp4"
            #EXTINF:4,
            b1.m4s
            """)
        #expect(
            playlist.segments.map { $0.initSection?.url.lastPathComponent } == [
                "init-a.mp4", "init-a.mp4", "init-b.mp4",
            ])
        #expect(playlist.segments.allSatisfy { $0.initSection?.byteRange == nil })
    }

    @Test("Keys apply until the next key tag; METHOD=NONE clears; the IV defaults to the media sequence number")
    func keys() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:258
            #EXT-X-KEY:METHOD=AES-128,URI="k1.key"
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:4,
            s1.ts
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k2",IV=0x000102030405060708090a0b0c0d0e0f
            #EXTINF:4,
            s2.ts
            #EXT-X-KEY:METHOD=NONE
            #EXTINF:4,
            s3.ts
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fairplay",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
            #EXT-X-KEY:METHOD=AES-128,URI="k4.key"
            #EXTINF:4,
            s4.ts
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fairplay",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXTINF:4,
            s5.ts
            """)
        let segments = playlist.segments
        #expect(segments[0].key?.url?.absoluteString == "https://cdn.example.com/show/k1.key")
        #expect(segments[0].key?.isDecryptable == true)
        // The init section is encrypted with the key in effect where it stands.
        #expect(segments[0].initSection?.key == segments[0].key)
        // 258 = 0x0102.
        #expect(segments[0].initializationVector == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02])
        #expect(segments[1].initializationVector == Array(0..<16))
        #expect(segments[2].key == nil && segments[2].initializationVector == nil)
        // Keys of several formats side by side: the identity one is what Nits decrypts with.
        #expect(segments[3].key?.method == .aes128 && segments[3].key?.keyFormat == "identity")
        // A key tag after a segment starts a new set: the identity key no longer applies.
        // A key of another format rotated: the identity one still applies (one per KEYFORMAT).
        #expect(segments[4].key?.method == .aes128 && segments[4].key?.isDecryptable == true)
    }

    @Test("Bitrates apply until the next tag")
    func bitrates() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            a.ts
            #EXT-X-BITRATE:1500
            #EXTINF:4,
            b.ts
            #EXTINF:4,
            c.ts
            """)
        #expect(playlist.segments.map(\.bitrate) == [nil, 1500, 1500])
    }

    @Test("Lenient: a BOM, CRLF, whitespace, unknown tags, a URI without EXTINF, no target duration")
    func lenient() throws {
        let playlist = try Self.media(
            "\u{FEFF}#EXTM3U\r\n#EXT-X-UNKNOWN:FOO=1\r\n  #EXTINF:4.5,\r\n a.ts  \r\nstray.ts\r\n#EXTINF:6.2,\r\nb.ts\r\n"
        )
        #expect(playlist.segments.map(\.url.lastPathComponent) == ["a.ts", "b.ts"])
        #expect(playlist.segments.map(\.sequence) == [0, 1])
        #expect(playlist.targetDuration == 6)
    }

    @Test(
        "A URI skipped for want of EXTINF takes its tags along, but for a discontinuity, which the next segment keeps")
    func strayURIKeepsItsTags() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-BYTERANGE:500@0
            #EXT-X-GAP
            #EXT-X-DISCONTINUITY
            #EXT-X-PROGRAM-DATE-TIME:2026-11-10T12:00:00Z
            stray.ts
            #EXTINF:4,
            a.ts
            """)
        let segment = try #require(playlist.segments.first)
        #expect(segment.byteRange == nil && !segment.isGap && segment.isDiscontinuity)
        #expect(segment.programDateTime == nil && segment.discontinuitySequence == 1)
    }

    @Test("Variables aren't substituted in tags not read: one undefined there fails nothing")
    func variablesInUnreadTags() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-DATERANGE:ID="ad",START-DATE="2026-11-10T12:00:00Z",X-ASSET-URI="https://ads.example.com/{$adid}"
            #EXT-X-VENDOR-THING:{$nope}
            #EXTINF:4,
            a.ts
            """)
        #expect(playlist.segments.count == 1)
    }

    @Test("An empty live playlist is a media playlist")
    func emptyLive() throws {
        let playlist = try Self.media("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:40\n")
        #expect(playlist.segments.isEmpty && playlist.isLive && playlist.mediaSequence == 40)
    }

    @Test("Event playlists and I-frame playlists are told")
    func types() throws {
        let event = try Self.media("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\na.ts\n")
        #expect(event.type == .event && event.isLive)
        let frames = try Self.media("#EXTM3U\n#EXT-X-I-FRAMES-ONLY\n#EXT-X-TARGETDURATION:2\n#EXT-X-ENDLIST\n")
        #expect(frames.isIFramesOnly && !frames.isLive)
    }

    // MARK: Variables

    @Test("EXT-X-DEFINE: values, imports from the master, query parameters of the playlist's URL")
    func variables() throws {
        let master = try Self.master(
            """
            #EXTM3U
            #EXT-X-DEFINE:NAME="host",VALUE="https://media.example.com"
            #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.640028"
            {$host}/v1/index.m3u8
            """)
        #expect(master.variants.first?.url.absoluteString == "https://media.example.com/v1/index.m3u8")
        #expect(master.variables == ["host": "https://media.example.com"])

        let media = try Self.media(
            """
            #EXTM3U
            #EXT-X-DEFINE:IMPORT="host"
            #EXT-X-DEFINE:QUERYPARAM="token"
            #EXT-X-TARGETDURATION:4
            #EXT-X-MAP:URI="{$host}/init.mp4?t={$token}"
            #EXTINF:4,
            {$host}/s1.m4s?t={$token}
            """, variables: master.variables)
        #expect(media.segments.first?.url.absoluteString == "https://media.example.com/s1.m4s?t=abc")
        #expect(media.segments.first?.initSection?.url.absoluteString == "https://media.example.com/init.mp4?t=abc")
    }

    @Test("Sequence tags written after the segments number them all the same")
    func lateSequenceTags() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            a.ts
            #EXT-X-DISCONTINUITY
            #EXTINF:4,
            b.ts
            #EXT-X-MEDIA-SEQUENCE:120
            #EXT-X-DISCONTINUITY-SEQUENCE:3
            """)
        #expect(playlist.mediaSequence == 120 && playlist.segments.map(\.sequence) == [120, 121])
        #expect(playlist.segments.map(\.discontinuitySequence) == [3, 4])
    }

    @Test("A target duration is never shorter than the longest segment")
    func targetDurationFloor() throws {
        let zero = try Self.media("#EXTM3U\n#EXT-X-TARGETDURATION:0\n#EXTINF:5.5,\na.ts\n#EXTINF:6,\nb.ts\n")
        #expect(zero.targetDuration == 6)
        let declared = try Self.media("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:5.5,\na.ts\n")
        #expect(declared.targetDuration == 10)
        // Compared rounded to the nearest second, as the RFC does: 6.006 is within a target of 6.
        let ntsc = try Self.media("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.006,\na.ts\n")
        #expect(ntsc.targetDuration == 6)
    }

    @Test("Sequence numbers past 2^53 are malformed, not an overflow")
    func hugeSequences() {
        #expect(throws: HLSPlaylistError.malformed(line: 2, tag: "EXT-X-MEDIA-SEQUENCE")) {
            try HLSPlaylist.parse(
                "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:9223372036854775807\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts",
                url: Self.base)
        }
        #expect(throws: HLSPlaylistError.malformed(line: 2, tag: "EXT-X-DISCONTINUITY-SEQUENCE")) {
            try HLSPlaylist.parse("#EXTM3U\n#EXT-X-DISCONTINUITY-SEQUENCE:9007199254740993\n", url: Self.base)
        }
    }

    @Test("Hints that don't read are skipped: EXT-X-START without an offset, a session key without a method")
    func malformedHints() throws {
        let master = try Self.master(
            """
            #EXTM3U
            #EXT-X-START:PRECISE=YES
            #EXT-X-SESSION-KEY:URI="k.key"
            #EXT-X-STREAM-INF:BANDWIDTH=1
            v.m3u8
            """)
        #expect(master.start == nil && master.sessionKeys.isEmpty && master.variants.count == 1)
    }

    @Test("EXT-X-BITRATE doesn't apply to byte-range segments")
    func bitrateSkipsByteRanges() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-BITRATE:5000
            #EXTINF:4,
            #EXT-X-BYTERANGE:100@0
            main.mp4
            #EXTINF:4,
            b.ts
            """)
        #expect(playlist.segments.map(\.bitrate) == [nil, 5000])
    }

    @Test("A byte range carried past Int64.max fails the read instead of the app")
    func byteRangeOverflow() {
        #expect(throws: HLSPlaylistError.malformed(line: 7, tag: "EXT-X-BYTERANGE")) {
            try HLSPlaylist.parse(
                "#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:9223372036854775806@1\na.ts\n#EXTINF:4,\n#EXT-X-BYTERANGE:10\na.ts",
                url: Self.base)
        }
    }

    @Test("Values written unquoted are read: renditions, keys, groups; CLOSED-CAPTIONS=\"NONE\" quoted is a group")
    func unquotedValues() throws {
        let master = try Self.master(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=aac,NAME=English,LANGUAGE=en,URI=audio/en.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=aac,CODECS=avc1.640028,CLOSED-CAPTIONS="NONE"
            v.m3u8
            """)
        #expect(master.renditions(.audio, group: "aac").first?.url?.lastPathComponent == "en.m3u8")
        #expect(master.variants.first?.audioGroup == "aac" && master.variants.first?.codecs == "avc1.640028")
        #expect(master.variants.first?.closedCaptionsGroup == "NONE")

        let media = try Self.media("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=key.bin\n#EXTINF:4,\na.ts\n")
        #expect(media.segments.first?.key?.isDecryptable == true)
    }

    @Test("A target duration is at least a second, also with no segments or only very short ones")
    func targetDurationAtLeastASecond() throws {
        #expect(try Self.media("#EXTM3U\n").targetDuration == 1)
        #expect(try Self.media("#EXTM3U\n#EXT-X-TARGETDURATION:0\n#EXTINF:0.3,\na.ts\n").targetDuration == 1)
    }

    @Test("An unknown duration (EXTINF:-1) is the target's")
    func unknownDurations() throws {
        let playlist = try Self.media("#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXTINF:-1,\na.ts\n#EXTINF:6,\nb.ts\n")
        #expect(playlist.segments.map(\.duration) == [8, 6])
        // Dates carried on follow the target's duration, not -1.
        let dated = try Self.media(
            "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-PROGRAM-DATE-TIME:2026-11-10T12:00:00Z\n#EXTINF:-1,\na.ts\n#EXTINF:-1,\nb.ts\n"
        )
        let noon = try #require(HLSPlaylist.date("2026-11-10T12:00:00Z"))
        #expect(dated.segments.map(\.programDateTime) == [noon, noon.addingTimeInterval(6)])
    }

    @Test("An init section is the same across reloads of a sliding playlist, its fallback IV aside")
    func initSectionIdentity() throws {
        let text = { (sequence: Int) in
            "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:\(sequence)\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\na.m4s\n"
        }
        let first = try #require(try Self.media(text(10)).segments.first?.initSection)
        let later = try #require(try Self.media(text(11)).segments.first?.initSection)
        #expect(first == later && first.hashValue == later.hashValue)
    }

    @Test("An encrypted init section without an IV takes the first segment's media sequence number")
    func initSectionIV() throws {
        let playlist = try Self.media(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:7
            #EXTINF:4,
            clear.ts
            #EXT-X-KEY:METHOD=AES-128,URI="k"
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:4,
            a.m4s
            #EXTINF:4,
            b.m4s
            #EXT-X-KEY:METHOD=AES-128,URI="k",IV=0x01
            #EXT-X-MAP:URI="init2.mp4"
            #EXTINF:4,
            c.m4s
            """)
        let sections = playlist.segments.map(\.initSection)
        #expect(sections[0] == nil)
        // Both segments under the first map share it, and its IV is that of 8, its first.
        #expect(
            sections[1] == sections[2] && sections[1]?.initializationVector == [UInt8](repeating: 0, count: 16))
        #expect(sections[3]?.initializationVector == [UInt8](repeating: 0, count: 15) + [1])
    }

    // MARK: Errors

    @Test("What can't be read fails: not a playlist, mixed types, malformed durations and ranges, unknown variables")
    func errors() {
        #expect(throws: HLSPlaylistError.notAPlaylist) { try HLSPlaylist.parse("#EXTINF:4,\na.ts", url: Self.base) }
        #expect(throws: HLSPlaylistError.notAPlaylist) { try HLSPlaylist.parse("", url: Self.base) }
        #expect(throws: HLSPlaylistError.notText) { try HLSPlaylist.parse(Data([0xff, 0xfe, 0xfd]), url: Self.base) }
        #expect(throws: HLSPlaylistError.mixedTypes) {
            try HLSPlaylist.parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n#EXTINF:4,\na.ts", url: Self.base)
        }
        #expect(throws: HLSPlaylistError.malformed(line: 2, tag: "EXT-X-TARGETDURATION")) {
            try HLSPlaylist.parse("#EXTM3U\n#EXT-X-TARGETDURATION:inf\n#EXTINF:4,\na.ts", url: Self.base)
        }
        #expect(throws: HLSPlaylistError.malformed(line: 2, tag: "EXTINF")) {
            try HLSPlaylist.parse("#EXTM3U\n#EXTINF:abc,\na.ts", url: Self.base)
        }
        #expect(throws: HLSPlaylistError.malformed(line: 3, tag: "EXT-X-BYTERANGE")) {
            try HLSPlaylist.parse("#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:x@1\na.ts", url: Self.base)
        }
        #expect(throws: HLSPlaylistError.undefinedVariable(line: 3, name: "nope")) {
            try HLSPlaylist.parse("#EXTM3U\n#EXTINF:4,\n{$nope}/a.ts", url: Self.base)
        }
        #expect(throws: HLSPlaylistError.undefinedVariable(line: 2, name: "host")) {
            try HLSPlaylist.parse("#EXTM3U\n#EXT-X-DEFINE:IMPORT=\"host\"", url: Self.base)
        }
        // A key of any method but NONE needs its URI.
        #expect(throws: HLSPlaylistError.malformed(line: 2, tag: "EXT-X-KEY")) {
            try HLSPlaylist.parse("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128\n#EXTINF:4,\na.ts", url: Self.base)
        }
    }
}
