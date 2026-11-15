import Foundation

/// The playlists the client plays, in the model of an HLS playlist (RFC 8216 and its revision, draft-pantos-hls-rfc8216bis; a DASH manifest is told in it too, `DASHPlaylists`): a multivariant playlist,
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
package enum StreamingPlaylist: Sendable, Equatable {
    case multivariant(MultivariantPlaylist)
    case media(MediaPlaylist)

    /// Reads a playlist served from `url`. `variables` are those a multivariant playlist defined (`MultivariantPlaylist.variables`),
    /// for a media playlist's `EXT-X-DEFINE:IMPORT`.
    package static func parse(_ data: Data, url: URL, variables: [String: String] = [:]) throws(HLSPlaylistError)
        -> StreamingPlaylist
    {
        guard let text = String(data: data, encoding: .utf8) else { throw .notText }
        return try parse(text, url: url, variables: variables)
    }

    package static func parse(_ text: String, url: URL, variables: [String: String] = [:]) throws(HLSPlaylistError)
        -> StreamingPlaylist
    {
        var reader = HLSPlaylistReader(url: url, imported: variables)
        return try reader.read(text)
    }
}

package enum HLSPlaylistError: Error, Equatable {
    /// Not UTF-8.
    case notText
    /// The first line is not `#EXTM3U`.
    case notAPlaylist
    /// Tags of both a multivariant and a media playlist.
    case mixedTypes
    /// A tag or URI line the timeline cannot do without, malformed; `line` counts from 1.
    case malformed(line: Int, tag: String)
    /// A `{$name}` no `EXT-X-DEFINE` defined.
    case undefinedVariable(line: Int, name: String)
}

// MARK: - Multivariant playlist

/// The variants and renditions a multivariant playlist lists (what HLS used to call a master playlist).
package struct MultivariantPlaylist: Sendable, Equatable {
    var version: Int?
    package var variants: [PlaylistVariant] = []
    var renditions: [PlaylistRendition] = []
    /// `EXT-X-SESSION-KEY`: keys the media playlists use, to load ahead.
    var sessionKeys: [HLSKey] = []
    /// `EXT-X-INDEPENDENT-SEGMENTS`: every segment of every media playlist decodes without the one before.
    var hasIndependentSegments = false
    package var start: HLSStart?
    /// The variables the playlist defined (`EXT-X-DEFINE`), which its media playlists may import.
    package var variables: [String: String] = [:]

    /// The renditions of `type` in `group`.
    func renditions(_ type: PlaylistRendition.Kind, group: String) -> [PlaylistRendition] {
        renditions.filter { $0.type == type && $0.groupID == group }
    }
}

/// `EXT-X-STREAM-INF`: a variant, the media playlist on the line that follows and the renditions it plays with.
package struct PlaylistVariant: Sendable, Equatable {
    package var url: URL
    /// Peak bits a second; 0 when the playlist doesn't tell it.
    package var bandwidth: Int
    var averageBandwidth: Int?
    var score: Double?
    /// `CODECS`, as written ("avc1.64001f,mp4a.40.2").
    package var codecs: String?
    /// `SUPPLEMENTAL-CODECS` (Dolby Vision over HEVC: "dvh1.08.07/db4h").
    package var supplementalCodecs: String?
    var resolution: VideoResolution?
    package var frameRate: Double?
    package var videoRange: VideoRange?
    var hdcpLevel: String?
    var audioGroup: String?
    var videoGroup: String?
    var subtitlesGroup: String?
    /// `CLOSED-CAPTIONS`: a group, or `NONE` (`""`): none in any variant.
    var closedCaptionsGroup: String?
}

package struct VideoResolution: Sendable, Equatable, Hashable {
    package var width: Int
    package var height: Int
}

package enum VideoRange: String, Sendable, Equatable {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
}

