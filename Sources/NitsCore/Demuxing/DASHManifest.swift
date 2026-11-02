import Foundation

/// A DASH manifest (MPD) read to be played by FFmpeg's DASH demuxer, and written again for it.
///
/// FFmpeg opens every representation of a manifest as soon as it opens it (seconds, over the network, for a ladder of
/// a dozen), fails the whole opening for one it cannot read (a TTML subtitle track), and plays the first picture it
/// lists, the lowest. It also seeks wrongly in a timeline that repeats a segment "to the end" (`r="-1"`: it lands
/// on the second segment). So the manifest is rewritten before FFmpeg sees it: one picture of the ladder (the others
/// are offered to choose from), the best audio of each language, nothing FFmpeg cannot read, a timeline that
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
    private let audioPlaces: [Place]
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
    package init?(data: Data, url: URL) {
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
        let start = period.attribute("start").flatMap(Self.duration(of:)) ?? 0
        self.periodDuration =
            period.attribute("duration").flatMap(Self.duration(of:))
            ?? root.attribute("mediaPresentationDuration").flatMap(Self.duration(of:)).map { $0 - start }

        var pictures: [(video: Video, place: Place, isKnownCodec: Bool)] = []
        var sounds: [(place: Place, language: String, bandwidth: Int, role: Int, isKnownCodec: Bool)] = []
        var hasProtected = false
        for (setIndex, node) in period.children.enumerated() {
            guard case .element(let set) = node, set.localName == "AdaptationSet", !Self.isTrickMode(set) else {
                continue
            }
            let setKind = Self.kind(of: set)
            for (index, child) in set.children.enumerated() {
                guard case .element(let representation) = child, representation.localName == "Representation" else {
                    continue
                }
                let kind = setKind ?? Self.kind(of: representation)
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
                            Self.roleRank(of: representation, in: set), canDecode == true
                        ))
                    continue
                }
                let family = value("codecs").flatMap(CodecFamily.video)
                let isHDR =
                    family.map(CodecFamily.isDolbyVision) == true
                    || Self.hasHDRTransfer(set) || Self.hasHDRTransfer(representation)
                pictures.append(
                    (
                        Video(
                            id: representation.attribute("id") ?? "\(setIndex).\(index)",
                            width: value("width").flatMap { Int($0) } ?? 0,
                            height: value("height").flatMap { Int($0) } ?? 0,
                            frameRate: value("frameRate").flatMap(Self.frameRate(of:)),
                            codec: family.map(CodecFamily.displayName(ofVideo:)) ?? "", bandwidth: bandwidth,
                            isHDR: isHDR), place, family != nil
                    ))
            }
        }
        self.hasProtectedStreams = hasProtected

        // The best first: a codec told over one that is not; then the larger picture, the HDR one, the higher bitrate.
        pictures.sort { lhs, rhs in
            let (a, b) = (lhs.video, rhs.video)
            if lhs.isKnownCodec != rhs.isKnownCodec { return lhs.isKnownCodec }
            if a.height != b.height { return a.height > b.height }
            if a.width != b.width { return a.width > b.width }
            if a.isHDR != b.isHDR { return a.isHDR }
            return a.bandwidth > b.bandwidth
        }
        // Each is offered; ids kept unique, and one that a second adaptation set lists again (the same size, codec and
        // bitrate) once.
        var seenKeys: Set<String> = []
        var seenIDs: Set<String> = []
        var videos: [Video] = []
        var places: [String: Place] = [:]
        for var picture in pictures {
            let key =
                "\(picture.video.width)x\(picture.video.height)@\(Int((picture.video.frameRate ?? 0).rounded()))"
                + " \(picture.video.codec) \(picture.video.isHDR) \(picture.video.bandwidth)"
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
        self.audioPlaces = languages.compactMap { bestSound[$0]?.place }

        // Written once to know that it can be: a timeline that cannot be made to end is not for FFmpeg to seek in.
        guard videos.isEmpty && audioPlaces.isEmpty || rewritten(videoIDs: videos.prefix(1).map(\.id)) != nil else {
            return nil
        }
    }

    /// The manifest with the picture `videoID` (the best one when nil) and the audio, as the demuxer is given it. Nil
    /// when the picture is none of `videos`.
    package func text(videoID: String? = nil) -> String? {
        guard let rewritten = rewritten(videoIDs: (videoID ?? videos.first?.id).map { [$0] } ?? []) else { return nil }
        return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + rewritten.serialized()
    }

    /// The pictures that can follow the network as one: those of the best one's codec and range (HDR or not), as
    /// the picture changes between them without a new decoder (HLS's ladder, `playlistsOutsideLadder`). The best first.
    /// Fewer than two is no ladder.
    package var ladder: [Video] {
        guard let best = videos.first else { return [] }
        let rungs = videos.filter { $0.codec == best.codec && $0.isHDR == best.isHDR && $0.bandwidth > 0 }
        return rungs.count > 1 ? rungs : []
    }

    /// The manifest with every picture of `ladder` and the audio, for the demuxer to switch between the pictures with
    /// the network (`MediaDemuxer.variants`). It opens every representation at once, so it costs the opening of each;
    /// nil without a ladder.
    package func ladderText() -> String? {
        let rungs = ladder
        guard !rungs.isEmpty, let rewritten = rewritten(videoIDs: rungs.map(\.id)) else { return nil }
        return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + rewritten.serialized()
    }

    private func rewritten(videoIDs: [String]) -> XMLTreeElement? {
        var kept: [Place] = audioPlaces
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
                if case .element(let element) = child, element.localName == "Representation" {
                    return representations.contains(index) ? child : nil
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

    // MARK: - Attributes

    /// "video", "audio", "text"…: the `contentType`, else the first part of the `mimeType`.
    private static func kind(of element: XMLTreeElement) -> String? {
        // Some generators put the content type on a `ContentComponent` of the set instead.
        let contentType =
            element.attribute("contentType")
            ?? element.elements(named: "ContentComponent").lazy.compactMap { $0.attribute("contentType") }.first
        if let contentType { return contentType.lowercased() }
        return element.attribute("mimeType").map { String($0.prefix { $0 != "/" }).lowercased() }
    }

    /// How much a sound is the sound of its language, by the roles of its set and of itself: 2 the main track, 1 one without a role (or a dub, which is the
    /// sound of its own language), 0 a commentary, a description, an alternative, or one with an `Accessibility`
    /// descriptor (audio description): played only when the language has nothing else.
    private static func roleRank(of representation: XMLTreeElement, in set: XMLTreeElement) -> Int {
        // The standard allows both on the set and on the representation.
        let roles = (set.elements(named: "Role") + representation.elements(named: "Role"))
            .compactMap { $0.attribute("value")?.lowercased() }
        if roles.contains("main") { return 2 }
        if !(set.elements(named: "Accessibility") + representation.elements(named: "Accessibility")).isEmpty {
            return 0
        }
        return roles.allSatisfy { $0 == "dub" } ? 1 : 0
    }

    /// An adaptation set of I-frames for fast forward, not a picture to play.
    private static func isTrickMode(_ set: XMLTreeElement) -> Bool {
        (set.elements(named: "EssentialProperty") + set.elements(named: "SupplementalProperty")).contains {
            $0.attribute("schemeIdUri")?.contains("trickmode") == true
        }
    }

    /// PQ or HLG (`TransferCharacteristics` 16 and 18) told by the manifest's properties.
    private static func hasHDRTransfer(_ element: XMLTreeElement) -> Bool {
        (element.elements(named: "EssentialProperty") + element.elements(named: "SupplementalProperty")).contains {
            $0.attribute("schemeIdUri")?.hasSuffix("TransferCharacteristics") == true
                && ["16", "18"].contains($0.attribute("value") ?? "")
        }
    }

    /// "24", "30000/1001".
    private static func frameRate(of text: String) -> Double? {
        let parts = text.split(separator: "/").compactMap { Double($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2 where parts[1] != 0: return parts[0] / parts[1]
        default: return nil
        }
    }

    /// An ISO 8601 duration ("PT0H9M54.00S", "P1DT2H") in seconds; years and months as 365 and 30 days.
    static func duration(of text: String) -> Double? {
        guard text.hasPrefix("P") else { return nil }
        var seconds = 0.0
        var number = ""
        var inTime = false
        for character in text.dropFirst() {
            if character == "T" {
                inTime = true
            } else if character.isNumber || character == "." {
                number.append(character)
            } else {
                guard let value = Double(number) else { return nil }
                number = ""
                switch (character, inTime) {
                case ("Y", false): seconds += value * 365 * 86400
                case ("M", false): seconds += value * 30 * 86400
                case ("W", false): seconds += value * 7 * 86400
                case ("D", false): seconds += value * 86400
                case ("H", true): seconds += value * 3600
                case ("M", true): seconds += value * 60
                case ("S", true): seconds += value
                default: return nil
                }
            }
        }
        return number.isEmpty ? seconds : nil
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
