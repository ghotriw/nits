import Foundation
import Testing

@testable import NitsStreaming

/// Which ladder of a multivariant playlist plays: the best by bandwidth, by a host's order of codecs, or the one a host
/// chose in the address's fragment.
@Suite("HLS ladder choice")
struct HLSLadderTests {
    private static func ladder(
        _ lines: String, rank: (@Sendable (String) -> Int)? = nil, selection: HLSSelection = HLSSelection(),
        warnings: Warnings? = nil
    ) throws -> [Int] {
        guard
            case .multivariant(let multivariant) = try StreamingPlaylist.parse(
                Data(("#EXTM3U\n" + lines).utf8), url: URL(string: "http://h/m.m3u8")!)
        else { return [] }
        return StreamingInput.ladder(of: multivariant, codecRank: rank, selection: selection) { warnings?.add($0) }
            .map(\.bandwidth).sorted()
    }

    private final class Warnings: @unchecked Sendable {
        private(set) var messages: [String] = []
        func add(_ message: String) { messages.append(message) }
    }

    private static func variant(
        _ bandwidth: Int, _ codec: String, _ height: Int, width: Int? = nil, range: String? = "SDR"
    ) -> String {
        let rangeField = range.map { ",VIDEO-RANGE=\($0)" } ?? ""
        return
            "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"\(codec)\",RESOLUTION=\(width ?? height * 16 / 9)x\(height)\(rangeField)\nv\(bandwidth).m3u8\n"
    }

    /// H.264 first, then VP9, as the app's default order has them; HEVC and AV1 follow.
    private static let avcFirst: @Sendable (String) -> Int = { ["avc", "vp9"].firstIndex(of: $0) ?? 10 }
    private static let vp9First: @Sendable (String) -> Int = { ["vp9", "avc"].firstIndex(of: $0) ?? 10 }

    private static let sdr =
        variant(500, "avc1.4d401f", 720) + variant(5000, "avc1.640028", 1080) + variant(300, "vp09.00.40.08", 720)
        + variant(1500, "vp09.00.40.08", 1080)

    @Test("By bandwidth alone the bigger codec wins, which says nothing of the picture; an order of codecs decides it")
    func followsCodecOrder() throws {
        #expect(try Self.ladder(Self.sdr) == [500, 5000])
        #expect(try Self.ladder(Self.sdr, rank: Self.vp9First) == [300, 1500])
        #expect(try Self.ladder(Self.sdr, rank: Self.avcFirst) == [500, 5000])
        // A codec the order puts last plays when it is all there is.
        let onlyAVC = Self.variant(500, "avc1.4d401f", 720) + Self.variant(5000, "avc1.640028", 1080)
        #expect(try Self.ladder(onlyAVC, rank: { $0 == "avc" ? 100 : 0 }) == [500, 5000])
    }

    @Test("The size comes first (height, then width), then HDR, then the codec")
    func sizeThenRangeThenCodec() throws {
        let sizes = Self.variant(900, "avc1.640028", 1080) + Self.variant(6000, "vp09.00.40.08", 2160)
        #expect(try Self.ladder(sizes, rank: Self.avcFirst) == [6000])
        let hdr = Self.variant(2000, "avc1.640028", 1080) + Self.variant(2500, "vp09.02.40.10", 1080, range: "PQ")
        #expect(try Self.ladder(hdr, rank: Self.avcFirst) == [2500])
        // Equal heights: the wider picture, whatever the codec.
        let widths =
            Self.variant(900, "avc1.640028", 800, width: 1920) + Self.variant(800, "vp09.00.40.08", 800, width: 2560)
        #expect(try Self.ladder(widths, rank: Self.avcFirst) == [800])
    }

