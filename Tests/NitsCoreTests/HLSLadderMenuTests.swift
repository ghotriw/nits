import Foundation
import Testing

@testable import NitsCore

/// The ladders of an HLS playlist that a host lists, offered to choose from, the preferred codec's playing.
@Suite("HLS ladder menu")
struct HLSLadderMenuTests {
    private static let master = "https://media.example/master.m3u8?sig=abc"

    private static func rung(
        _ codec: String, _ height: Int, isHDR: Bool = false, bandwidth: Int = 1_000_000
    ) -> HLSLadderMenu.Rung {
        .init(
            codec: codec, isHDR: isHDR, width: height * 16 / 9, height: height, frameRate: 24,
            bandwidth: bandwidth)
    }

    /// What YouTube lists: H.264 and VP9 at several sizes, an HDR10 VP9, a 144p VP9 twice.
    private static let rungs = [
        rung("avc1.4d401f", 360, bandwidth: 800_000), rung("avc1.640028", 1080, bandwidth: 5_000_000),
        rung("vp09.00.40.08", 360, bandwidth: 600_000), rung("vp09.00.40.08", 1080, bandwidth: 3_400_000),
        rung("vp09.00.10.08", 144, bandwidth: 84_000), rung("vp09.00.10.08", 144, bandwidth: 136_000),
        rung("vp09.02.40.10", 1080, isHDR: true, bandwidth: 4_000_000),
        rung("vp09.02.40.10", 360, isHDR: true, bandwidth: 650_000),
    ]

    @Test("One choice for each codec and range, its top rung shown, HDR named, the best first")
    func offersOneChoiceForEachLadder() {
        let formats = HLSLadderMenu.formats(master: Self.master, rungs: Self.rungs)
        #expect(formats.map(\.id) == ["vp9-hdr", "avc-sdr", "vp9-sdr"], "HDR first, then the default order's codecs")
        #expect(formats.map(\.codec) == ["VP9 HDR", "H.264", "VP9"])
        #expect(formats.map(\.height) == [1080, 1080, 1080])
        #expect(formats.map(\.bitrate) == [4_000_000, 5_000_000, 3_400_000])
        #expect(formats[1].url == Self.master + "#nits-ladder=avc&nits-range=sdr")
        #expect(formats[0].url.hasSuffix("#nits-ladder=vp9&nits-range=hdr"))
        // One ladder is no choice; a codec no family names is left out; Dolby Vision keeps its name, HLG is HDR.
        #expect(HLSLadderMenu.formats(master: Self.master, rungs: Array(Self.rungs[..<2])).isEmpty)
        #expect(
            HLSLadderMenu.formats(master: Self.master, rungs: [Self.rung("xyz", 720), Self.rung("avc1", 720)]).isEmpty)
        let hlg = HLSLadderMenu.formats(
            master: Self.master, rungs: [Self.rung("avc1.640028", 1080), Self.rung("hvc1.2.4", 1080, isHDR: true)])
        #expect(hlg.map(\.id) == ["hevc-hdr", "avc-sdr"])
        // As yt-dlp lists YouTube's HLG ladder: its "HDR10", a codec string with the transfer in it.
        let real = HLSLadderMenu.formats(
            master: Self.master,
            rungs: [
                Self.rung("vp09.00.50.08", 2160), Self.rung("vp09.02.51.10.01.09.18.09.00", 2160, isHDR: true),
            ])
        #expect(real.map(\.id) == ["vp9-hdr", "vp9-sdr"] && real.map(\.codec) == ["VP9 HDR", "VP9"])
        let dolby = HLSLadderMenu.formats(
            master: Self.master, rungs: [Self.rung("avc1.640028", 1080), Self.rung("dvh1.08.07", 1080, isHDR: true)])
        #expect(dolby.map(\.codec) == ["Dolby Vision", "H.264"], "No \"HDR\" after its name")
    }

    private static func media(_ rungs: [HLSLadderMenu.Rung] = Self.rungs) -> ResolvedMedia {
        var media = ResolvedMedia(path: master)
        media.videoFormats = HLSLadderMenu.formats(master: master, rungs: rungs)
        return media
    }

    @Test("The codec the user prefers plays, the choices best first by the rule the client chooses by")
    func playsThePreferredCodec() throws {
        // Size, then HDR: the HDR ladder is the same size as the others', so it wins whatever the order.
        let byDefault = HLSLadderMenu.offering(Self.media(), codecs: VideoCodecPreference())
        #expect(byDefault.selectedVideoFormatID == "vp9-hdr")
        #expect(byDefault.path == byDefault.videoFormats[0].url)

        // Without HDR, the codec decides among ladders of one size.
        let sdr = Self.rungs.filter { !$0.isHDR }
        let avc = HLSLadderMenu.offering(Self.media(sdr), codecs: VideoCodecPreference(order: ["avc", "vp9"]))
        #expect(avc.selectedVideoFormatID == "avc-sdr")
        #expect(avc.path == Self.master + "#nits-ladder=avc&nits-range=sdr")
        let vp9 = HLSLadderMenu.offering(Self.media(sdr), codecs: VideoCodecPreference(order: ["vp9", "avc"]))
        #expect(vp9.selectedVideoFormatID == "vp9-sdr")
        #expect(vp9.videoFormats.map(\.id) == ["vp9-sdr", "avc-sdr"])
        var off = VideoCodecPreference(order: ["vp9", "avc"])
        off.setEnabled(false, family: "vp9")
        #expect(HLSLadderMenu.offering(Self.media(sdr), codecs: off).selectedVideoFormatID == "avc-sdr")
        // The order as the client takes it, for a playlist that is no host's: a codec switched off after those on.
        #expect(
            VideoCodecPreference(order: ["vp9", "avc"]).ladderRank("vp9") < VideoCodecPreference().ladderRank("avc"))
        #expect(off.ladderRank("vp9") > off.ladderRank("avc") && off.ladderRank("vp9") > off.ladderRank("hevc"))

        // Switching to another choice is the same as for a manifest's pictures.
        let switched = try #require(vp9.selecting(videoFormat: "avc-sdr"))
        #expect(
            switched.path == Self.master + "#nits-ladder=avc&nits-range=sdr"
                && switched.selectedVideoFormatID == "avc-sdr")
    }

    @Test("Media that offers no ladders, or has one chosen, or other pictures, is returned as it is")
    func leavesOtherMediaAlone() {
        let plain = ResolvedMedia(path: Self.master)
        #expect(HLSLadderMenu.offering(plain, codecs: VideoCodecPreference()) == plain)
        var chosen = Self.media()
        chosen.selectedVideoFormatID = "avc-sdr"
        #expect(HLSLadderMenu.offering(chosen, codecs: VideoCodecPreference()) == chosen)
        var files = ResolvedMedia(path: "https://media.example/a")
        files.videoFormats = [
            .init(id: "1", url: "https://media.example/1", width: 1920, height: 1080),
            .init(id: "2", url: "https://media.example/2", width: 1280, height: 720),
        ]
        #expect(HLSLadderMenu.offering(files, codecs: VideoCodecPreference()) == files)
    }
}
