import Foundation

/// The transfer of a picture as yt-dlp's `dynamic_range` tells it, read in one place for everything that groups or marks
/// formats (`YouTubeFormatGrouping`, `YTDLPInfo`): `"SDR"` (or none), `"HDR10"`, `"HDR10+"`, `"HDR12"`, `"HLG"`, `"DV"`
/// (`InfoExtractor`'s docstring in yt-dlp). A word it does not know reads as PQ, an HDR ladder labelled SDR being the worse
/// mistake (`unknownValues(in:)` lists them, for the resolver to report once); an empty one is none: SDR.
///
/// `DV` reads as PQ by convention (Dolby Vision profile 8.4's base layer is HLG): harmless, as Dolby Vision is a codec
/// family of its own and its ladder never joins another's.
enum YTDLPDynamicRange: Hashable, Sendable {
    case sdr, pq, hlg

    private static let known: [String: Self] = [
        "SDR": .sdr, "HDR10": .pq, "HDR10+": .pq, "HDR12": .pq, "DV": .pq, "HLG": .hlg,
    ]

    init(_ value: String?) {
        guard let value, !value.isEmpty else {
            self = .sdr
            return
        }
        self = Self.known[value.uppercased()] ?? .pq
    }

    var isHDR: Bool { self != .sdr }

    /// The transfer of H.273 an HDR picture is marked with (`DASHElements.hdrTransfer`): 16 PQ, 18 HLG; nil for SDR.
    var transfer: Int? {
        switch self {
        case .sdr: nil
        case .pq: 16
        case .hlg: 18
        }
    }

    /// The values the pictures of `formats` carry that are none of yt-dlp's (a page has dozens of formats: the caller reports them once).
    static func unknownValues(in formats: [YTDLPInfo.Format]) -> Set<String> {
        Set(
            formats.filter(YouTubeFormatGrouping.hasPicture).compactMap(\.dynamicRange).filter {
                !$0.isEmpty && known[$0.uppercased()] == nil
            })
    }
}