/// `EXT-X-MEDIA`: a rendition of a group, which variants name.
package struct PlaylistRendition: Sendable, Equatable {
    package enum Kind: String, Sendable, Equatable {
        case audio = "AUDIO"
        case video = "VIDEO"
        case subtitles = "SUBTITLES"
        case closedCaptions = "CLOSED-CAPTIONS"
    }

    package var type: Kind
    var groupID: String
    var name: String
    /// Its media playlist; nil for one carried in the variant's own segments (and for closed captions).
    package var url: URL?
    package var language: String?
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
package struct HLSStart: Sendable, Equatable {
    var timeOffset: Double
    var isPrecise = false
}

// MARK: - Media playlist

/// A media playlist: one rendition's segments.
package struct MediaPlaylist: Sendable, Equatable {
    package enum Kind: String, Sendable, Equatable {
        /// Segments are only added, none removed (a stream recorded as it goes).
        case event = "EVENT"
        /// Finished, never changes.
        case vod = "VOD"
    }

    var version: Int?
    /// Seconds no segment's duration exceeds, rounded: a live playlist is reloaded about as often.
    var targetDuration: Double
    /// The media sequence number of the first segment listed.
    package var mediaSequence = 0
    /// The discontinuity sequence number of the first segment listed.
    var discontinuitySequence = 0
    /// The playlist says its discontinuity sequence (`EXT-X-DISCONTINUITY-SEQUENCE`): its numbers are the stream's, which
    /// every playlist of it shares (RFC 8216 6.2.4), not counted from what this playlist lists.
    var declaresDiscontinuitySequence = false
    package var type: Kind?
    /// `EXT-X-ENDLIST`: no segment will be added.
    package var hasEnded = false
    var isIFramesOnly = false
    var hasIndependentSegments = false
    package var start: HLSStart?
    /// How far behind the live edge the stream is meant to be played, seconds, when its source says (DASH's
    /// `suggestedPresentationDelay`; HLS's `HOLD-BACK` could fill it). Nil: the client's own margin.
    var holdBack: Double?
    /// How often the source says its playlist may change (DASH's `minimumUpdatePeriod`), seconds: a playlist is not taken
    /// as stuck before this has passed, however short its segments are. Nil: the target duration.
    package var updatePeriod: Double?
    package var segments: [MediaSegment] = []
    /// The numbers of its segments are its own (consecutive, as every playlist's), not the ladder's: a DASH picture whose
    /// segments do not start where its ladder's best picture's do. The number of one of its segments is no place in another
    /// variant's, nor theirs in it (`StreamingInput.canJoin`); a switch by time (`StreamingLane.catchUp`) is the same.
    package var hasOwnNumbers = false

    /// A playlist that can still change: live, or an event going on.
    var isLive: Bool { !hasEnded && type != .vod }
    /// The sum of the segments' durations.
    package var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

/// A segment of a media playlist, with what applies to it of the tags before it.
package struct MediaSegment: Sendable, Equatable {
    package var url: URL
    /// `EXTINF`'s duration, in seconds.
    package var duration: Double
    /// The media sequence number.
    package var sequence: Int
    /// The discontinuity sequence number: segments of one number make a run whose timestamps continue one another.
    var discontinuitySequence: Int
    /// `EXT-X-DISCONTINUITY` before it: its timestamps, encoding or format need not continue the segment before.
    var isDiscontinuity = false
    package var byteRange: ByteRange?
    /// `EXT-X-MAP`: the init section its media needs (fragmented MP4's `moov`, a TS's PAT / PMT).
    package var initSection: InitSection?
    /// The key it is encrypted with; nil when clear.
    var key: HLSKey?
    /// The date of its first sample: its own `EXT-X-PROGRAM-DATE-TIME`, or the latest one before it plus the durations
    /// between, within a run (none after a discontinuity until a tag gives one).
    var programDateTime: Date?
    /// `EXT-X-GAP`: missing, not to be loaded.
    package var isGap = false
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
package struct InitSection: Sendable, Equatable, Hashable {
    package var url: URL
    package var byteRange: ByteRange?
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
package struct HLSKey: Sendable, Equatable, Hashable {
    package enum Method: Sendable, Equatable, Hashable {
        case aes128
        case sampleAES
        case sampleAESCTR
        case other(String)

        package init(_ text: String) {
            switch text {
            case "AES-128": self = .aes128
            case "SAMPLE-AES": self = .sampleAES
            case "SAMPLE-AES-CTR": self = .sampleAESCTR
            default: self = .other(text)
            }
        }
    }

    var method: Method
    package var url: URL?
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
