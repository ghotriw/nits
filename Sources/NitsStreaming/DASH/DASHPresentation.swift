import Foundation
internal import NitsStreaming

/// An MPD read for the client (`DASHPlaylists`): its pictures and sounds with their segments, each placed on the
/// presentation's time. What the client does not play yet is refused with a reason (`DASHPresentationError.unsupported`),
/// which fails the opening (nothing else plays it).
///
/// Read (ISO/IEC 23009-1): one `static` period; `SegmentTemplate` (`$Number$` / `$Time$`, with a `SegmentTimeline` or
/// a `@duration`), `SegmentList` (`SegmentURL`, `mediaRange`) and `SegmentBase` (one MP4 file whose `sidx` tells its
/// segments: `IndexLocation`), inherited from the period and the adaptation set and overridden below; `BaseURL` at every
/// level; `Initialization` and the template's `initialization`. Protected
/// (`ContentProtection`), trick-play, text and image sets are left out.
package struct DASHPresentation: Sendable {
    package struct Segment: Sendable, Equatable {
        package var url: URL
        package var byteRange: HLSByteRange?
        /// Seconds from the period's start (the presentation time less the `presentationTimeOffset`).
        package var start: Double
        package var duration: Double
        /// Its `$Number$`: `startNumber` and its place in the representation.
        package var number: Int
        /// The period it belongs to (a manifest of several: each is a discontinuity of the timeline).
        package var period = 0
        /// Its period's initialization, in a representation of several periods (their inits differ); else the
        /// representation's.
        package var initSection: HLSInitSection?
        /// Silence kept in its place: a period of a sound with none of its own (`merge`). Never requested.
        package var isGap = false
    }

    package struct Representation: Sendable, Equatable {
        package enum Kind: Sendable, Equatable {
            case video
            case audio
        }

        package var id: String
        package var kind: Kind
        /// Bits per second; 0 when the manifest tells none.
        package var bandwidth: Int
        package var codecs: String?
        /// `scte214:supplementalCodecs` (Dolby Vision's on an HDR10 base layer).
        package var supplementalCodecs: String?
        package var width: Int?
        package var height: Int?
        package var frameRate: Double?
        /// PQ or HLG as the manifest's properties tell; nil for neither.
        package var videoRange: HLSVideoRange?
        package var language: String?
        /// `DASHElements.roleRank`.
        package var roleRank: Int
        /// The index of its adaptation set in the period.
        package var set: Int
        package var initSection: HLSInitSection?
        /// The `presentationTimeOffset` in seconds: what its media's timestamps are ahead of the period's time.
        package var presentationTimeOffset: Double
        /// Empty for one file (`index`) until its index is read (`segments(from:of:)`).
        package var segments: [Segment]
        /// Where the index of a representation that is one file is (`SegmentBase`); nil for one of segments.
        package var index: IndexLocation?
        /// Its segments are told by a timeline of a live manifest: the manifest moves the timeline's first entry as it
        /// slides without telling the number it now has, so the source numbers the segments by their times (`LiveNumbers`).
        package var numbersByTime = false
    }

    /// What a dynamic manifest tells besides its segments (ISO/IEC 23009-1 5.3.1.2).
    package struct Live: Sendable, Equatable {
        /// A `UTCTiming` descriptor: how the client learns the server's clock.
        package struct Timing: Sendable, Equatable {
            var scheme: String
            var value: String
        }

        /// `availabilityStartTime`: the zero of the media's availability times.
        var availabilityStart: Date
        /// The period's start, seconds after `availabilityStart`.
        package var periodStart: Double
        /// `minimumUpdatePeriod`: how often the manifest may change; nil, never (a timeline counted by the clock).
        package var minimumUpdatePeriod: Double?
        /// `suggestedPresentationDelay`: how far behind the edge the stream is meant to be played.
        package var suggestedPresentationDelay: Double?
        package var timings: [Timing]
        /// `Location`: where the next manifest is fetched from.
        package var location: URL?
        /// The period's time at the live edge, when read: the server's clock less `availabilityStart` and `periodStart`.
        package var edge: Double
        /// The window the segments were listed for, seconds: the manifest's depth, bounded by `maxHistory`.
        var depth: Double

        /// The date of a segment that starts `seconds` into the period.
        func date(at seconds: Double) -> Date {
            availabilityStart.addingTimeInterval(periodStart + seconds)
        }
    }

    /// How far back a live window reaches at most, seconds (the history a stream may be given, as a day of YouTube's).
    static let maxHistory = 24.0 * 3600

    /// The index of a representation that is one MP4 file (`SegmentBase`): its `indexRange` (or `RepresentationIndex`),
    /// read by the source when the representation's playlist is asked for (dash.js and shaka-player read it then, not
    /// with the manifest).
    package struct IndexLocation: Sendable, Equatable {
        /// The file.
        var media: URL
        /// Where the index is: the file, or a file of its own (`RepresentationIndex@sourceURL`).
        package var url: URL
        package var range: HLSByteRange
        /// The index is a file of its own: its offsets count from the start of the media file.
        package var isExternal: Bool { url != media }
    }

    /// The pictures and sounds, in the manifest's order.
    package var representations: [Representation]
    /// The period's length, when told: the segments an index lists end with it.
    package var periodDuration: Double?
    /// A dynamic manifest's clock and window; nil for a static one.
    package var live: Live?
}

