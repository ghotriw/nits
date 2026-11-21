import Foundation
import Testing

@testable import NitsCore
@testable import NitsYTDLP

/// How the page's formats are read into ladders: yt-dlp's `dynamic_range`, the sets of pictures, the codec's name.
@Suite("yt-dlp ladder rules")
struct YTDLPLadderRulesTests {
    private static func picture(
        _ codec: String, _ height: Int, fps: Int = 30, range: String? = nil, ext: String = "mp4"
    ) throws -> YTDLPInfo.Format {
        var json =
            #"{"format_id": "\#(codec)\#(height)\#(fps)\#(range ?? "")", "ext": "\#(ext)", "vcodec": "\#(codec)", "height": \#(height), "fps": \#(fps)"#
        if let range { json += #", "dynamic_range": "\#(range)""# }
        return try JSONDecoder().decode(YTDLPInfo.Format.self, from: Data((json + "}").utf8))
    }

    @Test("dynamic_range: the six values, none, and a word it does not know (PQ, listed; empty is none)")
    func readsDynamicRange() throws {
        #expect(YTDLPDynamicRange(nil) == .sdr)
        #expect(
            ["SDR", "HDR10", "HDR10+", "HDR12", "HLG", "DV"].map { YTDLPDynamicRange($0) } == [
                .sdr, .pq, .pq, .pq, .hlg, .pq,
            ])
        #expect(YTDLPDynamicRange("HDR12").transfer == 16)
        #expect(YTDLPDynamicRange("HLG").transfer == 18)
        #expect(YTDLPDynamicRange("SDR").transfer == nil)
        #expect(YTDLPDynamicRange("Bogus") == .pq)
        #expect(YTDLPDynamicRange("") == .sdr)
        let formats = try [
            Self.picture("vp9", 720, range: "HDR10"), Self.picture("vp9", 720, range: "Bogus"),
            Self.picture("vp9", 720, range: ""),
        ]
        #expect(YTDLPDynamicRange.unknownValues(in: formats) == ["Bogus"])
    }

    @Test("HDR10 and HDR10+ of one codec and container are one set; avc1 and avc3 too")
    func joinsRanges() throws {
        let hdr = try [
            Self.picture("vp9.2", 1080, range: "HDR10"), Self.picture("vp9.2", 1080, range: "HDR10+"),
            Self.picture("vp9.2", 1080, range: "HDR12"), Self.picture("vp9.2", 1080, range: "HLG"),
        ]
        #expect(YouTubeFormatGrouping.pictureSets(of: hdr).map(\.count) == [3, 1])
        let avc = try [Self.picture("avc1.640028", 1080), Self.picture("avc3.640028", 720)]
        #expect(YouTubeFormatGrouping.pictureSets(of: avc).map(\.count) == [2])
    }

    @Test("The 60 fps rule runs over a joined set")
    func sixtyFpsOverJoinedSet() throws {
        let formats = try [
            Self.picture("vp9.2", 1080, fps: 30, range: "HDR10"), Self.picture("vp9.2", 1080, fps: 60, range: "HDR10+"),
        ]
        let sets = YouTubeFormatGrouping.pictureSets(of: formats)
        #expect(sets.count == 1)
        #expect(sets[0].map(\.fps) == [60])
    }

    @Test("A codec as shown: four-character codes, other extractors' names, Dolby Vision, an unknown one")
    func namesCodecs() {
        let names = [
            "avc1.640028", "h264", "h265", "hevc", "av1", "vp09.00.40.08", "av01.0.13M.08", "dvh1.08.06", "xyz.1",
        ].map { YTDLPInfo.pictureCodec(of: $0) }
        #expect(names == ["H.264", "H.264", "HEVC", "HEVC", "AV1", "VP9", "AV1", "Dolby Vision", "XYZ"])
        #expect(YTDLPInfo.pictureCodec(of: nil) == "")
    }
}
