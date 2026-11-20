import Foundation
internal import NitsStreaming

/// The ladders of an HLS multivariant playlist a host knows of (a video site's resolver, from the formats its extractor
/// lists), offered to choose from as a manifest's pictures are (`ResolvedMedia.videoFormats`): one for each codec and range,
/// each choice the playlist's address with the ladder in its fragment (`HLSSelection`), which the client reads when it
/// opens it. The codec `VideoCodecPreference` prefers is first and plays (`offering`), by the rule the client chooses
/// the best ladder by (`LadderChoice`).
package enum HLSLadderMenu {
    /// A picture of the playlist, as the host's extractor lists it.
    package struct Rung: Sendable, Equatable {
        /// The codec as the extractor writes it ("vp09.00.40.08", "avc1.640028").
        package var codec: String
        /// The dynamic range as the extractor writes it ("SDR", "HDR10", "HLG", "DV"); none is SDR.
        package var dynamicRange: String?
        package var width: Int
        package var height: Int
        package var frameRate: Double?
        package var bandwidth: Int

        package init(
            codec: String, dynamicRange: String?, width: Int, height: Int, frameRate: Double?, bandwidth: Int
        ) {
            self.codec = codec
            self.dynamicRange = dynamicRange
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.bandwidth = bandwidth
        }
    }

    /// The ladder `rung` is a rung of: its codec family and whether it is HDR (not which: the extractor's "HDR10" is
    /// a playlist's `HLG`), nil for a codec no family names.
    private static func selection(of rung: Rung) -> HLSSelection? {
        guard let family = CodecFamily.video(in: rung.codec) else { return nil }
        let range = rung.dynamicRange?.uppercased()
        return HLSSelection(codec: family, isHDR: range != nil && range != "SDR")
    }

    /// One choice for each ladder `rungs` make, its top rung shown (the biggest picture, then the higher bandwidth), the
    /// best first by the default order of codecs (`offering` puts the user's first). Only one ladder is no choice: empty.
    /// `master` is the playlist's address. A host that offers these without the engine's chain has none marked as playing,
    /// and its path is the bare playlist's.
    package static func formats(master: String, rungs: [Rung]) -> [VideoFormat] {
        guard let master = URL(string: master) else { return [] }
        var tops: [String: (selection: HLSSelection, rung: Rung)] = [:]
        for rung in rungs {
            guard let selection = selection(of: rung), let codec = selection.codec, let isHDR = selection.isHDR else {
                continue
            }
            let id = "\(codec)-\(isHDR ? "hdr" : "sdr")"
            if let top = tops[id]?.rung,
                (top.height, top.width, top.bandwidth) >= (rung.height, rung.width, rung.bandwidth)
            {
                continue
            }
            tops[id] = (selection, rung)
        }
        guard tops.count > 1 else { return [] }
        let formats = tops.map { id, top in
            let family = top.selection.codec ?? ""
            let isHDR = top.selection.isHDR ?? false
            let name = CodecFamily.displayName(ofVideo: family)
            return VideoFormat(
                id: id, url: top.selection.address(of: master), width: top.rung.width, height: top.rung.height,
                frameRate: top.rung.frameRate, codec: isHDR && name != "Dolby Vision" ? "\(name) HDR" : name,
                bitrate: top.rung.bandwidth)
        }
        return formats.sorted { Self.isPreferred($0, over: $1, codecs: VideoCodecPreference()) }
    }

    /// Whether `a` is the better ladder of the two by the client's rule, the codec `codecs` prefers deciding among the
    /// rest.
    private static func isPreferred(_ a: VideoFormat, over b: VideoFormat, codecs: VideoCodecPreference) -> Bool {
        func key(_ format: VideoFormat) -> (Int, Int, Int, Int, Int) {
            let selection = HLSSelection.split(format.url).selection
            return LadderChoice.key(
                height: format.height, width: format.width, isHDR: selection.isHDR ?? false,
                family: selection.codec ?? "", bandwidth: format.bitrate, codecRank: { codecs.rank(ofFamily: $0) })
        }
        let (keyA, keyB) = (key(a), key(b))
        return keyA != keyB ? keyA > keyB : a.id < b.id
    }

    /// `media` with the codec `codecs` prefers playing, and the choices best first, when it offers ladders of an HLS
    /// playlist (`formats(master:rungs:)`) and none is chosen yet; any other media as it is.
    package static func offering(_ media: ResolvedMedia, codecs: VideoCodecPreference) -> ResolvedMedia {
        guard media.selectedVideoFormatID == nil, media.videoFormats.count > 1,
            media.videoFormats.allSatisfy({ !HLSSelection.split($0.url).selection.isEmpty })
        else { return media }
        var chosen = media
        chosen.videoFormats.sort { isPreferred($0, over: $1, codecs: codecs) }
        guard let best = chosen.videoFormats.first else { return media }
        chosen.path = best.url
        chosen.selectedVideoFormatID = best.id
        return chosen
    }
}