package enum DASHPresentationError: Error, Equatable {
    /// Not an MPD.
    case unreadable
    /// An MPD of what the client does not play yet.
    case unsupported(String)
}

extension DASHPresentation {
    /// The most a manifest read may be, in bytes; a larger one is refused with that reason.
    static let sizeLimit = 8 << 20
    /// The most segments one representation is given: a template counted by `@duration` over a period of years would
    /// list them all.
    static let segmentLimit = 200_000

    /// The presentation `data` holds; `url` is where it came from (after redirects), what its addresses are relative to.
    /// A live manifest of several periods is read as the one that starts at `livePeriodStart` (the one played: a period
    /// told after it, an ad break of server-side insertion, ends it), and refused without one (at the opening).
    package static func parse(
        _ data: Data, url: URL, now: Date? = nil, livePeriodStart: Double? = nil
    ) throws(DASHPresentationError) -> DASHPresentation {
        guard data.count <= sizeLimit else { throw .unsupported("a manifest over \(sizeLimit >> 20) MB") }
        guard let root = XMLTreeElement.parse(data, limit: sizeLimit), root.localName == "MPD" else {
            throw .unreadable
        }
        let type = root.attribute("type") ?? "static"
        guard type == "static" || type == "dynamic" else { throw .unsupported("a \(type) manifest") }
        var periods = root.elements(named: "Period")
        guard !periods.isEmpty else { throw .unsupported("no period") }
        let presentationDuration = root.attribute("mediaPresentationDuration").flatMap(DASHElements.duration(of:))
        if type == "dynamic" && periods.count > 1 && livePeriodStart == nil {
            throw .unsupported("\(periods.count) periods in a live manifest")
        }
        var times = try periodTimes(of: periods, presentationDuration: presentationDuration)
        if type == "dynamic" && periods.count > 1, let livePeriodStart {
            guard let played = times.firstIndex(where: { abs($0.start - livePeriodStart) <= 0.001 }) else {
                throw .unsupported("the period played is no longer in the manifest")
            }
            periods = [periods[played]]
            times = [times[played]]
        }
        let start = times[0].start
        var live: Live?
        if type == "dynamic" {
            guard let now else { throw .unsupported("a dynamic manifest (live)") }
            guard let availabilityStart = root.attribute("availabilityStartTime").flatMap(DASHElements.dateTime(of:))
            else { throw .unsupported("a dynamic manifest without its availabilityStartTime") }
            let depth = min(
                root.attribute("timeShiftBufferDepth").flatMap(DASHElements.duration(of:)) ?? maxHistory, maxHistory)
            live = Live(
                availabilityStart: availabilityStart, periodStart: start,
                minimumUpdatePeriod: root.attribute("minimumUpdatePeriod").flatMap(DASHElements.duration(of:)),
                suggestedPresentationDelay: root.attribute("suggestedPresentationDelay")
                    .flatMap(DASHElements.duration(of:)),
                timings: root.elements(named: "UTCTiming").compactMap { element in
                    guard let scheme = element.attribute("schemeIdUri"), let value = element.attribute("value")
                    else { return nil }
                    return Live.Timing(scheme: scheme, value: value)
                },
                location: root.elements(named: "Location").first.flatMap { URL(string: $0.text, relativeTo: url) }?
                    .absoluteURL,
                edge: now.timeIntervalSince(availabilityStart) - start, depth: max(depth, 0))
        }
        let mpdBase = baseURL(of: root, relativeTo: url)
        var kept = periods
        if periods.count > 1 {
            // A period of no length, or with no set of its own (an ad slot that came out empty), is not played.
            let keep = periods.indices.filter { (times[$0].duration ?? 1) > 0 && hasSets(periods[$0]) }
            kept = keep.map { periods[$0] }
            times = keep.map { times[$0] }
            guard !kept.isEmpty else { throw .unsupported("no period with streams") }
        }
        let reads = kept.enumerated().map { number, period in
            read(
                period: period, base: baseURL(of: period, relativeTo: mpdBase), duration: times[number].duration,
                live: live, isOfSeveral: kept.count > 1)
        }
        let result: PeriodRead =
            kept.count == 1 ? reads[0] : try merge(reads, starts: times.map(\.start), lengths: times.map(\.duration))
        if let reason = result.skippedPictures.first, !result.representations.contains(where: { $0.kind == .video }) {
            throw .unsupported(reason)
        }
        // A picture whose codecs name more than one carries its sound (muxed): that is the sound played then.
        let carriesSound = { (representation: Representation) in
            representation.kind == .audio || (representation.codecs?.contains(",") ?? false)
        }
        if let reason = result.skippedSounds.first, result.representations.contains(where: { $0.kind == .video }),
            !result.representations.contains(where: carriesSound)
        {
            throw .unsupported(reason)
        }
        if result.representations.isEmpty {
            if result.hasProtected { throw .unsupported("its streams are protected (DRM)") }
            if let reason = result.skipped.first { throw .unsupported(reason) }
        } else if !result.skipped.isEmpty {
            StreamingLog.warning("DASH: left out \(result.skipped.joined(separator: "; "))")
        }
        return DASHPresentation(
            representations: result.representations, periodDuration: kept.count == 1 ? times[0].duration : nil,
            live: live)
    }

