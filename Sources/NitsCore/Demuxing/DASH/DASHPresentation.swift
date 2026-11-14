import Foundation

/// An MPD read for the client (`DASHPlaylists`): its pictures and sounds with their segments, each placed on the
/// presentation's time. What the client does not play yet is refused with a reason (`DASHPresentationError.unsupported`),
/// which lets the demuxer open the manifest otherwise while FFmpeg's DASH demuxer is still there.
///
/// Read (ISO/IEC 23009-1): one `static` period; `SegmentTemplate` (`$Number$` / `$Time$`, with a `SegmentTimeline` or
/// a `@duration`) and `SegmentList` (`SegmentURL`, `mediaRange`), inherited from the period and the adaptation set and
/// overridden below; `BaseURL` at every level; `Initialization` and the template's `initialization`. Protected
/// (`ContentProtection`), trick-play, text and image sets are left out.
struct DASHPresentation: Sendable {
    struct Segment: Sendable, Equatable {
        var url: URL
        var byteRange: HLSByteRange?
        /// Seconds from the period's start (the presentation time less the `presentationTimeOffset`).
        var start: Double
        var duration: Double
        /// Its `$Number$`: `startNumber` and its place in the representation.
        var number: Int
    }

    struct Representation: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case video
            case audio
        }

        var id: String
        var kind: Kind
        /// Bits per second; 0 when the manifest tells none.
        var bandwidth: Int
        var codecs: String?
        /// `scte214:supplementalCodecs` (Dolby Vision's on an HDR10 base layer).
        var supplementalCodecs: String?
        var width: Int?
        var height: Int?
        var frameRate: Double?
        /// PQ or HLG as the manifest's properties tell; nil for neither.
        var videoRange: HLSVideoRange?
        var language: String?
        /// `DASHElements.roleRank`.
        var roleRank: Int
        /// The index of its adaptation set in the period.
        var set: Int
        var initSection: HLSInitSection?
        /// The `presentationTimeOffset` in seconds: what its media's timestamps are ahead of the period's time.
        var presentationTimeOffset: Double
        var segments: [Segment]
    }

    /// The pictures and sounds, in the manifest's order.
    var representations: [Representation]
}

enum DASHPresentationError: Error, Equatable {
    /// Not an MPD.
    case unreadable
    /// An MPD of what the client does not play yet.
    case unsupported(String)
}

extension DASHPresentation {
    /// The most a manifest read may be, in bytes (as `DASHManifest.sizeLimit`).
    static let sizeLimit = 8 << 20
    /// The most segments one representation is given: a template counted by `@duration` over a period of years would
    /// list them all.
    static let segmentLimit = 200_000

