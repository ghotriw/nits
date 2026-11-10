import Foundation

/// An HLS playlist (RFC 8216 and its revision, draft-pantos-hls-rfc8216bis), read from its text: a master playlist,
/// which lists the variants and renditions, or a media playlist, which lists one rendition's segments.
///
/// URIs are resolved against the address the playlist was served from (after redirects), which the reader gives.
/// Read leniently, as players read real playlists: unknown tags and comments are skipped, a variant without a URI line
/// is dropped, values are taken quoted or not, a missing `EXT-X-TARGETDURATION` is taken from the longest segment, an
/// unknown duration (`EXTINF:-1`) is the target's, hints that don't read are skipped. What the timeline or decryption cannot
/// do without (a byte range, a key's URI) fails the read.
///
/// Not read (out of scope): Low-Latency HLS (`EXT-X-PART`, `EXT-X-PRELOAD-HINT`, `EXT-X-SERVER-CONTROL`, `EXT-X-SKIP`),
/// `EXT-X-I-FRAME-STREAM-INF`, `EXT-X-SESSION-DATA`, `EXT-X-CONTENT-STEERING`, `EXT-X-DATERANGE` (interstitials).
enum HLSPlaylist: Sendable, Equatable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)

    /// Reads a playlist served from `url`. `variables` are those a master playlist defined (`HLSMasterPlaylist.variables`),
    /// for a media playlist's `EXT-X-DEFINE:IMPORT`.
    static func parse(_ data: Data, url: URL, variables: [String: String] = [:]) throws(HLSPlaylistError)
        -> HLSPlaylist
    {
        guard let text = String(data: data, encoding: .utf8) else { throw .notText }
        return try parse(text, url: url, variables: variables)
    }

    static func parse(_ text: String, url: URL, variables: [String: String] = [:]) throws(HLSPlaylistError)
        -> HLSPlaylist
    {
        var reader = HLSPlaylistReader(url: url, imported: variables)
        return try reader.read(text)
    }
}

enum HLSPlaylistError: Error, Equatable {
    /// Not UTF-8.
    case notText
    /// The first line is not `#EXTM3U`.
    case notAPlaylist
    /// Tags of both a master and a media playlist.
    case mixedTypes
    /// A tag or URI line the timeline cannot do without, malformed; `line` counts from 1.
    case malformed(line: Int, tag: String)
    /// A `{$name}` no `EXT-X-DEFINE` defined.
    case undefinedVariable(line: Int, name: String)
}

// MARK: - Master playlist

/// The variants and renditions a master (multivariant) playlist lists.
struct HLSMasterPlaylist: Sendable, Equatable {
    var version: Int?
    var variants: [HLSVariant] = []
    var renditions: [HLSRendition] = []
    /// `EXT-X-SESSION-KEY`: keys the media playlists use, to load ahead.
    var sessionKeys: [HLSKey] = []
    /// `EXT-X-INDEPENDENT-SEGMENTS`: every segment of every media playlist decodes without the one before.
    var hasIndependentSegments = false
    var start: HLSStart?
    /// The variables the playlist defined (`EXT-X-DEFINE`), which its media playlists may import.
    var variables: [String: String] = [:]

    /// The renditions of `type` in `group`.
    func renditions(_ type: HLSRendition.Kind, group: String) -> [HLSRendition] {
        renditions.filter { $0.type == type && $0.groupID == group }
    }
}

/// `EXT-X-STREAM-INF`: a variant, the media playlist on the line that follows and the renditions it plays with.
struct HLSVariant: Sendable, Equatable {
    var url: URL
    /// Peak bits a second; 0 when the playlist doesn't tell it.
    var bandwidth: Int
    var averageBandwidth: Int?
    var score: Double?
    /// `CODECS`, as written ("avc1.64001f,mp4a.40.2").
    var codecs: String?
    /// `SUPPLEMENTAL-CODECS` (Dolby Vision over HEVC: "dvh1.08.07/db4h").
    var supplementalCodecs: String?
    var resolution: HLSResolution?
    var frameRate: Double?
    var videoRange: HLSVideoRange?
    var hdcpLevel: String?
    var audioGroup: String?
    var videoGroup: String?
    var subtitlesGroup: String?
    /// `CLOSED-CAPTIONS`: a group, or `NONE` (`""`): none in any variant.
    var closedCaptionsGroup: String?
}