    @Test("A ladder a host chose plays, whatever the order or the bandwidth say; one the playlist lacks is warned of")
    func playsTheChosenLadder() throws {
        #expect(try Self.ladder(Self.sdr, selection: .init(codec: "vp9", isHDR: false)) == [300, 1500])
        #expect(try Self.ladder(Self.sdr, rank: Self.avcFirst, selection: .init(codec: "vp9")) == [300, 1500])
        // HDR or not tells ladders of one codec apart, whichever HDR (a host says "HDR10" of what the playlist calls
        // `HLG`, as YouTube's does); a rung that tells no range is SDR, with the ones that tell it.
        let ranges =
            Self.variant(3000, "vp09.00.40.08", 2160, range: nil)
            + Self.variant(1000, "vp09.00.40.08", 1080, range: nil)
            + Self.variant(1500, "vp09.00.40.08", 720, range: "SDR")
            + Self.variant(4000, "vp09.02.40.10", 2160, range: "HLG")
        #expect(try Self.ladder(ranges, selection: .init(codec: "vp9", isHDR: false)) == [1000, 1500, 3000])
        #expect(try Self.ladder(ranges, selection: .init(codec: "vp9", isHDR: true)) == [4000])
        // Dolby Vision over HEVC is told by `SUPPLEMENTAL-CODECS`.
        let dolby =
            Self.variant(2000, "hvc1.2.4.L120.B0", 2160, range: "SDR")
            + "#EXT-X-STREAM-INF:BANDWIDTH=3000,CODECS=\"hvc1.2.4.L153.B0\",SUPPLEMENTAL-CODECS=\"dvh1.08.07/db4h\",RESOLUTION=3840x2160,VIDEO-RANGE=PQ\nv3000.m3u8\n"
        #expect(try Self.ladder(dolby, selection: .init(codec: "dvhevc", isHDR: true)) == [3000])
        // A choice of HEVC HDR is the HDR10 ladder, not the Dolby Vision one made on it, whatever it weighs.
        let both =
            Self.variant(2500, "hvc1.2.4.L153.B0", 2160, range: "PQ")
            + "#EXT-X-STREAM-INF:BANDWIDTH=3000,CODECS=\"hvc1.2.4.L153.B0\",SUPPLEMENTAL-CODECS=\"dvh1.08.07/db4h\",RESOLUTION=3840x2160,VIDEO-RANGE=PQ\nv3000.m3u8\n"
        #expect(try Self.ladder(both, selection: .init(codec: "hevc", isHDR: true)) == [2500])
        #expect(try Self.ladder(both, selection: .init(codec: "dvhevc", isHDR: true)) == [3000])
        let warnings = Warnings()
        #expect(
            try Self.ladder(Self.sdr, rank: Self.avcFirst, selection: .init(codec: "av1"), warnings: warnings)
                == [500, 5000])
        #expect(warnings.messages.count == 1)
        // A variant that tells no codec: the ladders can't be told apart, and the choice is warned of.
        let untold = Warnings()
        let noCodec = Self.sdr + "#EXT-X-STREAM-INF:BANDWIDTH=9000,RESOLUTION=1920x1080\nv9000.m3u8\n"
        #expect(try Self.ladder(noCodec, selection: .init(codec: "vp9"), warnings: untold).count == 5)
        #expect(untold.messages.count == 1)
    }

    @Test("The choice is in the address's fragment, which the playlist's address is without")
    func readsTheFragment() {
        let master = URL(string: "https://media.example/master.m3u8?sig=a%26b")!
        let chosen = HLSSelection(codec: "vp9", isHDR: true)
        let address = chosen.address(of: master)
        #expect(address == "https://media.example/master.m3u8?sig=a%26b#nits-ladder=vp9&nits-range=hdr")
        let split = HLSSelection.split(address)
        #expect(split.address == master.absoluteString && split.selection == chosen)
        #expect(HLSSelection(codec: "avc").address(of: master).hasSuffix("#nits-ladder=avc"))
        #expect(HLSSelection().address(of: master) == master.absoluteString)
        // Not the choice's fragment (an anchor), a local path, or a path with a `#`: left as they are.
        #expect(HLSSelection.split("https://media.example/a.m3u8#top").address == "https://media.example/a.m3u8#top")
        #expect(HLSSelection.split("/tmp/a#b.m3u8").address == "/tmp/a#b.m3u8")
        #expect(HLSSelection.split("https://media.example/a.m3u8#nits-range=pq").selection.isEmpty, "Not SDR or HDR")
    }
}
