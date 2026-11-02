import Foundation
import Testing

@testable import NitsCore

/// The order of video codecs (`VideoCodecPreference`) and what it chooses in a DASH manifest.
@Suite("Video codec preference")
struct VideoCodecPreferenceTests {
    /// H.264 and VP9 at every size, VP9 at half the bitrate: the manifest of Shaka's demo, in short.
    private static func manifest(codecs: VideoCodecPreference) -> DASHManifest? {
        DASHManifest(
            data: DASHManifestTests.mpd(
                period: """
                    <AdaptationSet contentType="video"><SegmentTemplate media="s/$Number$" timescale="1" duration="1"/>
                    \(DASHManifestTests.video("h-low", 640, 266, codecs: "avc1.4d401f", bandwidth: 800_000))
                    \(DASHManifestTests.video("h-high", 1920, 800, codecs: "avc1.640028", bandwidth: 4_500_000))
                    </AdaptationSet>
                    <AdaptationSet contentType="video"><SegmentTemplate media="s/$Number$" timescale="1" duration="1"/>
                    \(DASHManifestTests.video("v-low", 640, 266, codecs: "vp9", bandwidth: 400_000))
                    \(DASHManifestTests.video("v-high", 1920, 800, codecs: "vp9", bandwidth: 2_100_000))
                    </AdaptationSet>
                    """),
            url: DASHManifestTests.url, codecs: codecs)
    }

    @Test("The default order puts HEVC and H.264 before AV1 and VP9")
    func defaultOrder() {
        #expect(VideoCodecPreference().order == ["hevc", "avc", "av1", "vp9", "vp8"])
        #expect(VideoCodecPreference().rank(ofFamily: "avc") < VideoCodecPreference().rank(ofFamily: "vp9"))
    }

    @Test("Stored, an order keeps its codecs off; unknown and repeated entries go, the missing ones come last")
    func storedForm() {
        let preference = VideoCodecPreference(stored: "vp9, -avc,bogus,vp9,hevc")
        #expect(preference.order == ["vp9", "avc", "hevc", "av1", "vp8"])
        #expect(preference.disabled == ["avc"])
        #expect(VideoCodecPreference(stored: preference.stored) == preference)
        #expect(VideoCodecPreference(stored: "") == VideoCodecPreference())
    }

    @Test("Dolby Vision ranks with the codec it is made on; a codec off ranks after every one on; unknown, last")
    func ranks() {
        let preference = VideoCodecPreference(order: ["av1", "hevc", "avc"], disabled: ["av1"])
        #expect(preference.rank(ofFamily: "dvhevc") == preference.rank(ofFamily: "hevc"))
        #expect(preference.rank(ofFamily: "hevc") < preference.rank(ofFamily: "avc"))
        #expect(preference.rank(ofFamily: "avc") < preference.rank(ofFamily: "av1"))
        #expect(preference.rank(ofFamily: "av1") < preference.rank(ofFamily: ""))
    }

    @Test("Moving a codec in the list, as the list view does")
    func moves() {
        var preference = VideoCodecPreference()
        preference.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(preference.order == ["vp9", "hevc", "avc", "av1", "vp8"])
        preference.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(preference.order == ["hevc", "avc", "vp9", "av1", "vp8"])
        preference.move(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        #expect(preference.order == ["hevc", "avc", "vp9", "av1", "vp8"])
    }

    @Test("At one size the preferred codec is the best picture, not the one with more bits")
    func codecDecidesAtOneSize() throws {
        let h264First = try #require(Self.manifest(codecs: VideoCodecPreference()))
        #expect(h264First.videos.first?.id == "h-high")
        #expect(h264First.ladder.map(\.id) == ["h-high", "h-low"])

        let vp9First = try #require(Self.manifest(codecs: VideoCodecPreference(order: ["vp9", "avc"])))
        #expect(vp9First.videos.first?.id == "v-high")
        #expect(vp9First.ladder.map(\.id) == ["v-high", "v-low"])
        // The bitrate still orders the pictures of one codec.
        #expect(vp9First.videos.map(\.id) == ["v-high", "h-high", "v-low", "h-low"])
    }

    @Test("A codec switched off is played only when the manifest has no other")
    func disabledIsLastResort() throws {
        let off = VideoCodecPreference(order: ["avc", "vp9"], disabled: ["avc"])
        #expect(try #require(Self.manifest(codecs: off)).videos.first?.id == "v-high")
        let only = try #require(
            DASHManifest(
                data: DASHManifestTests.mpd(
                    period: """
                        <AdaptationSet contentType="video"><SegmentTemplate media="s/$Number$" timescale="1" duration="1"/>
                        \(DASHManifestTests.video("h", 1280, 720, bandwidth: 2_000_000))
                        </AdaptationSet>
                        """), url: DASHManifestTests.url, codecs: off))
        #expect(only.videos.map(\.id) == ["h"])
    }