struct HLSResolution: Sendable, Equatable, Hashable {
    var width: Int
    var height: Int
}

enum HLSVideoRange: String, Sendable, Equatable {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
}

/// `EXT-X-MEDIA`: a rendition of a group, which variants name.
struct HLSRendition: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case audio = "AUDIO"
        case video = "VIDEO"
        case subtitles = "SUBTITLES"
        case closedCaptions = "CLOSED-CAPTIONS"
    }

    var type: Kind
    var groupID: String
    var name: String
    /// Its media playlist; nil for one carried in the variant's own segments (and for closed captions).
    var url: URL?
    var language: String?
    var associatedLanguage: String?
    var isDefault = false
    var autoselect = false
    var isForced = false
    /// Closed captions' channel (`CC1`, `SERVICE3`).
    var instreamID: String?
    /// Uniform type identifiers (`public.accessibility.describes-video`).
    var characteristics: [String] = []
    /// `CHANNELS` as written ("6", "16/JOC").
    var channels: String?
}

/// `EXT-X-START`: where to start playing, from the start (`timeOffset` ≥ 0) or the end (< 0) of the playlist.
struct HLSStart: Sendable, Equatable {
    var timeOffset: Double
    var isPrecise = false
}

// MARK: - Media playlist

/// A media playlist: one rendition's segments.
struct HLSMediaPlaylist: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        /// Segments are only added, none removed (a stream recorded as it goes).
        case event = "EVENT"
        /// Finished, never changes.
        case vod = "VOD"
    }

    var version: Int?
    /// Seconds no segment's duration exceeds, rounded: a live playlist is reloaded about as often.
    var targetDuration: Double
    /// The media sequence number of the first segment listed.
    var mediaSequence = 0
    /// The discontinuity sequence number of the first segment listed.
    var discontinuitySequence = 0
    var type: Kind?
    /// `EXT-X-ENDLIST`: no segment will be added.
    var hasEnded = false
    var isIFramesOnly = false
    var hasIndependentSegments = false
    var start: HLSStart?
    var segments: [HLSSegment] = []

    /// A playlist that can still change: live, or an event going on.
    var isLive: Bool { !hasEnded && type != .vod }
    /// The sum of the segments' durations.
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

/// A segment of a media playlist, with what applies to it of the tags before it.
struct HLSSegment: Sendable, Equatable {
    var url: URL
    /// `EXTINF`'s duration, in seconds.
    var duration: Double
    /// The media sequence number.
    var sequence: Int
    /// The discontinuity sequence number: segments of one number make a run whose timestamps continue one another.
    var discontinuitySequence: Int
    /// `EXT-X-DISCONTINUITY` before it: its timestamps, encoding or format need not continue the segment before.
    var isDiscontinuity = false
    var byteRange: HLSByteRange?
    /// `EXT-X-MAP`: the init section its media needs (fragmented MP4's `moov`, a TS's PAT / PMT).
    var initSection: HLSInitSection?
    /// The key it is encrypted with; nil when clear.
    var key: HLSKey?
    /// The date of its first sample: its own `EXT-X-PROGRAM-DATE-TIME`, or the latest one before it plus the durations
    /// between, within a run (none after a discontinuity until a tag gives one).
    var programDateTime: Date?
    /// `EXT-X-GAP`: missing, not to be loaded.
    var isGap = false
    /// `EXT-X-BITRATE`, kilobits a second.
    var bitrate: Int?

    /// The initialization vector of its AES-128 key: the key's own, or its media sequence number as a big-endian
    /// 128-bit integer (RFC 8216 5.2).
    var initializationVector: [UInt8]? {
        guard let key else { return nil }
        if let iv = key.initializationVector { return iv }
        return HLSKey.initializationVector(sequence: sequence)
    }
}

