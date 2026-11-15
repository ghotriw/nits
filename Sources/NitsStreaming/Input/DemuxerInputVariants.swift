import Foundation
internal import NitsStreaming

// What an input and the demuxer tell each other of variants and of the segments being downloaded: the input's side of
// the interface names no demuxer type (`DemuxerInput`).

/// The streams of a variant, by their indices in the input's table.
package struct VariantStreams {
    package let video: Int?
    package let audio: [Int]
    /// Subtitle renditions (`EXT-X-MEDIA` of type `SUBTITLES`): the subtitle streams other variants have too.
    package let subtitles: [Int]
    package let all: [Int]
}

/// A variant as the input groups its streams; see `DemuxerInput.variantCandidates()`.
package struct VariantCandidate {
    package let id: Int
    package let bandwidth: Int
    package let streams: VariantStreams
}

/// How far a variant's streams are described (`DemuxerInput.variantDescription(id:)`).
package enum VariantDescription: Sendable {
    /// By its own read: the table's streams are its.
    case described
    /// As another variant, by what its manifest tells (an HLS rung's `CODECS`, `RESOLUTION`): its first read tells.
    case pending
    /// Its first read found other streams than described: it plays never.
    case rejected
}

/// A segment of a variant that is being downloaded, as the input tells it while the read waits for its bytes
/// (`DemuxerInput.observeSegments`, `pollSegments`).
package struct InFlightSegment: Sendable, Equatable {
    /// The variants the lane belongs to (variants that differ in their audio group share a playlist).
    package let variants: [Int]
    package let sequence: Int
    /// Seconds on the timeline the segment starts at, and how long it is.
    package let start: Double
    package let duration: Double
    package let progress: HTTPSessionInput.Progress
    /// The variant's own lane carries sound (muxed into the picture's segments, as in MPEG-TS), not a rendition.
    package let hasMuxedAudio: Bool
}

/// Why a variant cannot take over a segment whose download was given up (`DemuxerInput.canJoin`).
package enum JoinRefusal: String, Sendable {
    /// The input does not switch variants this way.
    case unsupported = "the input cannot join a segment"
    /// The variant lists no such segment (a live playlist that moved on) or it is a gap.
    case noSegment = "the variant lists no such segment"
    /// The segment starts at an `EXT-X-DISCONTINUITY`: its timestamps restart.
    case atDiscontinuity = "the segment is at a discontinuity"
    /// The next segment is at one: the segment itself is continuous, so this is cautious (kept apart to count it).
    case beforeDiscontinuity = "the segment is just before a discontinuity"
}
