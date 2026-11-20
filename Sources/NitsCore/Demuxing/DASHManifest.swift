import Foundation
internal import NitsStreaming

/// A DASH manifest (MPD) read by the resolver (`DASHManifestResolver`) for what it offers to choose from.
///
/// The client (`DASHPlaylists`) reads the manifest itself and plays it; what the resolver keeps of it is the choices
/// the player shows: the ladder of one codec and range (the pictures that follow the network as one; the best picture
/// of each other codec is offered to choose from), the best audio of each language, nothing without a decoder (DRM,
/// text, images). A choice is told to the client by the manifest's own address with the pictures' id in its fragment
/// (`DASHSelection`, `address(videoID:)`): the manifest is not written again.
///
/// Only a finished (`static`) manifest of one period is handled; for others the initializer returns nil, and the
/// address is opened as it is.
package struct DASHManifest {
    /// A picture of the manifest, as played: the best of those of its size, frame rate and codec.
    package struct Video: Equatable {
        package var id: String
        package var width: Int
        package var height: Int
        package var frameRate: Double?
        /// As shown ("H.264", "HEVC").
        package var codec: String
        /// Bits per second; 0 when unknown.
        package var bandwidth: Int
        package var isHDR: Bool
        /// The codec's family (`CodecFamily.video(in:)`); empty when the manifest tells none.
        package var family = ""
        /// What switches with what, as the client groups them (`DASHPictureGroup`). Internal: NitsStreaming is imported
        /// internally, so a `package` declaration cannot name its types.
        var group: DASHPictureGroup
        /// Its media is segments, so that the demuxer can seek in it and switch to it at a position: a template, a list,
        /// or one file with its index (`SegmentBase`: an MP4's `sidx`, a WebM's `Cues`), whose segments the client's
        /// source reads from the index. One file without an index range is read from its start to either.
        package var isSegmented = true
    }

    /// The most a manifest read may be, in bytes: a ladder of a few dozen representations is a few hundred kilobytes.
    package static let sizeLimit = 8 << 20

    /// Where a representation is: the index of its adaptation set in the period, and its own in the set.
    private struct Place: Hashable {
        var set: Int
        var representation: Int
    }

    private let root: XMLTreeElement
    private let periodIndex: Int
    private let manifestURL: URL
    /// The order of audio codecs the sounds are chosen by, told to the client with each address (`DASHSelection`).
    private let audioCodecs: AudioCodecPreference
    /// The pictures played, the best first.
    package let videos: [Video]
    private let videoPlaces: [String: Place]
    /// The id of each representation played (`DASHElements.uniqueID`), as the client names it.
    private let ids: [Place: String]
    /// The best sound of each language, the main one's first, with its language ("" when the manifest tells none).
    private let audio: [(place: Place, language: String)]
    private var audioPlaces: [Place] { audio.map(\.place) }

    /// Whether the manifest has audio to play.
    package var hasAudio: Bool { !audioPlaces.isEmpty }

    /// The manifest's title (`ProgramInformation`), if it has one.
    package var title: String? {
        root.elements(named: "ProgramInformation").first?.elements(named: "Title").first?.text
            .nilIfEmpty
    }

    /// Pictures or sounds the manifest has that are protected (DRM), which are not played.
    package let hasProtectedStreams: Bool

    /// - Parameters:
    ///   - data: The manifest.
    ///   - url: Where it came from, after redirects: what its relative addresses are relative to.
    ///   - codecs: Which codec is preferred among the pictures of a size.
    ///   - audioCodecs: Which codec is preferred among the sounds of a language.
    package init?(
        data: Data, url: URL, codecs: VideoCodecPreference = VideoCodecPreference(),
        audioCodecs: AudioCodecPreference = AudioCodecPreference()
    ) {
        guard let root = XMLTreeElement.parse(data, limit: Self.sizeLimit), root.localName == "MPD",
            (root.attribute("type") ?? "static") == "static"
        else { return nil }
        let periods = root.children.indices.filter { index in
            if case .element(let element) = root.children[index] { element.localName == "Period" } else { false }
        }
        guard periods.count == 1, case .element(let period) = root.children[periods[0]] else { return nil }
        self.root = root
        self.manifestURL = url
        self.audioCodecs = audioCodecs
        self.periodIndex = periods[0]

        var pictures: [(video: Video, place: Place, isKnownCodec: Bool)] = []
        var sounds:
            [(place: Place, language: String, bandwidth: Int, role: Int, isKnownCodec: Bool, channels: Int, rank: Int)] =
                []
        var hasProtected = false
        var usedIDs = Set<String>()
        var ids: [Place: String] = [:]
        for (setIndex, node) in period.children.enumerated() {
            guard case .element(let set) = node, set.localName == "AdaptationSet", !DASHElements.isTrickMode(set) else {
                continue
            }
            let setKind = DASHElements.kind(of: set)
            for (index, child) in set.children.enumerated() {
                guard case .element(let representation) = child, representation.localName == "Representation" else {
                    continue
                }
                let kind = setKind ?? DASHElements.kind(of: representation)
                guard kind == "video" || kind == "audio" else { continue }
                if !set.elements(named: "ContentProtection").isEmpty
                    || !representation.elements(named: "ContentProtection").isEmpty
                {
                    hasProtected = true
                    continue
                }
                let place = Place(set: setIndex, representation: index)
                ids[place] = DASHElements.uniqueID(of: representation, set: setIndex, index: index, used: &usedIDs)
                let value = { (name: String) in representation.attribute(name) ?? set.attribute(name) }
                let bandwidth = representation.attribute("bandwidth").flatMap { Int($0) } ?? 0
                if kind == "audio" {
                    // A sound the build cannot decode (AC-4, MPEG-H) is not played, whatever its bitrate: the stream
                    // would be silent.
                    let canDecode = value("codecs").flatMap(CodecFamily.canDecodeAudio(in:))
                    guard canDecode != false else { continue }
                    sounds.append(
                        (
                            place, set.attribute("lang") ?? representation.attribute("lang") ?? "", bandwidth,
                            DASHElements.roleRank(of: representation, in: set), canDecode == true,
                            DASHElements.channelCount(of: representation, in: set),
                            audioCodecs.rank(ofFamily: value("codecs").flatMap(CodecFamily.audio(in:)))
                        ))
                    continue
                }
                let family = value("codecs").flatMap(CodecFamily.video)
                let isHDR =
                    family.map(CodecFamily.isDolbyVision) == true
                    || (DASHElements.hdrTransfer(of: set) != nil)
                    || (DASHElements.hdrTransfer(of: representation) != nil)
                let supplemental = value("scte214:supplementalCodecs").flatMap(CodecFamily.video)
                let range = DASHElements.hdrTransfer(of: representation) ?? DASHElements.hdrTransfer(of: set)
                // A WebM and an MP4 of one codec do not switch with each other (`DASHPlaylists.pictures`).
                let isWebM = value("mimeType")?.lowercased().hasSuffix("/webm") == true
                let group = DASHPictureGroup(
                    codecs: value("codecs"), supplementalCodecs: value("scte214:supplementalCodecs"), range: range,
                    isWebM: isWebM)
                pictures.append(
                    (
                        Video(
                            id: ids[place] ?? "",
                            width: value("width").flatMap { Int($0) } ?? 0,
                            height: value("height").flatMap { Int($0) } ?? 0,
                            frameRate: value("frameRate").flatMap(DASHElements.frameRate(of:)),
                            codec: family.map(CodecFamily.displayName(ofVideo:)) ?? "", bandwidth: bandwidth,
                            isHDR: isHDR, family: family ?? "", group: group,
                            isSegmented: Self.hasSegments(in: [representation, set, period])), place, family != nil
                    ))
            }
        }
        self.hasProtectedStreams = hasProtected

        // The best first: a codec told over one that is not, then `LadderChoice`'s order (the client's rule for the best
        // ladder: the larger picture, the HDR one, the codec the user prefers, the higher bitrate).
        func key(_ video: Video) -> (Int, Int, Int, Int, Int) {
            LadderChoice.key(
                height: video.height, width: video.width, isHDR: video.isHDR, family: video.family,
                bandwidth: video.bandwidth, codecRank: codecs.rank(ofFamily:))
        }
        pictures.sort { lhs, rhs in
            if lhs.isKnownCodec != rhs.isKnownCodec { return lhs.isKnownCodec }
            return key(lhs.video) > key(rhs.video)
        }
        // Files the client reads no index of (one without an index range: not `isSegmented`) play as files when the
        // manifest has no other picture (`playsAsFiles`). Beside pictures the client reads they are left out, before the
        // duplicates are (a file must not take the place of the same picture told otherwise): as files, their formats
        // would share the page's added sound (`ResolvedMedia.audioFiles`) with a manifest that carries its own.
        if pictures.contains(where: \.video.isSegmented) { pictures.removeAll { !$0.video.isSegmented } }
        // Each is offered; one that a second adaptation set lists again (the same size, codec and bitrate) once.
        struct PictureKey: Hashable {
            var width, height, frameRate: Int
            var group: DASHPictureGroup
            var isHDR: Bool
            var bandwidth: Int
        }
        var seenKeys: Set<PictureKey> = []
        var videos: [Video] = []
        var places: [String: Place] = [:]
        for picture in pictures {
            let video = picture.video
            let key = PictureKey(
                width: video.width, height: video.height, frameRate: Int((video.frameRate ?? 0).rounded()),
                group: video.group, isHDR: video.isHDR, bandwidth: video.bandwidth)
            guard seenKeys.insert(key).inserted else { continue }
            videos.append(picture.video)
            places[picture.video.id] = picture.place
        }
        self.videos = videos
        self.videoPlaces = places
        self.ids = ids

        // The best audio of each language, the main one's language first. Of a language: the main track over one
        // without a role over a commentary or a description (a higher bitrate does not make those the sound of the
        // language), then a codec told to be decoded over one that is not told, then more channels (one that tells none counts as stereo), then the codec the user prefers (a bitrate says nothing
        // of the quality across codecs), then the higher bitrate.
        var bestSound:
            [String: (place: Place, bandwidth: Int, role: Int, isKnownCodec: Bool, channels: Int, rank: Int)] = [:]
        var languages: [String] = []
        for sound in sounds {
            if let current = bestSound[sound.language] {
                let held = [
                    current.role, current.isKnownCodec ? 1 : 0, current.channels == 0 ? 2 : current.channels,
                    -current.rank, current.bandwidth,
                ]
                if held.lexicographicallyPrecedes([
                    sound.role, sound.isKnownCodec ? 1 : 0, sound.channels == 0 ? 2 : sound.channels, -sound.rank,
                    sound.bandwidth,
                ]
                ) {
                    bestSound[sound.language] = (
                        sound.place, sound.bandwidth, sound.role, sound.isKnownCodec, sound.channels, sound.rank
                    )
                }
            } else {
                bestSound[sound.language] = (
                    sound.place, sound.bandwidth, sound.role, sound.isKnownCodec, sound.channels, sound.rank
                )
                languages.append(sound.language)
            }
        }
        languages.sort { (bestSound[$0]?.role == 2) && !(bestSound[$1]?.role == 2) }
        self.audio = languages.compactMap { language in bestSound[language].map { ($0.place, language) } }

    }

    /// The order of audio codecs to put in an address: only one that is not the client's own default.
    private var audioCodecsToTell: [String] {
        audioCodecs == AudioCodecPreference() ? [] : audioCodecs.order
    }

    /// The address that plays the picture `videoID` (the best one when nil): the manifest's own, with the choice in its
    /// fragment (`DASHSelection`), which the client reads; for a manifest of sound alone, its own address. Nil when the
    /// picture is none of `videos`.
    package func address(videoID: String? = nil) -> String? {
        if videoID == nil, videos.isEmpty {
            return DASHSelection(audioCodecs: audioCodecsToTell).address(of: manifestURL)
        }
        guard let id = videoID ?? videos.first?.id, videoPlaces[id] != nil else { return nil }
        return DASHSelection(video: id, audioCodecs: audioCodecsToTell).address(of: manifestURL)
    }

    /// The pictures that can follow the network as one: those of the best one's codec and range (HDR or not), as
    /// the picture changes between them without a new decoder (HLS's ladder, `playlistsOutsideLadder`). The best first.
    /// Fewer than two is no ladder.
    package var ladder: [Video] {
        videos.first.map(ladder(of:)) ?? []
    }

    /// `Video.isSegmented` for a representation, `nodes` its levels from itself up.
    private static func hasSegments(in nodes: [XMLTreeElement]) -> Bool {
        if nodes.contains(where: {
            !$0.elements(named: "SegmentTemplate").isEmpty || !$0.elements(named: "SegmentList").isEmpty
        }) {
            return true
        }
        // A WebM's cues count from its Segment's data, which only its start tells: the client reads one that says where
        // that start is (an `Initialization` from the file's first byte), else it plays as a file.
        let isWebM = nodes.lazy.compactMap { $0.attribute("mimeType") }.first?.lowercased().hasSuffix("/webm") == true
        // As the client reads it (`DASHPresentation.oneFile`): an `Initialization` of any level, of the file itself.
        let hasStart = nodes.flatMap { $0.elements(named: "SegmentBase") }.flatMap {
            $0.elements(named: "Initialization")
        }
        .contains { $0.attribute("range")?.hasPrefix("0-") == true && $0.attribute("sourceURL") == nil }
        return nodes.contains { node in
            node.elements(named: "SegmentBase").contains {
                if $0.attribute("indexRange") != nil || !$0.elements(named: "RepresentationIndex").isEmpty {
                    return !isWebM || hasStart
                }
                // No index range: the client finds the index in the file itself (`SingleFileLayout`), unless the
                // initialization is a file of its own, which it cannot place the index against.
                return $0.elements(named: "Initialization").allSatisfy { $0.attribute("sourceURL") == nil }
            }
        }
    }

    /// The ladder of `video`'s codec and range, the best first. Fewer than two is no ladder, nor is one of pictures that
    /// are single files without an index the client reads (`isSegmented`): such a file is read from its start to switch
    /// to it.
    package func ladder(of video: Video) -> [Video] {
        guard video.isSegmented else { return [] }
        let rungs = videos.filter {
            $0.group == video.group && $0.bandwidth > 0 && $0.isSegmented
        }
        return rungs.count > 1 ? rungs : []
    }

    /// The best picture of each codec and range, the best first: what a viewer chooses between when the manifest has
    /// more than one (a ladder plays as one, its other codecs are these).
    package var codecGroups: [Video] {
        var seen = Set<DASHPictureGroup>()
        return videos.filter { seen.insert($0.group).inserted }
    }

    /// What the relative addresses of the manifest are relative to: its own `BaseURL`, or the folder of the manifest.
    private var absoluteBase: String {
        if let declared = root.elements(named: "BaseURL").first?.text, !declared.isEmpty,
            let url = URL(string: declared, relativeTo: manifestURL)
        {
            return url.absoluteURL.absoluteString
        }
        guard var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: true) else {
            return manifestURL.absoluteString
        }
        components.query = nil
        components.fragment = nil
        let path = components.path
        if let slash = path.lastIndex(of: "/") { components.path = String(path[...slash]) }
        return components.string ?? manifestURL.absoluteString
    }

    // MARK: - Files

    /// The pictures are all files the client reads no index of (a file without an index range):
    /// each plays as a file (`file(videoID:)`), its sound added (`sounds`), without adaptive bitrate; a seek is one in a
    /// network file. Not when the manifest has a picture the client reads: those files are then left out.
    package var playsAsFiles: Bool { !videos.isEmpty && !videos.contains(where: \.isSegmented) }

    /// A sound of the manifest, to add to a picture played as a file.
    package struct Sound: Equatable {
        /// Its file, for one the client reads no index of; else a manifest of it alone, which the client reads.
        package var path: String
        package var language: String?
    }

    /// The best sound of each language, the main one's first: a file the client reads no index of as it is (FFmpeg reads
    /// it), any other as a manifest of it alone (the client reads it: segments, or a file with its `sidx`), written by
    /// the manifest's address with that sound as the choice (`DASHSelection`).
    package func sounds() -> [Sound] {
        guard case .element(let period) = root.children[periodIndex] else { return [] }
        return audio.compactMap { place, language in
            guard case .element(let set) = period.children[place.set],
                case .element(let representation) = set.children[place.representation]
            else { return nil }
            let path: String
            if !Self.hasSegments(in: [representation, set, period]),
                let url = fileURL(of: representation, in: set, period: period)
            {
                path = url.absoluteString
            } else {
                guard let id = ids[place], !endsNever(representation, in: set, period: period) else { return nil }
                path = DASHSelection(audio: id).address(of: manifestURL)
            }
            return Sound(path: path, language: language.isEmpty ? nil : language)
        }
    }

    /// A timeline that repeats a segment to the end (`<S r="-1"/>`) in a manifest that tells no length of its period: it
    /// has no end the client could count to, so the sound of it is not played (it would be required, and refused).
    private func endsNever(_ representation: XMLTreeElement, in set: XMLTreeElement, period: XMLTreeElement) -> Bool {
        let repeats = [representation, set, period].flatMap { $0.elements(named: "SegmentTemplate") }
            .flatMap { $0.elements(named: "SegmentTimeline") }.flatMap { $0.elements(named: "S") }
            .contains { ($0.attribute("r").flatMap { Int($0) } ?? 0) < 0 }
        let hasLength =
            period.attribute("duration").flatMap(DASHElements.duration(of:)) != nil
            || root.attribute("mediaPresentationDuration").flatMap(DASHElements.duration(of:)) != nil
        return repeats && !hasLength
    }

    /// The file of the picture `videoID`; nil when it is none of `videos` or has no `BaseURL` of its own.
    package func file(videoID: String) -> URL? {
        guard let place = videoPlaces[videoID], case .element(let period) = root.children[periodIndex],
            case .element(let set) = period.children[place.set],
            case .element(let representation) = set.children[place.representation]
        else { return nil }
        return fileURL(of: representation, in: set, period: period)
    }

    /// The file of a representation: its `BaseURL`, and those above it, resolved. Nil when the set and the
    /// representation tell none (the manifest's own address is no file).
    private func fileURL(of representation: XMLTreeElement, in set: XMLTreeElement, period: XMLTreeElement) -> URL? {
        var url = URL(string: absoluteBase)
        var hasOwn = false
        for (node, isOwn) in [(period, false), (set, true), (representation, true)] {
            guard
                let text = node.elements(named: "BaseURL").first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            url = URL(string: text, relativeTo: url)?.absoluteURL
            hasOwn = hasOwn || isOwn
        }
        return hasOwn ? url : nil
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
