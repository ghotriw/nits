import Foundation

/// A DASH manifest (MPD) read to be played by FFmpeg's DASH demuxer, and written again for it.
///
/// FFmpeg opens every representation of a manifest as soon as it opens it (seconds, over the network, for a ladder of
/// a dozen), fails the whole opening for one it cannot read (a TTML subtitle track), and plays the first picture it
/// lists, the lowest. It also seeks wrongly in a timeline that repeats a segment "to the end" (`r="-1"`: it lands
/// on the second segment). So the manifest is rewritten before FFmpeg sees it: the ladder of one codec and range (the
/// pictures that follow the network as one; the best picture of each other codec is offered to choose from), the best
/// audio of each language, nothing FFmpeg cannot read, a timeline that
/// ends, and an absolute `BaseURL`. Given to the demuxer inline (`MediaURL.inlineDASHManifest`).
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
        /// Its media is segments, so that the demuxer can seek in it and switch to it at a position: a template, a list,
        /// or one MP4 file with its index (`SegmentBase`), whose segments the client's source reads from the index. One
        /// file without an index the client reads (WebM's is its `Cues`) is read from its start to either.
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
    private let periodDuration: Double?
    private let manifestURL: URL
    /// The pictures played, the best first.
    package let videos: [Video]
    private let videoPlaces: [String: Place]
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
    package init?(data: Data, url: URL, codecs: VideoCodecPreference = VideoCodecPreference()) {
        guard let root = XMLTreeElement.parse(data, limit: Self.sizeLimit), root.localName == "MPD",
            (root.attribute("type") ?? "static") == "static"
        else { return nil }
        let periods = root.children.indices.filter { index in
            if case .element(let element) = root.children[index] { element.localName == "Period" } else { false }
        }
        guard periods.count == 1, case .element(let period) = root.children[periods[0]] else { return nil }
        self.root = root
        self.manifestURL = url
        self.periodIndex = periods[0]
        let start = period.attribute("start").flatMap(DASHElements.duration(of:)) ?? 0
        self.periodDuration =
            period.attribute("duration").flatMap(DASHElements.duration(of:))
            ?? root.attribute("mediaPresentationDuration").flatMap(DASHElements.duration(of:)).map { $0 - start }

        var pictures: [(video: Video, place: Place, isKnownCodec: Bool)] = []
        var sounds: [(place: Place, language: String, bandwidth: Int, role: Int, isKnownCodec: Bool)] = []
        var hasProtected = false
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
                            DASHElements.roleRank(of: representation, in: set), canDecode == true
                        ))
                    continue
                }
                let family = value("codecs").flatMap(CodecFamily.video)
                let isHDR =
                    family.map(CodecFamily.isDolbyVision) == true
                    || (DASHElements.hdrTransfer(of: set) != nil)
                    || (DASHElements.hdrTransfer(of: representation) != nil)
                pictures.append(
                    (
                        Video(
                            id: representation.attribute("id") ?? "\(setIndex).\(index)",
                            width: value("width").flatMap { Int($0) } ?? 0,
                            height: value("height").flatMap { Int($0) } ?? 0,
                            frameRate: value("frameRate").flatMap(DASHElements.frameRate(of:)),
                            codec: family.map(CodecFamily.displayName(ofVideo:)) ?? "", bandwidth: bandwidth,
                            isHDR: isHDR, family: family ?? "",
                            isSegmented: Self.hasSegments(in: [representation, set, period])), place, family != nil
                    ))
            }
        }
        self.hasProtectedStreams = hasProtected

        // The best first: a codec told over one that is not; then the larger picture, the HDR one, the codec the user
        // prefers (a bitrate says nothing of the quality across codecs), the higher bitrate.
        pictures.sort { lhs, rhs in
            let (a, b) = (lhs.video, rhs.video)
            if lhs.isKnownCodec != rhs.isKnownCodec { return lhs.isKnownCodec }
            if a.height != b.height { return a.height > b.height }
            if a.width != b.width { return a.width > b.width }
            if a.isHDR != b.isHDR { return a.isHDR }
            let (ra, rb) = (codecs.rank(ofFamily: a.family), codecs.rank(ofFamily: b.family))
            if ra != rb { return ra < rb }
            return a.bandwidth > b.bandwidth
        }
        // Files the client reads no index of (a WebM file's is its `Cues`: not `isSegmented`) play as files when the
        // manifest has no other picture (`playsAsFiles`). Beside pictures the client reads they are left out, before the
        // duplicates are (a file must not take the place of the same picture told otherwise): as files, their formats
        // would share the page's added sound (`ResolvedMedia.audioFiles`) with a manifest that carries its own. The
        // client reading `Cues` would make them pictures of the manifest again: then this goes (PLAN.md, 3b).
        if pictures.contains(where: \.video.isSegmented) { pictures.removeAll { !$0.video.isSegmented } }
        // Each is offered; ids kept unique, and one that a second adaptation set lists again (the same size, codec and
        // bitrate) once.
        var seenKeys: Set<String> = []
        var seenIDs: Set<String> = []
        var videos: [Video] = []
        var places: [String: Place] = [:]
        for var picture in pictures {
            let key =
                "\(picture.video.width)x\(picture.video.height)@\(Int((picture.video.frameRate ?? 0).rounded()))"
                + " \(picture.video.family) \(picture.video.isHDR) \(picture.video.bandwidth)"
            guard seenKeys.insert(key).inserted else { continue }
            if !seenIDs.insert(picture.video.id).inserted {
                picture.video.id = "\(picture.place.set).\(picture.place.representation)"
                seenIDs.insert(picture.video.id)
            }
            videos.append(picture.video)
            places[picture.video.id] = picture.place
        }
        self.videos = videos
        self.videoPlaces = places

        // The best audio of each language, the main one's language first. Of a language: the main track over one
        // without a role over a commentary or a description (a higher bitrate does not make those the sound of the
        // language), then a codec told to be decoded over one that is not told, then the higher bitrate.
        var bestSound: [String: (place: Place, bandwidth: Int, role: Int, isKnownCodec: Bool)] = [:]
        var languages: [String] = []
        for sound in sounds {
            if let current = bestSound[sound.language] {
                let held = [current.role, current.isKnownCodec ? 1 : 0, current.bandwidth]
                if held.lexicographicallyPrecedes([sound.role, sound.isKnownCodec ? 1 : 0, sound.bandwidth]) {
                    bestSound[sound.language] = (sound.place, sound.bandwidth, sound.role, sound.isKnownCodec)
                }
            } else {
                bestSound[sound.language] = (sound.place, sound.bandwidth, sound.role, sound.isKnownCodec)
                languages.append(sound.language)
            }
        }
        languages.sort { (bestSound[$0]?.role == 2) && !(bestSound[$1]?.role == 2) }
        self.audio = languages.compactMap { language in bestSound[language].map { ($0.place, language) } }

        // Written once to know that it can be: a timeline that cannot be made to end is not for FFmpeg to seek in. Not
        // when the pictures play as files: a sound of such a timeline is then left out alone (`sounds`).
        let playsAsFiles = !videos.isEmpty && !videos.contains(where: \.isSegmented)
        guard
            videos.isEmpty && audio.isEmpty || playsAsFiles
                || rewritten(videoIDs: videos.prefix(1).map(\.id)) != nil
        else {
            return nil
        }
    }

    /// The manifest with the picture `videoID` (the best one when nil) and the audio, as the demuxer is given it. Nil
    /// when the picture is none of `videos`.
    package func text(videoID: String? = nil) -> String? {
        text(videoIDs: (videoID ?? videos.first?.id).map { [$0] } ?? [])
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
        let isWebM = nodes.lazy.compactMap { $0.attribute("mimeType") }.first?.lowercased().hasSuffix("/webm") == true
        return !isWebM
            && nodes.contains { node in
                node.elements(named: "SegmentBase").contains {
                    $0.attribute("indexRange") != nil || !$0.elements(named: "RepresentationIndex").isEmpty
                }
            }
    }

    /// The ladder of `video`'s codec and range, the best first. Fewer than two is no ladder, nor is one of pictures that
    /// are single files without an index the client reads (`isSegmented`): such a file is read from its start to switch
    /// to it.
    package func ladder(of video: Video) -> [Video] {
        guard video.isSegmented else { return [] }
        let rungs = videos.filter {
            $0.family == video.family && $0.isHDR == video.isHDR && $0.bandwidth > 0 && $0.isSegmented
        }
        return rungs.count > 1 ? rungs : []
    }

    /// The best picture of each codec and range, the best first: what a viewer chooses between when the manifest has
    /// more than one (a ladder plays as one, its other codecs are these).
    package var codecGroups: [Video] {
        var seen = Set<String>()
        return videos.filter { seen.insert("\($0.family) \($0.isHDR)").inserted }
    }

    /// The manifest with every picture of `ladder` and the audio, for the demuxer to switch between the pictures with
    /// the network (`MediaDemuxer.variants`). It opens every representation at once, so it costs the opening of each;
    /// nil without a ladder.
    package func ladderText(of video: Video? = nil) -> String? {
        let rungs = video.map(ladder(of:)) ?? ladder
        guard !rungs.isEmpty else { return nil }
        return text(videoIDs: rungs.map(\.id))
    }

    /// `rewritten` as the demuxer is given it.
    private func text(videoIDs: [String], audio: [Place]? = nil) -> String? {
        guard let rewritten = rewritten(videoIDs: videoIDs, audio: audio) else { return nil }
        return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + rewritten.serialized()
    }

    private func rewritten(videoIDs: [String], audio: [Place]? = nil) -> XMLTreeElement? {
        var kept: [Place] = audio ?? audioPlaces
        for id in videoIDs.reversed() {
            guard let place = videoPlaces[id] else { return nil }
            kept.insert(place, at: 0)
        }
        guard !kept.isEmpty else { return nil }
        guard case .element(var period) = root.children[periodIndex] else { return nil }
        // The demuxer lists the streams in the order of the manifest: the picture, then the sounds in the order chosen.
        var leading: [XMLTreeElement.Node] = []
        var trailing: [XMLTreeElement.Node] = []
        var sets: [(position: Int, node: XMLTreeElement.Node)] = []
        for (setIndex, node) in period.children.enumerated() {
            guard case .element(var set) = node, set.localName == "AdaptationSet" else {
                if sets.isEmpty { leading.append(node) } else { trailing.append(node) }
                continue
            }
            let representations = Set(kept.filter { $0.set == setIndex }.map(\.representation))
            guard !representations.isEmpty else { continue }
            set.children = set.children.enumerated().compactMap { index, child in
                if case .element(let element) = child, element.localName == "Representation",
                    !representations.contains(index)
                {
                    return nil
                }
                return child
            }
            sets.append((kept.firstIndex { $0.set == setIndex } ?? 0, .element(set)))
        }
        period.children = leading + sets.sorted { $0.position < $1.position }.map(\.node) + trailing
        guard Self.expandTimelines(in: &period, timescale: nil, offset: 0, periodDuration: periodDuration) else {
            return nil
        }

        var manifest = root
        // The standard has `static` for a manifest without a type, FFmpeg's demuxer wants it said.
        manifest.setAttribute("type", to: "static")
        var rootChildren = root.children.filter { node in
            if case .element(let element) = node { element.localName != "BaseURL" } else { true }
        }
        let base = XMLTreeElement(name: "BaseURL", children: [.text(absoluteBase)])
        let periodPosition = rootChildren.firstIndex { node in
            if case .element(let element) = node { element.localName == "Period" } else { false }
        }
        rootChildren.insert(.element(base), at: periodPosition ?? rootChildren.endIndex)
        if let position = rootChildren.firstIndex(where: { node in
            if case .element(let element) = node { element.localName == "Period" } else { false }
        }) {
            rootChildren[position] = .element(period)
        }
        manifest.children = rootChildren
        return manifest
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

    /// The pictures are all files the client reads no index of (a WebM file's `Cues`, a file without an index range):
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
    /// `inline` (the resolver's `data:` address).
    package func sounds(inline: (String) -> String) -> [Sound] {
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
                guard let text = text(videoIDs: [], audio: [place]) else { return nil }
                path = inline(text)
            }
            return Sound(path: path, language: language.isEmpty ? nil : language)
        }
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

    // MARK: - Timelines

    /// Gives every `<S r="-1"/>` of the timelines in `element` its repeats: to the next segment that says where it
    /// starts, or to the end of the period. False when that cannot be told (the period's length is unknown).
    private static func expandTimelines(
        in element: inout XMLTreeElement, timescale: Double?, offset: Double, periodDuration: Double?
    ) -> Bool {
        var timescale = timescale
        var offset = offset
        // What a level says of its segments (a template with a timescale) holds for the levels below it, which are
        // its siblings in the manifest: an adaptation set's template for its representations'.
        for child in element.elements where Self.isSegmentInfo(child) {
            timescale = child.attribute("timescale").flatMap { Double($0) } ?? timescale
            offset = child.attribute("presentationTimeOffset").flatMap { Double($0) } ?? offset
        }
        if element.localName == "SegmentTimeline" {
            return expandRepeats(
                in: &element, timescale: timescale ?? 1, offset: offset, periodDuration: periodDuration)
        }
        for index in element.children.indices {
            guard case .element(var child) = element.children[index] else { continue }
            guard expandTimelines(in: &child, timescale: timescale, offset: offset, periodDuration: periodDuration)
            else { return false }
            element.children[index] = .element(child)
        }
        return true
    }

    private static func isSegmentInfo(_ element: XMLTreeElement) -> Bool {
        ["SegmentTemplate", "SegmentBase", "SegmentList"].contains(element.localName)
    }

    private static func expandRepeats(
        in timeline: inout XMLTreeElement, timescale: Double, offset: Double, periodDuration: Double?
    ) -> Bool {
        let positions = timeline.children.indices.filter { index in
            if case .element(let element) = timeline.children[index] { element.localName == "S" } else { false }
        }
        var time = 0.0
        for (n, position) in positions.enumerated() {
            guard case .element(var segment) = timeline.children[position],
                let duration = segment.attribute("d")
                    .flatMap({ Double($0) }), duration > 0
            else { return false }
            if let start = segment.attribute("t").flatMap({ Double($0) }) { time = start }
            var repeats = segment.attribute("r").flatMap { Int($0) } ?? 0
            if repeats < 0 {
                var limit: Double?
                if n + 1 < positions.count, case .element(let next) = timeline.children[positions[n + 1]] {
                    limit = next.attribute("t").flatMap { Double($0) }
                }
                guard let end = limit ?? periodDuration.map({ $0 * timescale + offset }) else { return false }
                repeats = max(0, Int(((end - time) / duration - 1e-6).rounded(.up)) - 1)
                segment.setAttribute("r", to: String(repeats))
                timeline.children[position] = .element(segment)
            }
            time += duration * Double(repeats + 1)
        }
        return true
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
