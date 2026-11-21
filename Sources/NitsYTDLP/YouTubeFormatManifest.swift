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
    static func isListed(_ format: YTDLPInfo.Format) -> Bool {
        guard format.protocol == "https", format.url != nil, let id = format.formatID, format.hasDRM != true,
            !id.hasSuffix("-drc"), format.formatNote?.contains("DRC") != true,
            ["mp4", "m4a", "webm"].contains(format.ext?.lowercased() ?? "")
        else { return false }
        return YouTubeFormatGrouping.hasPicture(format) != YouTubeFormatGrouping.hasSound(format)
    }

    private static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func mimeType(of format: YTDLPInfo.Format, isVideo: Bool) -> String {
        let container = format.ext?.lowercased() == "webm" ? "webm" : "mp4"
        return "\(isVideo ? "video" : "audio")/\(container)"
    }

    /// The manifest of `formats`; nil when they hold no picture or no sound to make one of (the page plays as it did).
    init?(formats: [YTDLPInfo.Format]) {
        let listed = Self.keyed(formats.filter(Self.isListed))
        let pictures = listed.filter(YouTubeFormatGrouping.hasPicture)
        let sounds = listed.filter(YouTubeFormatGrouping.hasSound)
        guard !pictures.isEmpty, !sounds.isEmpty else { return nil }

        var keys = Set<String>()
        var sets: [String] = []
        // Pictures that may switch with each other share a set: a codec, a range, a container.
        for group in YouTubeFormatGrouping.pictureSets(of: pictures) {
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
                    YouTubeFormatGrouping.transfer(of: format.dynamicRange).map(SegmentedDASHManifest.transferProperty)
                    ?? ""
                representations +=
                    "<Representation \(attributes)>\(property)<BaseURL>\(MediaFileKey.address(id))</BaseURL><SegmentBase/>"
                    + "</Representation>"
            }
            sets.append(#"<AdaptationSet contentType="video">\#(representations)</AdaptationSet>"#)
        }

        // The sound of each language: the original is the main one, the others dubs.
        for soundSet in YouTubeFormatGrouping.soundSets(of: sounds) {
            let (language, group, isOriginal) = (soundSet.language, soundSet.formats, soundSet.isOriginal)
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
        addresses(ofKeyed: keyed(formats.filter(isListed)))
    }

    /// The signed address of each of `formats`, already keyed (`keyed(_:)`), by key.
    static func addresses(ofKeyed formats: [YTDLPInfo.Format]) -> [String: String] {
        var urls: [String: String] = [:]
        for format in formats {
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