    /// What one period gave: its representations played, and those left out with the reason.
    private struct PeriodRead {
        package var representations: [Representation] = []
        /// The representations left out, with the reason.
        var skipped: [String] = []
        /// Those of them that are pictures: a manifest of pictures, none played, is not played as its sound alone.
        var skippedPictures: [String] = []
        /// Those that are sounds the build decodes, refused for how they are told: pictures whose every sound is left out
        /// so are not played silent. One with no decoder or no segments would be silent however it is opened.
        var skippedSounds: [String] = []
        var hasProtected = false
        /// It has a set of sound, whatever became of its representations: a period without one is silent.
        var hasSoundSet = false
    }

    private static func hasSets(_ period: XMLTreeElement) -> Bool {
        period.children.contains {
            if case .element(let element) = $0 { return element.localName == "AdaptationSet" }
            return false
        }
    }

    /// Where each period starts on the presentation's time and how long it is (nil for the last of a manifest that does
    /// not tell: its segments end it). A start not told follows the period before. A period lasts up to the next one's
    /// start when that is told (as shaka-player has it: no gap and no overlap between periods, whatever `@duration`
    /// says), else its `@duration`; the last, its `@duration`, else to the manifest's end.
    private static func periodTimes(
        of periods: [XMLTreeElement], presentationDuration: Double?
    ) throws(DASHPresentationError) -> [(start: Double, duration: Double?)] {
        var times: [(start: Double, duration: Double?)] = []
        var next: Double = 0
        for (number, period) in periods.enumerated() {
            let start = period.attribute("start").flatMap(DASHElements.duration(of:)) ?? next
            var duration = period.attribute("duration").flatMap(DASHElements.duration(of:))
            if number + 1 < periods.count {
                if let following = periods[number + 1].attribute("start").flatMap(DASHElements.duration(of:)) {
                    // A period that is followed by one that starts before it is a manifest out of order, not an empty slot.
                    guard following >= start - 0.001 || !hasSets(period) else {
                        throw .unsupported("periods out of order")
                    }
                    duration = following - start
                } else if duration == nil {
                    // An empty period (no set: an ad slot that came out of nothing) takes no time; any other needs its
                    // length.
                    guard !hasSets(period) else { throw .unsupported("a period whose length is not told") }
                    duration = 0
                }
            } else if duration == nil {
                duration = presentationDuration.map { $0 - start }
            }
            times.append((start, duration))
            next = start + (duration ?? 0)
        }
        return times
    }