    @Test("A size comes before the codec: the larger picture wins whatever the order")
    func sizeBeforeCodec() throws {
        let manifest = try #require(
            DASHManifest(
                data: DASHManifestTests.mpd(
                    period: """
                        <AdaptationSet contentType="video"><SegmentTemplate media="s/$Number$" timescale="1" duration="1"/>
                        \(DASHManifestTests.video("h", 1920, 1080, bandwidth: 4_000_000))
                        \(DASHManifestTests.video("v", 1280, 720, codecs: "vp9", bandwidth: 2_000_000))
                        </AdaptationSet>
                        """), url: DASHManifestTests.url, codecs: VideoCodecPreference(order: ["vp9", "avc"])))
        #expect(manifest.videos.first?.id == "h")
    }

    @Test("The best picture of each codec is listed, and each plays with the ladder of its own")
    func codecGroups() throws {
        let manifest = try #require(Self.manifest(codecs: VideoCodecPreference()))
        #expect(manifest.codecGroups.map(\.id) == ["h-high", "v-high"])
        let vp9 = try #require(manifest.codecGroups.last)
        let text = try #require(manifest.ladderText(of: vp9))
        #expect(text.contains(#"id="v-high""#) && text.contains(#"id="v-low""#))
        #expect(!text.contains(#"id="h-high""#))
    }
}

extension VideoCodecPreferenceTests {
    @Test("Shifting one place, and moving with entries or a destination outside the list, stay inside it")
    func shiftsAndClamps() {
        var preference = VideoCodecPreference()
        preference.shift("avc", by: -1)
        #expect(preference.order == ["avc", "hevc", "av1", "vp9", "vp8"])
        preference.shift("avc", by: -1)
        #expect(preference.order == ["avc", "hevc", "av1", "vp9", "vp8"])
        preference.shift("vp8", by: 1)
        #expect(preference.order == ["avc", "hevc", "av1", "vp9", "vp8"])
        preference.shift("hevc", by: 1)
        #expect(preference.order == ["avc", "av1", "hevc", "vp9", "vp8"])
        preference.move(fromOffsets: IndexSet([1, 99]), toOffset: 99)
        #expect(preference.order == ["avc", "hevc", "vp9", "vp8", "av1"])
        preference.move(fromOffsets: IndexSet(integer: 4), toOffset: -5)
        #expect(preference.order == ["av1", "avc", "hevc", "vp9", "vp8"])
    }

    @Test("A Dolby Vision picture is not a ladder with another Dolby Vision codec's, whatever the name shown")
    func dolbyVisionFamiliesStayApart() throws {
        let manifest = try #require(
            DASHManifest(
                data: DASHManifestTests.mpd(
                    period: """
                        <AdaptationSet contentType="video"><SegmentTemplate media="s/$Number$" timescale="1" duration="1"/>
                        \(DASHManifestTests.video("dv-hevc", 1920, 1080, codecs: "dvh1.05.06", bandwidth: 5_000_000))
                        \(DASHManifestTests.video("dv-hevc-low", 1280, 720, codecs: "dvh1.05.06", bandwidth: 2_000_000))
                        \(DASHManifestTests.video("dv-av1", 1920, 1080, codecs: "dav1.10.06", bandwidth: 3_000_000))
                        </AdaptationSet>
                        """), url: DASHManifestTests.url))
        #expect(manifest.ladder.map(\.id) == ["dv-hevc", "dv-hevc-low"])
        #expect(manifest.codecGroups.map(\.id) == ["dv-hevc", "dv-av1"])
    }

    @Test("When the best codec has no ladder, another codec's is offered with its ladder")
    func otherCodecKeepsItsLadder() throws {
        let manifest = try #require(
            DASHManifest(
                data: DASHManifestTests.mpd(
                    period: """
                        <AdaptationSet contentType="video"><SegmentTemplate media="s/$Number$" timescale="1" duration="1"/>
                        \(DASHManifestTests.video("top", 3840, 2160, codecs: "av01.0.12M.10", bandwidth: 12_000_000))
                        \(DASHManifestTests.video("h-high", 1920, 1080, bandwidth: 4_000_000))
                        \(DASHManifestTests.video("h-low", 1280, 720, bandwidth: 2_000_000))
                        </AdaptationSet>
                        """), url: DASHManifestTests.url))
        #expect(manifest.ladder.isEmpty)
        let h264 = try #require(manifest.codecGroups.last)
        #expect(manifest.ladder(of: h264).map(\.id) == ["h-high", "h-low"])
    }
}

extension VideoCodecPreferenceTests {
    @Test(
        "Pictures that are single files are no ladder: FFmpeg reads a file from its start to seek in it or switch to it"
    )
    func singleFilesAreNoLadder() throws {
        let manifest = try #require(
            DASHManifest(
                data: DASHManifestTests.mpd(
                    period: """
                        <AdaptationSet contentType="video">
                        \(DASHManifestTests.video("hi", 1920, 1080, bandwidth: 4_000_000, inside: #"<BaseURL>hi.mp4</BaseURL><SegmentBase indexRange="800-1500"><Initialization range="0-799"/></SegmentBase>"#))
                        \(DASHManifestTests.video("lo", 1280, 720, bandwidth: 2_000_000, inside: #"<BaseURL>lo.mp4</BaseURL><SegmentBase indexRange="800-1500"><Initialization range="0-799"/></SegmentBase>"#))
                        </AdaptationSet>
                        """), url: DASHManifestTests.url))
        #expect(manifest.videos.map(\.isSegmented) == [false, false])
        #expect(manifest.ladder.isEmpty && manifest.ladderText() == nil)
        // Each is still a picture to play.
        #expect(manifest.text(videoID: "hi") != nil)
    }
}
