import Foundation

/// How the formats a YouTube page lists are grouped into what can switch with each other: the pictures of a codec, a
/// range and a container make a ladder (adaptive bitrate), the sound of a language a set of its own, the original first.
/// One rule for the manifest of an ordinary video's files (`YouTubeFormatManifest`) and of a live stream's history
/// (`YTDLPInfo.liveHistoryStreams`), so that both offer what the viewer chooses between in the same way.
enum YouTubeFormatGrouping {
    /// The sound of one language.
    struct SoundSet {
        var language: String
        /// The page's original language (not a dub): its set is the main one.
        var isOriginal: Bool
        var formats: [YTDLPInfo.Format]
    }

    static func hasPicture(_ format: YTDLPInfo.Format) -> Bool {
        !(format.vcodec ?? "").isEmpty && format.vcodec != "none"
    }

    static func hasSound(_ format: YTDLPInfo.Format) -> Bool {
        !(format.acodec ?? "").isEmpty && format.acodec != "none"
    }

    /// The pictures of `formats` in the sets that may switch with each other (a codec, a range, a container), in the order
    /// of their first appearance.
    static func pictureSets(of formats: [YTDLPInfo.Format]) -> [[YTDLPInfo.Format]] {
        var groups: [String: [YTDLPInfo.Format]] = [:]
        var order: [String] = []
        for picture in formats where hasPicture(picture) {
            let family = (picture.vcodec ?? "").split(separator: ".").first.map(String.init) ?? ""
            let key = "\(family)|\(YTDLPDynamicRange(picture.dynamicRange))|\(picture.ext?.lowercased() ?? "")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(picture)
        }
        return order.compactMap { key in
            guard var group = groups[key] else { return nil }
            // As YouTube's player does: at 720p and above a ladder keeps its 60 fps rungs and drops the 30 fps ones, so that
            // adaptive bitrate never swaps frame rates (the picture would step between 30 and 60 fps).
            if group.contains(where: { ($0.height ?? 0) >= 720 && ($0.fps ?? 0) > 30 }) {
                group.removeAll { ($0.height ?? 0) >= 720 && ($0.fps ?? 0) <= 30 }
            }
            return group
        }
    }

    /// The sound of each language: the original (yt-dlp ranks it highest, and notes it) is the main one, the others dubs.
    /// With `splitsContainers`, a set for each container a language comes in: for a manifest whose `AdaptationSet` has one MIME
    /// type (`SegmentedDASHManifest`), not the ordinary video's, which tells it of each representation.
    static func soundSets(of formats: [YTDLPInfo.Format], splitsContainers: Bool = false) -> [SoundSet] {
        var languages: [String: [YTDLPInfo.Format]] = [:]
        var order: [String] = []
        for sound in formats where hasSound(sound) {
            let language = sound.language ?? ""
            if languages[language] == nil { order.append(language) }
            languages[language, default: []].append(sound)
        }
        let best = languages.values.compactMap { $0.map { $0.languagePreference ?? -1 }.max() }.max() ?? -1
        return order.flatMap { language -> [SoundSet] in
            let group = languages[language] ?? []
            let preference = group.map { $0.languagePreference ?? -1 }.max() ?? -1
            let isOriginal =
                group.contains { $0.formatNote?.lowercased().contains("original") == true }
                || (languages.count == 1) || (preference == best && best > 0)
            var byContainer: [String: [YTDLPInfo.Format]] = [:]
            var containers: [String] = []
            for sound in group {
                let container =
                    splitsContainers && ["webm", "weba"].contains(sound.ext?.lowercased() ?? "") ? "webm" : "mp4"
                if byContainer[container] == nil { containers.append(container) }
                byContainer[container, default: []].append(sound)
            }
            return containers.map {
                SoundSet(language: language, isOriginal: isOriginal, formats: byContainer[$0] ?? [])
            }
        }
    }

    /// The transfer of H.273 an HDR picture is marked with (`DASHElements.hdrTransfer`): 16 PQ, 18 HLG.
    static func transfer(of range: String?) -> Int? {
        YTDLPDynamicRange(range).transfer
    }
}
