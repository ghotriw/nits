import Foundation
import NitsCore

/// A DASH manifest (MPD) of the files YouTube lists as formats (video-only and audio-only `https` ones, each the whole
/// file of one stream): the pictures of each codec, range and container a ladder with adaptive bitrate, the sound of each
/// language a set of its own, the original first. The files are named by keys, their formats' ids (`MediaFileKey`): their
/// signed addresses are a `YouTubeFormatSource`'s, as they expire, and the manifest is kept. Neither says where the
/// initialization or the index of a file is (YouTube's answer has no `initRange` or `indexRange`): the client finds them
/// in the file's start (`SegmentBase` without `indexRange`).
///
/// The codec to play and the choice among the codecs are not its business: the manifest lists all, and the player's
/// resolver offers them as it does for an `.mpd` (`VideoCodecPreference`).
struct YouTubeFormatManifest {
    /// The text of the MPD.
    let text: String
    /// The ids of the formats it names, which are the keys of the addresses it needs.
    let keys: Set<String>
    /// The signed address of each, by key (`MediaFileKey`): the source's, never the manifest's.
    let addresses: [String: String]

    /// A format of the page this reads: video-only or audio-only, over `https`, unprotected, with a file's address and a
    /// container the client's source reads (`mp4`, `m4a`, `webm`).
    fileprivate static func isListed(_ format: YTDLPInfo.Format) -> Bool {
        guard format.protocol == "https", format.url != nil, let id = format.formatID, format.hasDRM != true,
            !id.hasSuffix("-drc"), format.formatNote?.contains("DRC") != true,
            ["mp4", "m4a", "webm"].contains(format.ext?.lowercased() ?? "")
        else { return false }
        let hasVideo = !(format.vcodec ?? "").isEmpty && format.vcodec != "none"
        let hasAudio = !(format.acodec ?? "").isEmpty && format.acodec != "none"
        return hasVideo != hasAudio
    }

    private static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func mimeType(of format: YTDLPInfo.Format, isVideo: Bool) -> String {
        let container = format.ext?.lowercased() == "webm" ? "webm" : "mp4"
        return "\(isVideo ? "video" : "audio")/\(container)"
    }

    /// The transfer of H.273 an HDR picture is marked with (`DASHElements.hdrTransfer`): 16 PQ, 18 HLG.
    private static func transfer(of range: String?) -> Int? {
        switch range {
        case "HDR10", "HDR10+", "DV": 16
        case "HLG": 18
        default: nil
        }
    }

