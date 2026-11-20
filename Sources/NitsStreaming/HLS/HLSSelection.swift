import Foundation

/// Which ladder of an HLS multivariant playlist is played, told by the address that opens it: a host that knows the
/// ladders (a video site's resolver, which offers them to choose from) hands the playlist's address back with the choice in
/// its fragment (`https://…/master.m3u8#nits-ladder=vp9&nits-range=hdr`), which a server never sees. The client reads the
/// choice off the address (`split(_:)`), plays the variants that have that codec and range (`matches(_:)`), and loads the
/// playlist from the address without it. An address with no choice plays the best ladder (`LadderChoice`).
package struct HLSSelection: Equatable, Sendable {
    /// The video codec family of the ladder (`CodecFamily.video(in:)`: "avc", "hevc", "vp9", "av1").
    package var codec: String?
    /// Whether it is HDR (any `VIDEO-RANGE` but SDR: a host's extractor and a playlist name HDR differently, YouTube's
    /// "HDR10" being `HLG` in its playlist); a variant that tells no range is SDR.
    package var isHDR: Bool?

    private static let codecKey = "nits-ladder"
    private static let rangeKey = "nits-range"

    package var isEmpty: Bool { codec == nil && isHDR == nil }

    package init(codec: String? = nil, isHDR: Bool? = nil) {
        self.codec = codec
        self.isHDR = isHDR
    }

    /// The choice an address's fragment holds; empty for an address with none or a fragment that is not this one's.
    package init(fragment: String?) {
        for part in (fragment ?? "").split(separator: "&") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let value = String(part[part.index(after: equals)...]).removingPercentEncoding
            switch part[..<equals] {
            case Self.codecKey: codec = value
            case Self.rangeKey: isHDR = ["sdr": false, "hdr": true][value?.lowercased() ?? ""]
            default: break
            }
        }
    }

    /// `address` without its fragment, and the choice the fragment held. An address that is no URL (a path) is returned
    /// as it is, with no choice.
    package static func split(_ address: String) -> (address: String, selection: HLSSelection) {
        guard StreamingURL.isNetworkURL(address), let hash = address.firstIndex(of: "#") else {
            return (address, HLSSelection())
        }
        let selection = HLSSelection(fragment: String(address[address.index(after: hash)...]))
        // A fragment that is not this one's (an anchor) is the address's own: left in.
        return selection.isEmpty ? (address, selection) : (String(address[..<hash]), selection)
    }

    /// `master` with the choice in its fragment (without it when empty).
    package func address(of master: URL) -> String {
        guard var components = URLComponents(url: master, resolvingAgainstBaseURL: false) else {
            return master.absoluteString
        }
        components.fragment = nil
        var parts: [String] = []
        if let codec { parts.append("\(Self.codecKey)=\(codec)") }
        if let isHDR { parts.append("\(Self.rangeKey)=\(isHDR ? "hdr" : "sdr")") }
        if !parts.isEmpty { components.percentEncodedFragment = parts.joined(separator: "&") }
        return components.string ?? master.absoluteString
    }

    /// Whether `variant` is a rung of the chosen ladder: its codec family and whether it is HDR, whichever the choice
    /// names. Dolby Vision over HEVC is told by `SUPPLEMENTAL-CODECS` (`CODECS` says `hvc1`): only a choice of Dolby
    /// Vision takes it, and a choice of HEVC does not, its HDR10 ladder being another.
    func matches(_ variant: PlaylistVariant) -> Bool {
        if let codec {
            let main = variant.codecs.flatMap(CodecFamily.video)
            let supplemental = variant.supplementalCodecs.flatMap(CodecFamily.video)
            if CodecFamily.isDolbyVision(codec) {
                if main != codec && supplemental != codec { return false }
            } else if main != codec || supplemental.map(CodecFamily.isDolbyVision) == true {
                return false
            }
        }
        if let isHDR, (variant.videoRange.map { $0 != .sdr } ?? false) != isHDR { return false }
        return true
    }
}