    /// The presentation `data` holds; `url` is where it came from (after redirects), what its addresses are relative to.
    static func parse(_ data: Data, url: URL) throws(DASHPresentationError) -> DASHPresentation {
        guard let root = XMLTreeElement.parse(data, limit: sizeLimit), root.localName == "MPD" else {
            throw .unreadable
        }
        let type = root.attribute("type") ?? "static"
        guard type == "static" else { throw .unsupported("a \(type) manifest (live)") }
        let periods = root.elements(named: "Period")
        guard periods.count == 1, let period = periods.first else {
            throw .unsupported(periods.isEmpty ? "no period" : "\(periods.count) periods")
        }
        let start = period.attribute("start").flatMap(DASHElements.duration(of:)) ?? 0
        let duration =
            period.attribute("duration").flatMap(DASHElements.duration(of:))
            ?? root.attribute("mediaPresentationDuration").flatMap(DASHElements.duration(of:)).map { $0 - start }
        let mpdBase = baseURL(of: root, relativeTo: url)
        let periodBase = baseURL(of: period, relativeTo: mpdBase)

        var representations: [Representation] = []
        /// The representations left out, with the reason.
        var skipped: [String] = []
        var hasProtected = false
        for (setIndex, node) in period.children.enumerated() {
            guard case .element(let set) = node, set.localName == "AdaptationSet" else { continue }
            guard !DASHElements.isTrickMode(set) else { continue }
            let setBase = baseURL(of: set, relativeTo: periodBase)
            for (index, child) in set.children.enumerated() {
                guard case .element(let element) = child, element.localName == "Representation" else { continue }
                let kind = DASHElements.kind(of: set) ?? DASHElements.kind(of: element)
                guard kind == "video" || kind == "audio" else { continue }
                guard set.elements(named: "ContentProtection").isEmpty,
                    element.elements(named: "ContentProtection").isEmpty
                else {
                    hasProtected = true
                    continue
                }
                let value = { (name: String) in element.attribute(name) ?? set.attribute(name) }
                // As the resolver names one without an id (`DASHManifest`): its set and its place in it.
                let id = element.attribute("id") ?? "\(setIndex).\(index)"
                let bandwidth = element.attribute("bandwidth").flatMap { Int($0) } ?? 0
                let base = baseURL(of: element, relativeTo: setBase)
                let levels = [period, set, element]
                // One the client does not play is left out, not the manifest: it may be one that would never be
                // played (a sound with no decoder, a lesser one of its language).
                let initSection: HLSInitSection?
                let offset: Double
                let segments: [Segment]
                do throws(DASHPresentationError) {
                    (initSection, offset, segments) = try segmentsOf(
                        levels: levels, base: base, id: id, bandwidth: bandwidth, periodDuration: duration)
                } catch {
                    if case .unsupported(let reason) = error { skipped.append("\(id): \(reason)") }
                    continue
                }
                guard !segments.isEmpty else {
                    skipped.append("\(id): no segments")
                    continue
                }
                representations.append(
                    Representation(
                        id: id, kind: kind == "video" ? .video : .audio, bandwidth: bandwidth, codecs: value("codecs"),
                        supplementalCodecs: value("scte214:supplementalCodecs"),
                        width: value("width").flatMap { Int($0) }, height: value("height").flatMap { Int($0) },
                        frameRate: value("frameRate").flatMap(DASHElements.frameRate(of:)),
                        videoRange: DASHElements.hdrTransfer(of: element) ?? DASHElements.hdrTransfer(of: set),
                        language: value("lang"),
                        roleRank: DASHElements.roleRank(of: element, in: set), set: setIndex,
                        initSection: initSection, presentationTimeOffset: offset, segments: segments))
            }
        }
        if representations.isEmpty {
            if hasProtected { throw .unsupported("its streams are protected (DRM)") }
            if let reason = skipped.first { throw .unsupported(reason) }
        } else if !skipped.isEmpty {
            AppLog.warning(.demuxer, "DASH: left out \(skipped.joined(separator: "; "))")
        }
        return DASHPresentation(representations: representations)
    }

    // MARK: - Addresses

    /// `element`'s first `BaseURL` resolved against `base`; `base` when it has none.
    private static func baseURL(of element: XMLTreeElement, relativeTo base: URL) -> URL {
        guard let text = element.elements(named: "BaseURL").first?.text, !text.isEmpty,
            let url = URL(string: text, relativeTo: base)?.absoluteURL
        else { return base }
        return url
    }