    /// The representations of one period. In a manifest of several, one that is a file (`SegmentBase`) is left out: its
    /// index is read apart from the manifest and numbered on the period's own.
    private static func read(
        period: XMLTreeElement, base periodBase: URL, duration: Double?, live: Live?, isOfSeveral: Bool
    ) -> PeriodRead {
        var read = PeriodRead()
        var representations: [Representation] = []
        var usedIDs = Set<String>()
        for (setIndex, node) in period.children.enumerated() {
            guard case .element(let set) = node, set.localName == "AdaptationSet" else { continue }
            guard !DASHElements.isTrickMode(set) else { continue }
            let setBase = baseURL(of: set, relativeTo: periodBase)
            for (index, child) in set.children.enumerated() {
                guard case .element(let element) = child, element.localName == "Representation" else { continue }
                let kind = DASHElements.kind(of: set) ?? DASHElements.kind(of: element)
                guard kind == "video" || kind == "audio" else { continue }
                if kind == "audio" { read.hasSoundSet = true }
                guard set.elements(named: "ContentProtection").isEmpty,
                    element.elements(named: "ContentProtection").isEmpty
                else {
                    read.hasProtected = true
                    continue
                }
                let value = { (name: String) in element.attribute(name) ?? set.attribute(name) }
                // As the resolver names it (`DASHElements.uniqueID`).
                let id = DASHElements.uniqueID(of: element, set: setIndex, index: index, used: &usedIDs)
                let bandwidth = element.attribute("bandwidth").flatMap { Int($0) } ?? 0
                let base = baseURL(of: element, relativeTo: setBase)
                let levels = [period, set, element]
                // One the client does not play is left out, not the manifest: it may be one that would never be
                // played (a sound with no decoder, a lesser one of its language).
                var told: Told
                do throws(DASHPresentationError) {
                    // The templates' `$RepresentationID$` is the id the manifest gives, not the unique one that names it.
                    told = try segmentsOf(
                        levels: levels, base: base, id: element.attribute("id") ?? "\(setIndex).\(index)",
                        bandwidth: bandwidth, mimeType: value("mimeType"),
                        periodDuration: duration, live: live)
                    if isOfSeveral && told.index != nil {
                        throw .unsupported("one file (SegmentBase) in a manifest of several periods")
                    }
                } catch {
                    if case .unsupported(let reason) = error {
                        read.skipped.append("\(id): \(reason)")
                        if kind == "video" { read.skippedPictures.append("\(id): \(reason)") }
                        if kind == "audio", value("codecs").flatMap(CodecFamily.canDecodeAudio(in:)) != false {
                            read.skippedSounds.append("\(id): \(reason)")
                        }
                    }
                    continue
                }
                // A live one may have none yet (the stream has not made its first segment, or the clock the manifest is read
                // at is not the server's yet): it lists none until it has.
                guard !told.segments.isEmpty || told.index != nil || live != nil else {
                    read.skipped.append("\(id): no segments")
                    if kind == "video" { read.skippedPictures.append("\(id): no segments") }
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
                        initSection: told.initSection, presentationTimeOffset: told.presentationTimeOffset,
                        segments: told.segments, index: told.index, numbersByTime: told.numbersByTime))
            }
        }
        read.representations = representations
        return read
    }

    /// The codec's family of a representation: a picture's by `CodecFamily`, a sound's the first entry's name. Nil when
    /// it tells none.
    private static func codecFamily(of representation: Representation) -> String? {
        guard let codecs = representation.codecs else { return nil }
        if representation.kind == .video { return CodecFamily.video(in: codecs) }
        return codecs.split(separator: ",").first.map {
            String($0.split(separator: ".").first ?? $0).trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    /// How near two languages are: 0 the same, 1 the same language (`uk` and `uk-UA`), 2 one tells none, 3 apart.
    private static func languageDistance(_ a: String?, _ b: String?) -> Int {
        guard let a = a?.lowercased(), let b = b?.lowercased() else { return a == b ? 0 : 2 }
        if a == b { return 0 }
        return a.split(separator: "-").first == b.split(separator: "-").first ? 1 : 3
    }

    /// The representation of `others` that continues `first` in another period. Of its kind and codec family, as the
    /// client describes a stream by its first run (a decoder made for one codec is not given another's): the one of the
    /// same id (and size, for a picture) if there is; else, as shaka-player does, the nearest: for a sound its language,
    /// then bitrate; for a picture its height, then bitrate. One representation may continue several (an ad's ladder is
    /// shorter than the content's).
    private static func continuation(of first: Representation, in others: [Representation]) -> Representation? {
        let family = codecFamily(of: first)
        let candidates = others.filter { other in
            guard other.kind == first.kind else { return false }
            let otherFamily = codecFamily(of: other)
            return family == nil || otherFamily == nil || family == otherFamily
        }
        let sameSize = { (other: Representation) in
            first.kind == .audio || first.width == nil || other.width == nil
                || (first.width == other.width && first.height == other.height)
        }
        if let same = candidates.first(where: { $0.id == first.id && sameSize($0) }) { return same }
        func distance(_ other: Representation) -> [Int] {
            let rate = abs(other.bandwidth - first.bandwidth)
            if first.kind == .audio { return [languageDistance(first.language, other.language), rate] }
            return [abs((other.height ?? 0) - (first.height ?? 0)), rate]
        }
        return candidates.min { distance($0).lexicographicallyPrecedes(distance($1)) }
    }

    /// The representations that every period has, each as one whose segments run on through the periods: placed on the
    /// presentation's time (`starts`), numbered from 1 across them, each marked with its period (a discontinuity: the
    /// media's timestamps restart there) and its period's initialization. One that a period lacks is left out. The
    /// pictures and sounds of a period must tell one `presentationTimeOffset`, as a manifest's of one period.
    /// A period with no sound set at all (an advertisement's slate) beside others that have some plays silent: the sound's
    /// segments carry it as gaps (`Segment.isGap`, as long as the period, cut as long as the sound's own segments, which
    /// the timeline counts from the start of the period list, so the sound after it, and the film's before an advertisement's,
    /// stay in their places); only after the last period that has sound none are needed. A period whose sound is told but
    /// not played (protected, unsupported) is not silent: the stream is refused as for any sound that does not continue.
    /// The sound's representations are those of the first period that has sound.
    private static func merge(
        _ reads: [PeriodRead], starts: [Double], lengths: [Double?]
    ) throws(DASHPresentationError) -> PeriodRead {
        var merged = PeriodRead()
        for (number, read) in reads.enumerated() {
            merged.skipped += read.skipped.map { "period \(number + 1), \($0)" }
            merged.skippedPictures += read.skippedPictures.map { "period \(number + 1), \($0)" }
            merged.skippedSounds += read.skippedSounds.map { "period \(number + 1), \($0)" }
            merged.hasProtected = merged.hasProtected || read.hasProtected
        }
        let hasSound = { (read: PeriodRead) in read.representations.contains { $0.kind == .audio } }
        let isSilent = { (read: PeriodRead) in !read.hasSoundSet }
        let firstSound = reads.firstIndex(where: hasSound)
        let lastSound = reads.lastIndex(where: hasSound)
        // Each is the period it starts from, and what continues it in every period (nil: a silent period).
        var members: [(from: Int, found: [Representation?])] = []
        for (from, read) in reads.enumerated() {
            for first in read.representations where first.kind == .video ? from == 0 : from == firstSound {
                var found: [Representation?] = Array(repeating: nil, count: from) + [first]
                var isComplete = true
                for number in (from + 1)..<max(reads.count, from + 1) {
                    if let member = continuation(of: first, in: reads[number].representations) {
                        found.append(member)
                    } else if first.kind == .audio && isSilent(reads[number]) {
                        found.append(nil)
                    } else {
                        isComplete = false
                        break
                    }
                }
                // A period before the sound's first that told sound of its own lost it: not silent.
                guard isComplete, reads[..<from].allSatisfy(isSilent) else {
                    let reason = "\(first.id): not in every period"
                    merged.skipped.append(reason)
                    if first.kind == .video { merged.skippedPictures.append(reason) }
                    continue
                }
                members.append((from, found))
            }
        }
        for number in reads.indices {
            let offsets = members.compactMap { $0.found[number]?.presentationTimeOffset }
            if let first = offsets.first, let other = offsets.first(where: { abs($0 - first) > 0.001 }) {
                throw .unsupported(
                    "presentation time offsets that differ in period \(number + 1) (\(first) s, \(other) s)")
            }
        }
        // A film that had sound is not played silent because its periods' sound found no match.
        if firstSound != nil && !members.contains(where: { $0.found.contains { $0?.kind == .audio } }) {
            throw .unsupported("sound that does not continue through every period")
        }
        for (from, found) in members {
            guard var representation = found[from] else { continue }
            representation.initSection = nil
            representation.segments = []
            // Silence is cut as long as the sound's own segments.
            let piece = max(found.compactMap { $0?.segments.map(\.duration).max() }.max() ?? 0, 1)
            let url = found.lazy.compactMap { $0?.segments.first?.url }.first
            for (number, member) in found.enumerated() {
                guard let member else {
                    // After the last period with sound, nothing follows that needs its place kept.
                    guard let url, let length = lengths[number], number < (lastSound ?? 0) else { continue }
                    var done = 0.0
                    while done < length - 0.001 {
                        let duration = min(piece, length - done)
                        representation.segments.append(
                            Segment(
                                url: url, start: starts[number] + done, duration: duration,
                                number: representation.segments.count + 1, period: number, isGap: true))
                        done += duration
                    }
                    continue
                }
                for var segment in member.segments {
                    segment.number = representation.segments.count + 1
                    segment.start += starts[number]
                    segment.period = number
                    segment.initSection = member.initSection
                    representation.segments.append(segment)
                }
            }
            merged.representations.append(representation)
        }
        return merged
    }

    /// The segments of a representation that is one file (`Representation.index`), from its index: each a byte range of
    /// the file, numbered from 1, on the period's time (the index's times less the `presentationTimeOffset`). Those that
    /// start at the period's end or past it are left out and the last ends with it, as for a timeline (shaka-player fits
    /// an index to its period too).
    package static func segments(
        from index: SegmentIndex, of representation: Representation, periodDuration: Double?
    ) -> [Segment] {
        guard let location = representation.index else { return [] }
        let timescale = Double(index.timescale)
        var segments: [Segment] = []
        segments.reserveCapacity(index.segments.count)
        for (position, entry) in index.segments.enumerated() {
            var start = Double(entry.time) / timescale - representation.presentationTimeOffset
            if let periodDuration, start >= periodDuration - 0.001 { break }
            var duration = Double(entry.duration) / timescale
            // Before the period (a `presentationTimeOffset` past the index's start): a segment that ends by its start is
            // left out, one across it is told from it, so that the lengths add up to the period's time.
            if start < 0 {
                guard start + duration > 0.001 else { continue }
                duration += start
                start = 0
            }
            if let periodDuration { duration = min(duration, periodDuration - start) }
            segments.append(
                Segment(
                    url: location.media, byteRange: HLSByteRange(offset: entry.offset, length: entry.size),
                    start: start, duration: duration, number: position + 1))
        }
        return segments
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
        package var timeline: XMLTreeElement?
        var initialization: XMLTreeElement?
        /// `SegmentBase`'s `RepresentationIndex`.
        var representationIndex: XMLTreeElement?
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
                if let index = element.elements(named: "RepresentationIndex").first { representationIndex = index }
                let urls = element.elements(named: "SegmentURL")
                if !urls.isEmpty { segmentURLs = urls }
            }
            guard found else { return nil }
        }

        /// Values that are not counts or times (negative) are taken as not told.
        var timescale: Int64 { attributes["timescale"].flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil } ?? 1 }
        package var presentationTimeOffset: Int64 {
            attributes["presentationTimeOffset"].flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil } ?? 0
        }
        var startNumber: Int {
            attributes["startNumber"].flatMap { Int($0) }.flatMap { (0...numberLimit).contains($0) ? $0 : nil } ?? 1
        }
        package var duration: Int64? { attributes["duration"].flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil } }
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

    /// What a representation's segment information tells: its segments, or for one file where its index is.
    private struct Told {
        package var initSection: HLSInitSection?
        /// Seconds.
        package var presentationTimeOffset: Double
        package var segments: [Segment] = []
        package var index: IndexLocation?
        package var numbersByTime = false
    }

    private static func segmentsOf(
        levels: [XMLTreeElement], base: URL, id: String, bandwidth: Int, mimeType: String?, periodDuration: Double?,
        live: Live?
    ) throws(DASHPresentationError) -> Told {
        switch kindOfInformation(levels: levels) {
        case "SegmentTemplate":
            guard let information = Information("SegmentTemplate", levels: levels) else { break }
            let (initSection, offset, segments) = try templateSegments(
                information, base: base, id: id, bandwidth: bandwidth, periodDuration: periodDuration, live: live)
            return Told(
                initSection: initSection, presentationTimeOffset: offset, segments: segments,
                numbersByTime: live != nil && information.timeline != nil)
        case "SegmentList":
            guard live == nil else { throw .unsupported("a live manifest of a segment list") }
            guard let information = Information("SegmentList", levels: levels) else { break }
            let (initSection, offset, segments) = try listSegments(
                information, base: base, periodDuration: periodDuration)
            return Told(initSection: initSection, presentationTimeOffset: offset, segments: segments)
        case "SegmentBase":
            guard live == nil else { throw .unsupported("a live manifest of one file (SegmentBase)") }
            guard let information = Information("SegmentBase", levels: levels) else { break }
            return try oneFile(information, base: base, mimeType: mimeType)
        default: break
        }
        throw .unsupported("no segments")
    }

    /// A representation that is one file (`SegmentBase`): where its index is, its `indexRange` or a
    /// `RepresentationIndex` (its `range`, and a `sourceURL` for an index in a file of its own, as shaka-player reads
    /// it). Its initialization is its `Initialization`, else the bytes before the index (the `ftyp` and `moov` an MP4
    /// file of this profile starts with; dash.js looks for the `moov` in them). An MP4 file only: a WebM one's index is
    /// its `Cues`, which the client does not read.
    private static func oneFile(
        _ information: Information, base: URL, mimeType: String?
    ) throws(DASHPresentationError) -> Told {
        if let mimeType, mimeType.lowercased().hasSuffix("/webm") {
            throw .unsupported("a WebM file (its index, Cues, is not read)")
        }
        var indexURL = base
        var rangeText = information.attributes["indexRange"]
        if let element = information.representationIndex {
            rangeText = element.attribute("range") ?? rangeText
            if let source = element.attribute("sourceURL") {
                guard let url = URL(string: source, relativeTo: base)?.absoluteURL else {
                    throw .unsupported("an index address it cannot read (\(source))")
                }
                indexURL = url
            }
        }
        guard let rangeText else { throw .unsupported("one file without an index range") }
        guard let range = DASHElements.byteRange(of: rangeText) else {
            throw .unsupported("an index range it cannot read (\(rangeText))")
        }
        guard Int64(range.length) <= SegmentIndex.sizeLimit else {
            throw .unsupported("an index of \(range.length) bytes")
        }
        var initSection = try initSection(information.initialization, base: base)
        if initSection == nil {
            guard indexURL == base, range.offset > 0 else { throw .unsupported("one file without its initialization") }
            initSection = HLSInitSection(url: base, byteRange: HLSByteRange(offset: 0, length: range.offset))
        }
        return Told(
            initSection: initSection,
            presentationTimeOffset: Double(information.presentationTimeOffset) / Double(information.timescale),
            index: IndexLocation(media: base, url: indexURL, range: range))
    }

    // MARK: - Times

    /// A manifest's numbers are its own: what they add up to is checked, and a sum past what a time holds is a manifest
    /// refused, never a trap.
    private static func sum(_ a: Int64, _ b: Int64) throws(DASHPresentationError) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw .unsupported("times past what they are counted in") }
        return value
    }

    private static func product(_ a: Int64, _ b: Int64) throws(DASHPresentationError) -> Int64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw .unsupported("times past what they are counted in") }
        return value
    }

    /// A count of segments the manifest's numbers make (rounded already): one past what a count holds is refused, never
    /// a trap. The bound leaves room to add a segment's number to it.
    private static func segmentCount(_ value: Double) throws(DASHPresentationError) -> Int {
        guard value.isFinite, abs(value) < 4.0e18 else { throw .unsupported("a count of segments past what it holds") }
        return Int(value)
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
        _ timeline: XMLTreeElement, timescale: Int64, end: Int64?, edge: Int64? = nil
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
                        StreamingLog.warning(
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
                    // A live timeline repeats to the edge: the segments that have come whole, not one still being made.
                    limit = [end, edge].compactMap { $0 }.min()
                }
                guard let limit, limit > time else { break }
                let span = try sum(limit, -time)
                let count = try segmentCount(
                    (Double(span) / Double(duration)).rounded(edge != nil && index + 1 == entries.count ? .down : .up))
                guard count >= 1 else { break }
                repeats = count - 1
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
        _ information: Information, base: URL, id: String, bandwidth: Int, periodDuration: Double?, live: Live?
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

        var times: [(time: Int64, duration: Int64)]
        /// The segments the manifest's list (or the clock's count) starts after: a live window slid past them.
        var skipped = 0
        let availabilityOffset = try availabilityOffset(information)
        if let timeline = information.timeline {
            var edge: Int64?
            if let live {
                let ticks = ((live.edge + availabilityOffset) * Double(timescale)).rounded(.down)
                guard ticks.isFinite, abs(ticks) < 9.0e18 else {
                    throw .unsupported("a clock too far from the manifest's")
                }
                edge = try sum(offset, Int64(ticks))
            }
            times = try timelineTimes(timeline, timescale: timescale, end: periodEnd, edge: edge)
            if let live { skipped = trim(&times, timescale: timescale, depth: live.depth) }
        } else if let duration = information.duration, let live {
            (times, skipped) = try liveEvenTimes(
                information, duration: duration, live: live, availabilityOffset: availabilityOffset,
                periodDuration: periodDuration)
        } else if let duration = information.duration {
            guard let periodEnd else { throw .unsupported("a template counted over a period of no length told") }
            var count = try segmentCount((Double(try sum(periodEnd, -offset)) / Double(duration)).rounded(.up))
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
            let number = information.startNumber + skipped + index
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

    /// `availabilityTimeOffset`: seconds a segment is available before its end (low latency's chunked ones). Its
    /// segments are asked for whole, which the server then serves as it makes them. `INF` (every segment always
    /// available) leaves no edge to tell: refused.
    private static func availabilityOffset(_ information: Information) throws(DASHPresentationError) -> Double {
        guard let text = information.attributes["availabilityTimeOffset"] else { return 0 }
        guard let value = Double(text), value.isFinite, value >= 0 else {
            throw .unsupported("an availabilityTimeOffset of \(text)")
        }
        return value
    }

    /// A live template counted by `@duration`: the segments from the window's start to the newest one that has come whole
    /// (its end by the edge, plus `availabilityTimeOffset`), numbered by the clock (`skipped`: those before the first).
    private static func liveEvenTimes(
        _ information: Information, duration: Int64, live: Live, availabilityOffset: Double, periodDuration: Double?
    ) throws(DASHPresentationError) -> (times: [(time: Int64, duration: Int64)], skipped: Int) {
        let length = Double(duration) / Double(information.timescale)
        var edge = live.edge + availabilityOffset
        var last: Int
        if let periodDuration, edge >= periodDuration {
            edge = periodDuration
            last = try segmentCount((periodDuration / length).rounded(.up)) - 1
        } else {
            guard edge.isFinite, abs(edge) < 9.0e12 else { throw .unsupported("a clock too far from the manifest's") }
            last = try segmentCount((edge / length + 1e-6).rounded(.down)) - 1
        }
        if let endNumber = information.attributes["endNumber"].flatMap({ Int($0) }),
            (0...numberLimit).contains(endNumber)
        {
            last = min(last, endNumber - information.startNumber)
        }
        var first = max(0, try segmentCount((max(0, edge - live.depth) / length).rounded(.down)))
        first = max(first, last - segmentLimit + 1)
        guard first <= last else { return ([], 0) }
        let end = try periodEnd(information, periodDuration: periodDuration)
        let offset = information.presentationTimeOffset
        var times: [(time: Int64, duration: Int64)] = []
        times.reserveCapacity(last - first + 1)
        for position in first...last {
            let time = try sum(offset, product(Int64(position), duration))
            var own = duration
            if let end, try sum(time, own) > end { own = max(1, end - time) }
            times.append((time, own))
        }
        return (times, first)
    }

    /// Drops the timeline's segments that ended before its window: `depth` seconds back from the newest one's end.
    /// Returns how many were dropped. A depth past what a time holds in the timescale reaches back past every one.
    private static func trim(_ times: inout [(time: Int64, duration: Int64)], timescale: Int64, depth: Double) -> Int {
        guard let last = times.last else { return 0 }
        let depthTicks = (depth * Double(timescale)).rounded(.down)
        guard depthTicks.isFinite, depthTicks < 9.0e18 else { return 0 }
        // Both are whole and not negative: the difference holds.
        let threshold = last.time + last.duration - Int64(max(0, depthTicks))
        let dropped = times.firstIndex { $0.time + $0.duration > threshold } ?? times.count - 1
        times.removeFirst(dropped)
        return dropped
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