    /// The manifest of `formats`; nil when they hold no picture or no sound to make one of (the page plays as it did).
    init?(formats: [YTDLPInfo.Format]) {
        let listed = Self.keyed(formats.filter(Self.isListed))
        let pictures = listed.filter { !($0.vcodec ?? "").isEmpty && $0.vcodec != "none" }
        let sounds = listed.filter { !($0.acodec ?? "").isEmpty && $0.acodec != "none" }
        guard !pictures.isEmpty, !sounds.isEmpty else { return nil }

        var keys = Set<String>()
        var sets: [String] = []
        // Pictures that may switch with each other share a set: a codec, a range, a container.
        var groups: [String: [YTDLPInfo.Format]] = [:]
        var order: [String] = []
        for picture in pictures {
            let family = (picture.vcodec ?? "").split(separator: ".").first.map(String.init) ?? ""
            let key = "\(family)|\(picture.dynamicRange ?? "SDR")|\(picture.ext?.lowercased() ?? "")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(picture)
        }
        for key in order {
            guard var group = groups[key] else { continue }
            // As YouTube's player does: at 720p and above a ladder keeps its 60 fps rungs and drops the 30 fps ones, so that
            // adaptive bitrate never swaps frame rates (the picture would step between 30 and 60 fps).
            if group.contains(where: { ($0.height ?? 0) >= 720 && ($0.fps ?? 0) > 30 }) {
                group.removeAll { ($0.height ?? 0) >= 720 && ($0.fps ?? 0) <= 30 }
            }
            var representations = ""
            for format in group {
                guard let id = format.formatID else { continue }
                keys.insert(id)
                var attributes =
                    #"id="\#(Self.attribute(id))" mimeType="\#(Self.mimeType(of: format, isVideo: true))""#
                    + #" codecs="\#(Self.attribute(format.vcodec ?? ""))""#
                if let width = format.width, let height = format.height {
                    attributes += #" width="\#(width)" height="\#(height)""#
                }
                if let fps = format.fps, fps > 0 {
                    attributes += #" frameRate="\#(fps)""#.replacingOccurrences(of: ".0\"", with: "\"")
                }
                attributes += #" bandwidth="\#(Int(((format.tbr ?? 0) * 1000).rounded()))""#
                let property =
                    Self.transfer(of: format.dynamicRange).map {
                        #"<EssentialProperty schemeIdUri="urn:mpeg:mpegB:cicp:TransferCharacteristics" value="\#($0)"/>"#
                    } ?? ""
                representations +=
                    "<Representation \(attributes)>\(property)<BaseURL>\(MediaFileKey.address(id))</BaseURL><SegmentBase/>"
                    + "</Representation>"
            }
            sets.append(#"<AdaptationSet contentType="video">\#(representations)</AdaptationSet>"#)
        }

        // The sound of each language: the original (yt-dlp ranks it highest, and notes it) is the main one, the others dubs.
        var languages: [String: [YTDLPInfo.Format]] = [:]
        var languageOrder: [String] = []
        for sound in sounds {
            let language = sound.language ?? ""
            if languages[language] == nil { languageOrder.append(language) }
            languages[language, default: []].append(sound)
        }
        let best = languages.values.compactMap { $0.map { $0.languagePreference ?? -1 }.max() }.max() ?? -1
        for language in languageOrder {
            guard let group = languages[language] else { continue }
            let preference = group.map { $0.languagePreference ?? -1 }.max() ?? -1
            let isOriginal =
                group.contains { $0.formatNote?.lowercased().contains("original") == true }
                || (languages.count == 1) || (preference == best && best > 0)
            var representations = ""
            for format in group {
                guard let id = format.formatID else { continue }
                keys.insert(id)
                var attributes =
                    #"id="\#(Self.attribute(id))" mimeType="\#(Self.mimeType(of: format, isVideo: false))""#
                    + #" codecs="\#(Self.attribute(format.acodec ?? ""))""#
                if let rate = format.sampleRate { attributes += #" audioSamplingRate="\#(rate)""# }
                let bitrate = format.abr ?? format.tbr ?? 0
                attributes += #" bandwidth="\#(Int((bitrate * 1000).rounded()))""#
                representations +=
                    "<Representation \(attributes)>"
                    + (format.audioChannels.map {
                        #"<AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="\#($0)"/>"#
                    } ?? "")
                    + "<BaseURL>\(MediaFileKey.address(id))</BaseURL><SegmentBase/></Representation>"
            }
            let lang = language.isEmpty ? "" : #" lang="\#(Self.attribute(language))""#
            let role = #"<Role schemeIdUri="urn:mpeg:dash:role:2011" value="\#(isOriginal ? "main" : "dub")"/>"#
            sets.append(#"<AdaptationSet contentType="audio"\#(lang)>\#(role)\#(representations)</AdaptationSet>"#)
        }
        self.keys = keys
        addresses = Self.addresses(of: formats).filter { keys.contains($0.key) }
        text =
            #"<?xml version="1.0" encoding="UTF-8"?>"#
            + #"<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" "#
            + #"profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period>"#
            + sets.joined() + "</Period></MPD>"
    }
}

extension YouTubeFormatManifest {
    /// What the manifest names `format` by. A format's id ("251"), but a dubbed sound's ("251-3": the itag and its
    /// position in the page's list of languages, which another asking may order differently) is its itag and language
    /// ("251-de"), so that the addresses a renewal brings are those of the same sound.
    static func key(of format: YTDLPInfo.Format) -> String? {
        guard let id = format.formatID else { return nil }
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
            let language = format.language, !language.isEmpty
        else { return id }
        return "\(parts[0])-\(language)"
    }

    /// The signed address of each file the manifest of `formats` names, by key.
    static func addresses(of formats: [YTDLPInfo.Format]) -> [String: String] {
        var urls: [String: String] = [:]
        for format in Self.keyed(formats.filter(Self.isListed)) {
            if let key = format.formatID, let url = format.url { urls[key] = url }
        }
        return urls
    }
}

extension YouTubeFormatManifest {
    /// `formats` with each id replaced by the key the manifest names it by (`key(of:)`). Two that would share a key (a dub and
    /// an audio description in one language) keep their own ids, so that neither's address overwrites the other's.
    static func keyed(_ formats: [YTDLPInfo.Format]) -> [YTDLPInfo.Format] {
        var counts: [String: Int] = [:]
        for format in formats { if let key = key(of: format) { counts[key, default: 0] += 1 } }
        return formats.compactMap { format in
            guard let key = key(of: format) else { return nil }
            var keyed = format
            if counts[key] == 1 { keyed.formatID = key }
            return keyed
        }
    }
}