    /// A template's address (`media`, `initialization`) with its identifiers replaced: `$RepresentationID$`,
    /// `$Bandwidth$`, `$Number$`, `$Time$`, `$$`. The numbers may carry a format (ISO/IEC 23009-1 5.3.9.4.4, as
    /// shaka-player reads it): `%0<width>` and `d`, `i`, `u` (decimal), `o` (octal), `x` / `X` (hexadecimal); the
    /// representation's id takes none. Nil for an identifier it does not know (`$SubNumber$`, low latency's), one with
    /// no value here, or a format it cannot read.
    static func expand(
        _ template: String, id: String, bandwidth: Int, number: Int? = nil, time: Int64? = nil
    ) -> String? {
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "$") {
            result += rest[..<open]
            let tail = rest[rest.index(after: open)...]
            guard let close = tail.firstIndex(of: "$") else { return nil }
            let identifier = tail[..<close]
            rest = tail[tail.index(after: close)...]
            if identifier.isEmpty {
                result += "$"
                continue
            }
            let name = identifier.prefix { $0 != "%" }
            let format = identifier.dropFirst(name.count)
            let value: Int64
            switch name {
            case "RepresentationID":
                guard format.isEmpty else { return nil }
                result += id
                continue
            case "Bandwidth": value = Int64(bandwidth)
            case "Number":
                guard let number else { return nil }
                value = Int64(number)
            case "Time":
                guard let time else { return nil }
                value = time
            default: return nil
            }
            guard let formatted = formatted(value, format: format) else { return nil }
            result += formatted
        }
        return result + rest
    }

    /// `value` as `format` says: "" as it is, "%05d" with zeros to five places, "%08x" in hexadecimal.
    private static func formatted(_ value: Int64, format: Substring) -> String? {
        guard !format.isEmpty else { return String(value) }
        guard format.hasPrefix("%"), let kind = format.last else { return nil }
        let widthText = format.dropFirst().dropLast()
        guard widthText.isEmpty || widthText.hasPrefix("0"), let width = Int(widthText.isEmpty ? "1" : widthText),
            width <= 32
        else { return nil }
        let digits: String
        switch kind {
        case "d", "i", "u": digits = String(value)
        case "o": digits = String(value, radix: 8)
        case "x": digits = String(value, radix: 16)
        case "X": digits = String(value, radix: 16, uppercase: true)
        default: return nil
        }
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    // MARK: - Segments

    /// What one kind of segment information (`SegmentTemplate`, `SegmentList`, `SegmentBase`) says for a representation:
    /// the attributes of every level merged, the lower overriding, and the child elements of the lowest level that has
    /// them.
    private struct Information {
        var attributes: [String: String] = [:]
        var timeline: XMLTreeElement?
        var initialization: XMLTreeElement?
        var segmentURLs: [XMLTreeElement] = []
        /// The levels (0 the period) that told the template's `initialization` and the `Initialization` element: the
        /// lower one is the representation's.
        var initializationAttributeLevel: Int?
        var initializationElementLevel: Int?

        init?(_ name: String, levels: [XMLTreeElement]) {
            var found = false
            for (depth, level) in levels.enumerated() {
                guard let element = level.elements(named: name).first else { continue }
                found = true
                for attribute in element.attributes { attributes[attribute.name] = attribute.value }
                if element.attribute("initialization") != nil { initializationAttributeLevel = depth }
                if let timeline = element.elements(named: "SegmentTimeline").first { self.timeline = timeline }
                if let initialization = element.elements(named: "Initialization").first {
                    self.initialization = initialization
                    initializationElementLevel = depth
                }
                let urls = element.elements(named: "SegmentURL")
                if !urls.isEmpty { segmentURLs = urls }
            }
            guard found else { return nil }
        }

        /// Values that are not counts or times (negative) are taken as not told.
        var timescale: Int64 { attributes["timescale"].flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil } ?? 1 }
        var presentationTimeOffset: Int64 {
            attributes["presentationTimeOffset"].flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil } ?? 0
        }
        var startNumber: Int {
            attributes["startNumber"].flatMap { Int($0) }.flatMap { (0...numberLimit).contains($0) ? $0 : nil } ?? 1
        }
        var duration: Int64? { attributes["duration"].flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil } }
    }

    /// The highest `startNumber` taken: a number past it plus a representation's segments could not be counted.
    static let numberLimit = Int(Int32.max)

    /// The level whose segment information is the representation's: the lowest that has any.
    private static func kindOfInformation(levels: [XMLTreeElement]) -> String? {
        for level in levels.reversed() {
            for name in ["SegmentList", "SegmentTemplate", "SegmentBase"] where !level.elements(named: name).isEmpty {
                return name
            }
        }
        return nil
    }

    private static func segmentsOf(
        levels: [XMLTreeElement], base: URL, id: String, bandwidth: Int, periodDuration: Double?
    ) throws(DASHPresentationError) -> (HLSInitSection?, Double, [Segment]) {
        switch kindOfInformation(levels: levels) {
        case "SegmentTemplate":
            guard let information = Information("SegmentTemplate", levels: levels) else { break }
            return try templateSegments(
                information, base: base, id: id, bandwidth: bandwidth, periodDuration: periodDuration)
        case "SegmentList":
            guard let information = Information("SegmentList", levels: levels) else { break }
            return try listSegments(information, base: base, periodDuration: periodDuration)
        case "SegmentBase":
            throw .unsupported("a representation of one file (SegmentBase)")
        default: break
        }
        throw .unsupported("no segments")
    }

    // MARK: - Times

    /// A manifest's numbers are its own: what they add up to is checked, and a sum past what a time holds is a manifest
    /// refused, never a trap.
    private static func sum(_ a: Int64, _ b: Int64) throws(DASHPresentationError) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw .unsupported("times past what they are counted in") }
        return value
    }

    /// `seconds` in `timescale`'s units.
    private static func ticks(_ seconds: Double, timescale: Int64) throws(DASHPresentationError) -> Int64 {
        let value = (seconds * Double(timescale)).rounded()
        guard value.isFinite, abs(value) < 9.0e18 else { throw .unsupported("a period too long for its timescale") }
        return Int64(value)
    }

    /// Where the period ends, in `information`'s units; nil when its length is not told.
    private static func periodEnd(
        _ information: Information, periodDuration: Double?
    ) throws(DASHPresentationError) -> Int64? {
        guard let periodDuration else { return nil }
        return try sum(information.presentationTimeOffset, ticks(periodDuration, timescale: information.timescale))
    }

    /// `count` segments of `duration` from `start`; the last ends at `end` when it comes first.
    private static func evenTimes(
        count: Int, duration: Int64, from start: Int64, end: Int64?
    ) throws(DASHPresentationError) -> [(time: Int64, duration: Int64)] {
        guard count <= segmentLimit else { throw .unsupported("more than \(segmentLimit) segments") }
        var times: [(time: Int64, duration: Int64)] = []
        times.reserveCapacity(max(0, count))
        var time = start
        for _ in 0..<max(0, count) {
            times.append((time, duration))
            time = try sum(time, duration)
        }
        if let end, let last = times.indices.last, times[last].time < end {
            times[last].duration = min(duration, end - times[last].time)
        }
        return times
    }

    /// The starts and lengths a `SegmentTimeline` lists, in its timescale, read as shaka-player reads them
    /// (`MpdUtils.createTimeline`):
    /// - an `S` without a length is skipped;
    /// - a start that leaves a gap after the segment before it, or overlaps it, moves that segment's end to it (the
    ///   client places a playlist's segments end to end, and each keeps its own start so); one by `gapWarning` or more is
    ///   logged. A start at or before the start of the segment before it is time going back: refused;
    /// - an `r="-1"` repeats up to the next `S`'s start, or to `end` for the last, and the timeline ends with the period; one that cannot be told (the next
    ///   `S` says no start, or one not after its own, or the period's end is not told or already past) ends the timeline
    ///   there.
    private static func timelineTimes(
        _ timeline: XMLTreeElement, timescale: Int64, end: Int64?
    ) throws(DASHPresentationError) -> [(time: Int64, duration: Int64)] {
        let entries = timeline.elements(named: "S")
        var times: [(time: Int64, duration: Int64)] = []
        var time: Int64 = 0
        for (index, entry) in entries.enumerated() {
            guard let duration = entry.attribute("d").flatMap({ Int64($0) }), duration > 0 else { continue }
            if let start = entry.attribute("t").flatMap({ Int64($0) }) {
                guard start >= 0 else { throw .unsupported("a timeline entry before zero") }
                if let last = times.indices.last, start != time {
                    guard start > times[last].time else {
                        throw .unsupported("a timeline that goes back at \(Double(start) / Double(timescale)) s")
                    }
                    if Double(abs(start - time)) / Double(timescale) >= gapWarning {
                        AppLog.warning(
                            .demuxer,
                            "DASH: a timeline with a \(start > time ? "gap" : "overlap") of "
                                + "\(Double(abs(start - time)) / Double(timescale)) s at \(Double(time) / Double(timescale)) s; "
                                + "the segment before it is made to end there")
                    }
                    times[last].duration = start - times[last].time
                }
                time = start
            }
            var repeats = entry.attribute("r").flatMap { Int($0) } ?? 0
            if repeats < 0 {
                let limit: Int64?
                if index + 1 < entries.count {
                    limit = entries[index + 1].attribute("t").flatMap { Int64($0) }
                } else {
                    limit = end
                }
                guard let limit, limit > time else { break }
                let span = try sum(limit, -time)
                repeats = max(0, Int((Double(span) / Double(duration)).rounded(.up)) - 1)
            }
            guard repeats < segmentLimit, times.count + repeats < segmentLimit else {
                throw .unsupported("more than \(segmentLimit) segments")
            }
            for _ in 0...repeats {
                times.append((time, duration))
                time = try sum(time, duration)
            }
        }
        // Nothing past the period's end (shaka-player fits its index to the period too): the segments it lists past it
        // are not served, and the last ends with it. One that would start within a millisecond of the end is none.
        if let end {
            let tolerance = max(1, timescale / 1000)
            while let last = times.last, last.time >= end - tolerance { times.removeLast() }
            if let last = times.indices.last {
                times[last].duration = min(times[last].duration, end - times[last].time)
            }
        }
        return times
    }

    /// A gap or overlap in a timeline as long as this (seconds) is logged (shaka-player's
    /// `GAP_OVERLAP_TOLERANCE_SECONDS`).
    static let gapWarning = 1.0 / 15

    // MARK: - Templates and lists

    private static func templateSegments(
        _ information: Information, base: URL, id: String, bandwidth: Int, periodDuration: Double?
    ) throws(DASHPresentationError) -> (HLSInitSection?, Double, [Segment]) {
        let timescale = information.timescale
        let offset = information.presentationTimeOffset
        let periodEnd = try periodEnd(information, periodDuration: periodDuration)
        guard let media = information.attributes["media"] else {
            throw .unsupported("a template without its media's address")
        }
        let initialization: HLSInitSection?
        // The template's `initialization` or an `Initialization` element, whichever the lower level tells.
        if let text = information.attributes["initialization"],
            (information.initializationAttributeLevel ?? -1) >= (information.initializationElementLevel ?? -1)
        {
            guard let address = expand(text, id: id, bandwidth: bandwidth),
                let url = URL(string: address, relativeTo: base)?.absoluteURL
            else { throw .unsupported("an initialization address it cannot read") }
            initialization = HLSInitSection(url: url)
        } else {
            initialization = try initSection(information.initialization, base: base)
        }

        let times: [(time: Int64, duration: Int64)]
        if let timeline = information.timeline {
            times = try timelineTimes(timeline, timescale: timescale, end: periodEnd)
        } else if let duration = information.duration {
            guard let periodEnd else { throw .unsupported("a template counted over a period of no length told") }
            var count = Int((Double(try sum(periodEnd, -offset)) / Double(duration)).rounded(.up))
            if let endNumber = information.attributes["endNumber"].flatMap({ Int($0) }),
                (0...numberLimit).contains(endNumber)
            {
                count = min(count, endNumber - information.startNumber + 1)
            }
            times = try evenTimes(count: count, duration: duration, from: offset, end: periodEnd)
        } else {
            throw .unsupported("a template without a timeline or a length")
        }

        var segments: [Segment] = []
        segments.reserveCapacity(times.count)
        for (index, entry) in times.enumerated() {
            let number = information.startNumber + index
            guard let address = expand(media, id: id, bandwidth: bandwidth, number: number, time: entry.time),
                let url = URL(string: address, relativeTo: base)?.absoluteURL
            else { throw .unsupported("a media address it cannot read (\(media))") }
            segments.append(
                Segment(
                    url: url, start: Double(entry.time - offset) / Double(timescale),
                    duration: Double(entry.duration) / Double(timescale), number: number))
        }
        return (initialization, Double(offset) / Double(timescale), segments)
    }

    private static func listSegments(
        _ information: Information, base: URL, periodDuration: Double?
    ) throws(DASHPresentationError) -> (HLSInitSection?, Double, [Segment]) {
        let timescale = information.timescale
        let offset = information.presentationTimeOffset
        let periodEnd = try periodEnd(information, periodDuration: periodDuration)
        let urls = information.segmentURLs
        let times: [(time: Int64, duration: Int64)]
        if let timeline = information.timeline {
            times = try timelineTimes(timeline, timescale: timescale, end: periodEnd)
        } else if let duration = information.duration {
            times = try evenTimes(count: urls.count, duration: duration, from: offset, end: periodEnd)
        } else if urls.count == 1, let periodEnd {
            times = [(offset, try sum(periodEnd, -offset))]
        } else {
            throw .unsupported("a segment list without lengths")
        }
        guard times.count >= urls.count else { throw .unsupported("a segment list longer than its timeline") }
        var segments: [Segment] = []
        segments.reserveCapacity(urls.count)
        for (index, element) in urls.enumerated() {
            let url: URL
            if let media = element.attribute("media") {
                guard let resolved = URL(string: media, relativeTo: base)?.absoluteURL else {
                    throw .unsupported("a media address it cannot read (\(media))")
                }
                url = resolved
            } else {
                url = base
            }
            var range: HLSByteRange?
            if let text = element.attribute("mediaRange") {
                guard let parsed = DASHElements.byteRange(of: text) else {
                    throw .unsupported("a media range it cannot read (\(text))")
                }
                range = parsed
            }
            segments.append(
                Segment(
                    url: url, byteRange: range, start: Double(times[index].time - offset) / Double(timescale),
                    duration: Double(times[index].duration) / Double(timescale),
                    number: information.startNumber + index))
        }
        return (try initSection(information.initialization, base: base), Double(offset) / Double(timescale), segments)
    }

    /// An `Initialization` element: its `sourceURL` (the representation's file without one) and its `range`.
    private static func initSection(
        _ element: XMLTreeElement?, base: URL
    ) throws(DASHPresentationError) -> HLSInitSection? {
        guard let element else { return nil }
        var url = base
        if let source = element.attribute("sourceURL") {
            guard let resolved = URL(string: source, relativeTo: base)?.absoluteURL else {
                throw .unsupported("an initialization address it cannot read (\(source))")
            }
            url = resolved
        }
        var range: HLSByteRange?
        if let text = element.attribute("range") {
            guard let parsed = DASHElements.byteRange(of: text) else {
                throw .unsupported("an initialization range it cannot read (\(text))")
            }
            range = parsed
        }
        return HLSInitSection(url: url, byteRange: range)
    }
}