/// `EXT-X-MAP`.
struct HLSInitSection: Sendable, Equatable, Hashable {
    var url: URL
    var byteRange: HLSByteRange?
    /// The key in effect where the tag stands, which the init section is encrypted with (RFC 8216bis 4.4.4.5).
    var key: HLSKey?

    /// The initialization vector of its AES-128 key: the key's own, which the RFC requires; without one, zero, as
    /// hls.js reads it (FFmpeg takes the next segment's number, ExoPlayer refuses the playlist): the same in every
    /// load, so the section is too.
    var initializationVector: [UInt8]? {
        guard let key else { return nil }
        return key.initializationVector ?? HLSKey.initializationVector(sequence: 0)
    }
}

/// `EXT-X-KEY` / `EXT-X-SESSION-KEY`.
struct HLSKey: Sendable, Equatable, Hashable {
    enum Method: Sendable, Equatable, Hashable {
        case aes128
        case sampleAES
        case sampleAESCTR
        case other(String)

        init(_ text: String) {
            switch text {
            case "AES-128": self = .aes128
            case "SAMPLE-AES": self = .sampleAES
            case "SAMPLE-AES-CTR": self = .sampleAESCTR
            default: self = .other(text)
            }
        }
    }

    var method: Method
    var url: URL?
    var initializationVector: [UInt8]?
    /// `identity` when the tag names none.
    var keyFormat = "identity"
    var keyFormatVersions: [Int] = [1]

    /// Whether Nits decrypts it: AES-128 of the whole segment, with a key served as it is.
    var isDecryptable: Bool { method == .aes128 && keyFormat == "identity" && url != nil }

    static func initializationVector(sequence: Int) -> [UInt8] {
        let value = UInt64(truncatingIfNeeded: sequence)
        return [UInt8](repeating: 0, count: 8) + (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

// MARK: - Reading

private struct HLSPlaylistReader {
    let url: URL
    /// A master playlist's variables, which `EXT-X-DEFINE:IMPORT` takes.
    let imported: [String: String]
    var variables: [String: String] = [:]

    var lineNumber = 0
    var sawMasterTag = false
    var sawMediaTag = false

    /// The playlist as read so far: tags of both kinds go to `media` until the end tells which it is (`version`,
    /// `hasIndependentSegments` and `start` are the master's too).
    var master = HLSMasterPlaylist()
    var media = HLSMediaPlaylist(targetDuration: 0)
    var targetDuration: Double?
    var pendingVariant: HLSAttributeList?

    // What applies to the next segment.
    var nextDuration: Double?
    var nextByteRange: (length: Int64, offset: Int64?)?
    var nextIsDiscontinuity = false
    var nextProgramDateTime: Date?
    var nextIsGap = false
    /// A discontinuity before a URI line skipped (no `EXTINF`): the next segment's.
    var carriedDiscontinuity = false
    var discontinuities = 0
    var initSection: HLSInitSection?
    /// The keys in effect, one per `KEYFORMAT`: a key tag replaces the one of its format (RFC 8216 4.3.2.4, as hls.js and
    /// ExoPlayer read it), `METHOD=NONE` all of them.
    var keys: [HLSKey] = []
    var bitrate: Int?

    /// The tags read. Others are skipped unread: variables are not substituted in them, so one undefined there fails
    /// nothing.
    static let readTags: Set<Substring> = [
        "EXT-X-VERSION", "EXT-X-INDEPENDENT-SEGMENTS", "EXT-X-START", "EXT-X-STREAM-INF", "EXT-X-MEDIA",
        "EXT-X-SESSION-KEY", "EXT-X-TARGETDURATION", "EXT-X-MEDIA-SEQUENCE", "EXT-X-DISCONTINUITY-SEQUENCE",
        "EXT-X-PLAYLIST-TYPE", "EXT-X-ENDLIST", "EXT-X-I-FRAMES-ONLY", "EXTINF", "EXT-X-BYTERANGE",
        "EXT-X-DISCONTINUITY", "EXT-X-KEY", "EXT-X-MAP", "EXT-X-PROGRAM-DATE-TIME", "EXT-X-GAP", "EXT-X-BITRATE",
    ]
    /// Tags only a master playlist has, which tell its kind but aren't read.
    static let masterOnlyTags: Set<Substring> = [
        "EXT-X-I-FRAME-STREAM-INF", "EXT-X-SESSION-DATA", "EXT-X-CONTENT-STEERING",
    ]

    init(url: URL, imported: [String: String]) {
        self.url = url
        self.imported = imported
    }

    mutating func read(_ text: String) throws(HLSPlaylistError) -> HLSPlaylist {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        if let first = lines.first, first.hasPrefix("\u{FEFF}") {
            lines[lines.startIndex] = first.dropFirst()
        }
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") else {
            throw .notAPlaylist
        }
        lineNumber = 1
        for raw in lines.dropFirst() {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                guard line.hasPrefix("#EXT") else { continue }
                let name = line.dropFirst().prefix { $0 != ":" }
                if name == "EXT-X-DEFINE" {
                    try define(HLSAttributeList(line.dropFirst("#EXT-X-DEFINE:".count)))
                } else if Self.masterOnlyTags.contains(name) {
                    sawMasterTag = true
                } else if Self.readTags.contains(name) {
                    try tag(substituted(line))
                }
            } else {
                try uriLine(substituted(line))
            }
        }
        if sawMasterTag && sawMediaTag { throw .mixedTypes }
        if sawMasterTag {
            master.version = media.version
            master.hasIndependentSegments = media.hasIndependentSegments
            master.start = media.start
            master.variables = variables
            return .master(master)
        }
        // Segments are numbered here: a server may write the sequence tags after them (FFmpeg reads them anywhere).
        // Never shorter than the longest segment, rounded to the nearest second as the RFC compares them (6.006 under a
        // target of 6), nor than a second: a target of 0 would have a live playlist reloaded in a loop, and missed
        // segments count as nothing.
        let longest = (media.segments.map(\.duration).max() ?? 0).rounded(.toNearestOrAwayFromZero)
        media.targetDuration = max(targetDuration ?? 0, longest, 1)
        for index in media.segments.indices {
            media.segments[index].sequence += media.mediaSequence
            media.segments[index].discontinuitySequence += media.discontinuitySequence
            // A duration unknown (`EXTINF:-1`, as IPTV servers write it): the target's.
            if media.segments[index].duration < 0 { media.segments[index].duration = media.targetDuration }
            // A date the segment's tag doesn't give follows the one before, within a run, now the durations are known.
            if index > 0, media.segments[index].programDateTime == nil, !media.segments[index].isDiscontinuity,
                let date = media.segments[index - 1].programDateTime
            {
                media.segments[index].programDateTime = date.addingTimeInterval(media.segments[index - 1].duration)
            }
        }
        return .media(media)
    }

    // MARK: Variables

    private mutating func define(_ attributes: HLSAttributeList) throws(HLSPlaylistError) {
        if let name = attributes["NAME"], let value = attributes["VALUE"] {
            variables[name] = value
        } else if let name = attributes["IMPORT"] {
            guard let value = imported[name] else { throw .undefinedVariable(line: lineNumber, name: name) }
            variables[name] = value
        } else if let name = attributes["QUERYPARAM"] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
            guard let value = items.first(where: { $0.name == name })?.value else {
                throw .undefinedVariable(line: lineNumber, name: name)
            }
            variables[name] = value
        } else {
            throw .malformed(line: lineNumber, tag: "EXT-X-DEFINE")
        }
    }

    /// `line` with every `{$name}` replaced by its variable's value.
    private func substituted(_ line: String) throws(HLSPlaylistError) -> String {
        guard line.contains("{$") else { return line }
        var result = ""
        var rest = line[...]
        while let open = rest.range(of: "{$") {
            result += rest[..<open.lowerBound]
            let tail = rest[open.upperBound...]
            guard let close = tail.firstIndex(of: "}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let name = String(tail[..<close])
            guard let value = variables[name] else { throw .undefinedVariable(line: lineNumber, name: name) }
            result += value
            rest = tail[tail.index(after: close)...]
        }
        return result + rest
    }

    // MARK: Tags

    private mutating func tag(_ line: String) throws(HLSPlaylistError) {
        let colon = line.firstIndex(of: ":")
        let name = String(line[line.index(after: line.startIndex)..<(colon ?? line.endIndex)])
        let value = colon.map { line[line.index(after: $0)...] } ?? ""
        switch name {
        case "EXT-X-VERSION":
            media.version = Int(value.trimmingCharacters(in: .whitespaces))
        case "EXT-X-INDEPENDENT-SEGMENTS":
            media.hasIndependentSegments = true
        case "EXT-X-START":
            // A hint: one without an offset is skipped.
            let attributes = HLSAttributeList(value)
            if let offset = attributes.float("TIME-OFFSET") {
                media.start = HLSStart(timeOffset: offset, isPrecise: attributes.bool("PRECISE") ?? false)
            }

        // Master playlist.
        case "EXT-X-STREAM-INF":
            sawMasterTag = true
            pendingVariant = HLSAttributeList(value)
        case "EXT-X-MEDIA":
            sawMasterTag = true
            if let rendition = rendition(HLSAttributeList(value)) { master.renditions.append(rendition) }
        case "EXT-X-SESSION-KEY":
            sawMasterTag = true
            // Keys to load ahead, a hint: a malformed one is skipped (the media playlist's own key tag decides).
            if let key = try? key(HLSAttributeList(value), tag: name) { master.sessionKeys.append(key) }

        // Media playlist.
        case "EXT-X-TARGETDURATION":
            sawMediaTag = true
            guard let duration = Double(value.trimmingCharacters(in: .whitespaces)), duration.isFinite, duration >= 0
            else {
                throw .malformed(line: lineNumber, tag: name)
            }
            targetDuration = duration
        case "EXT-X-MEDIA-SEQUENCE":
            sawMediaTag = true
            guard let number = Int(value.trimmingCharacters(in: .whitespaces)),
                (0...HLSPlaylist.largestSequence).contains(number)
            else {
                throw .malformed(line: lineNumber, tag: name)
            }
            media.mediaSequence = number
        case "EXT-X-DISCONTINUITY-SEQUENCE":
            sawMediaTag = true
            guard let number = Int(value.trimmingCharacters(in: .whitespaces)),
                (0...HLSPlaylist.largestSequence).contains(number)
            else {
                throw .malformed(line: lineNumber, tag: name)
            }
            media.discontinuitySequence = number
        case "EXT-X-PLAYLIST-TYPE":
            sawMediaTag = true
            media.type = HLSMediaPlaylist.Kind(rawValue: value.trimmingCharacters(in: .whitespaces))
        case "EXT-X-ENDLIST":
            sawMediaTag = true
            media.hasEnded = true
        case "EXT-X-I-FRAMES-ONLY":
            sawMediaTag = true
            media.isIFramesOnly = true
        case "EXTINF":
            sawMediaTag = true
            // The number the value starts with, as FFmpeg (`atof`), hls.js and ExoPlayer read it: servers write
            // `-1 tvg-id="…"` or `6.0s` before the comma.
            let trimmed = value.drop { $0 == " " || $0 == "\t" }
            let sign = trimmed.prefix { $0 == "-" || $0 == "+" }.prefix(1)
            let number = trimmed.dropFirst(sign.count).prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard let duration = Double(sign + number), duration.isFinite else {
                throw .malformed(line: lineNumber, tag: name)
            }
            // Negative: unknown (`-1`, IPTV servers), the target's once read (FFmpeg plays them).
            nextDuration = duration < 0 ? -1 : duration
        case "EXT-X-BYTERANGE":
            sawMediaTag = true
            guard let range = HLSByteRange.parse(value) else { throw .malformed(line: lineNumber, tag: name) }
            nextByteRange = range
        case "EXT-X-DISCONTINUITY":
            sawMediaTag = true
            nextIsDiscontinuity = true
        case "EXT-X-KEY":
            sawMediaTag = true
            let key = try key(HLSAttributeList(value), tag: name)
            if let key {
                keys.removeAll { $0.keyFormat == key.keyFormat }
                keys.append(key)
            } else {
                keys = []
            }
        case "EXT-X-MAP":
            sawMediaTag = true
            let attributes = HLSAttributeList(value)
            guard let uri = attributes["URI"], let resolved = resolve(uri) else {
                throw .malformed(line: lineNumber, tag: name)
            }
            var range: HLSByteRange?
            if let text = attributes["BYTERANGE"] {
                guard let parsed = HLSByteRange.parse(text),
                    let placed = HLSByteRange(offset: parsed.offset ?? 0, length: parsed.length)
                else { throw .malformed(line: lineNumber, tag: name) }
                range = placed
            }
            initSection = HLSInitSection(
                url: resolved, byteRange: range, key: currentKey)
        case "EXT-X-PROGRAM-DATE-TIME":
            sawMediaTag = true
            // A date that doesn't read is skipped: the date of a segment is a nicety, not its place.
            nextProgramDateTime = HLSPlaylist.date(value.trimmingCharacters(in: .whitespaces))
        case "EXT-X-GAP":
            sawMediaTag = true
            nextIsGap = true
        case "EXT-X-BITRATE":
            sawMediaTag = true
            bitrate = Int(value.trimmingCharacters(in: .whitespaces))
        default:
            break
        }
    }

    /// The key segments are encrypted with: the identity format's (`AES-128`), else the first named (one Nits can't
    /// decrypt, which still marks the segment encrypted).
    private var currentKey: HLSKey? {
        keys.first { $0.keyFormat == "identity" } ?? keys.first
    }

    private func key(_ attributes: HLSAttributeList, tag: String) throws(HLSPlaylistError) -> HLSKey? {
        guard let method = attributes["METHOD"] else { throw .malformed(line: lineNumber, tag: tag) }
        guard method != "NONE" else { return nil }
        var key = HLSKey(method: HLSKey.Method(method))
        // Required for every method but NONE: segments marked encrypted with no key to load would fail unexplained.
        guard let uri = attributes["URI"], let url = resolve(uri) else {
            throw .malformed(line: lineNumber, tag: tag)
        }
        key.url = url
        if attributes["IV"] != nil {
            guard let iv = attributes.hexadecimal("IV"), iv.count <= 16 else {
                throw .malformed(line: lineNumber, tag: tag)
            }
            key.initializationVector = [UInt8](repeating: 0, count: 16 - iv.count) + iv
        }
        if let format = attributes["KEYFORMAT"] { key.keyFormat = format }
        if let versions = attributes["KEYFORMATVERSIONS"] {
            key.keyFormatVersions = versions.split(separator: "/").compactMap { Int($0) }
        }
        return key
    }

    private func rendition(_ attributes: HLSAttributeList) -> HLSRendition? {
        guard let type = attributes["TYPE"].flatMap(HLSRendition.Kind.init(rawValue:)),
            let group = attributes["GROUP-ID"], let name = attributes["NAME"]
        else { return nil }
        var rendition = HLSRendition(type: type, groupID: group, name: name)
        if let uri = attributes["URI"], type != .closedCaptions {
            guard let resolved = resolve(uri) else { return nil }
            rendition.url = resolved
        }
        rendition.language = attributes["LANGUAGE"]
        rendition.associatedLanguage = attributes["ASSOC-LANGUAGE"]
        rendition.isDefault = attributes.bool("DEFAULT") ?? false
        // AUTOSELECT is YES whenever DEFAULT is.
        rendition.autoselect = attributes.bool("AUTOSELECT") ?? false || rendition.isDefault
        rendition.isForced = type == .subtitles && attributes.bool("FORCED") == true
        rendition.instreamID = attributes["INSTREAM-ID"]
        rendition.characteristics =
            attributes["CHARACTERISTICS"]?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? []
        rendition.channels = attributes["CHANNELS"]
        return rendition
    }

    // MARK: URI lines

    private mutating func uriLine(_ line: String) throws(HLSPlaylistError) {
        if let attributes = pendingVariant {
            pendingVariant = nil
            guard let resolved = resolve(line) else { return }
            master.variants.append(variant(attributes, url: resolved))
            return
        }
        // What the tags before a URI line said is for that line only, segment or not; but for a discontinuity, which
        // stands between what came before and what follows a line skipped as much as one read.
        let isDiscontinuity = nextIsDiscontinuity
        defer {
            nextDuration = nil
            nextByteRange = nil
            nextIsDiscontinuity = false
            nextProgramDateTime = nil
            nextIsGap = false
        }
        // A URI without `EXTINF` can't be placed on the timeline: skipped, as FFmpeg skips it.
        guard let duration = nextDuration else {
            carriedDiscontinuity = carriedDiscontinuity || isDiscontinuity
            return
        }
        nextIsDiscontinuity = isDiscontinuity || carriedDiscontinuity
        carriedDiscontinuity = false
        guard let resolved = resolve(line) else { throw .malformed(line: lineNumber, tag: "URI") }
        var range: HLSByteRange?
        if let next = nextByteRange {
            // Without an offset, the range follows the previous segment's in the same resource (else starts it).
            let previous = media.segments.last.flatMap { $0.url == resolved ? $0.byteRange : nil }
            guard
                let placed = HLSByteRange(
                    offset: next.offset ?? previous.map { $0.range.upperBound } ?? 0, length: next.length)
            else { throw .malformed(line: lineNumber, tag: "EXT-X-BYTERANGE") }
            range = placed
        }
        if nextIsDiscontinuity { discontinuities += 1 }
        media.segments.append(
            HLSSegment(
                // Relative to the sequence tags, which the end of the read adds.
                url: resolved, duration: duration, sequence: media.segments.count,
                discontinuitySequence: discontinuities,
                isDiscontinuity: nextIsDiscontinuity, byteRange: range, initSection: initSection, key: currentKey,
                programDateTime: nextProgramDateTime, isGap: nextIsGap, bitrate: range == nil ? bitrate : nil))
    }

    private func variant(_ attributes: HLSAttributeList, url: URL) -> HLSVariant {
        // `NONE` unquoted is the enumerated value; quoted, a group of that name.
        let closedCaptions = attributes["CLOSED-CAPTIONS"].map { value in
            value == "NONE" && !attributes.isQuoted("CLOSED-CAPTIONS") ? "" : value
        }
        return HLSVariant(
            url: url, bandwidth: attributes.integer("BANDWIDTH") ?? 0,
            averageBandwidth: attributes.integer("AVERAGE-BANDWIDTH"), score: attributes.float("SCORE"),
            codecs: attributes["CODECS"], supplementalCodecs: attributes["SUPPLEMENTAL-CODECS"],
            resolution: attributes.resolution("RESOLUTION"),
            frameRate: attributes.float("FRAME-RATE"),
            videoRange: attributes["VIDEO-RANGE"].flatMap(HLSVideoRange.init(rawValue:)),
            hdcpLevel: attributes["HDCP-LEVEL"], audioGroup: attributes["AUDIO"],
            videoGroup: attributes["VIDEO"], subtitlesGroup: attributes["SUBTITLES"],
            closedCaptionsGroup: closedCaptions)
    }

    private func resolve(_ uri: String) -> URL? {
        URL(string: uri, relativeTo: url)?.absoluteURL
    }
}

// MARK: - Limits

extension HLSPlaylist {
    /// The largest media or discontinuity sequence number read (2^53): a larger one is malformed, and numbers stay far
    /// from overflowing as segments are counted on.
    static let largestSequence = 1 << 53
}

// MARK: - Dates

extension HLSPlaylist {
    private static let dateWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let dateWithoutFraction = Date.ISO8601FormatStyle()

    /// An ISO 8601 date with a time zone, with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: dateWithFraction)) ?? (try? Date(text, strategy: dateWithoutFraction))
    }
}
