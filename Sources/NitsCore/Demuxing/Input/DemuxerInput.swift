import CFFmpeg
import Foundation

/// What `MediaDemuxer` reads packets from: a container FFmpeg opens and demuxes whole (`FFmpegInput`: a file, a
/// network file, a DASH manifest), or a stream Nits assembles itself. The demuxer keeps what is the same for every input
/// (the queues, the read-ahead, the packet cache, track selection, the splice of a variant switch, subtitles); an input
/// knows its container and its network: how to open, read, seek and select, where its timeline starts and what it tells
/// of variants and of a live window.
///
/// Streams are described as `AVStream`s (parameters, time base, disposition, metadata), which the decoders are made
/// from: an input that demuxes by other means fills its own. The description of a stream stays valid while the input is
/// open; its parameters may be updated behind the demuxer's `lock` (a stream FFmpeg opens later, a DASH representation).
///
/// Behind the demuxer's `lock` (which `MediaDemuxer.lockIO()` takes), but for what is noted. The blocking calls (`read`,
/// the seeks, `closeUnusedRepresentations`) run with `queueLock` released, and give way to the interrupt context the
/// input was made with (`FFmpegInterrupt`).
protocol DemuxerInput: StreamDescriptions {
    // MARK: Description (readable outside `lock`, as track selection reads it; an input may update the
    // duration and add streams as it reads)

    /// "HLS" or "DASH" for an adaptive stream, for the log.
    var streamingName: String { get }
    var traits: DemuxerInputTraits { get }
    /// Seconds; 0 when the container tells none (a live stream, a stream without an index).
    var durationSeconds: Double { get }
    /// Where the zero-based timeline starts, in `AV_TIME_BASE` units of the container's own timestamps: `read` hands out
    /// packets moved by it, and the seeks take targets on the timeline.
    var timelineOrigin: Int64 { get }
    var chapters: [MediaChapter.Raw] { get }
    /// Fonts the container attaches (Matroska), for ASS scripts.
    var attachedFonts: [AssScript.Font] { get }

    /// A stream's title: its `title`, or what the container names it by otherwise (an HLS rendition's `NAME`).
    func title(ofStream index: Int) -> String

    // MARK: Variants and live

    /// The variants of an adaptive stream, as the container groups its streams (an HLS `EXT-X-STREAM-INF`, a DASH
    /// representation of the picture); nil for a single one. The demuxer chooses among them (`adoptVariants`).
    func variantCandidates() -> [MediaDemuxer.VariantCandidate]?
    /// Bits a second the link carried while the input opened, when that is known and tells the start variant
    /// (`adoptVariants`): a DASH ladder read side by side, an HLS master's opening that proves the link slow.
    var openingLinkRate: Double? { get }
    /// A playlist that slides and has no end yet, as opened.
    var isLivePlaylist: Bool { get }
    /// The window of a live playlist as last loaded, on the timeline; nil for other media. Read after `read`, on the
    /// reading thread: the playlist is reloaded inside it.
    func liveWindow() -> LiveWindow?

    // MARK: Network

    /// Read over the network (`MediaURL.isNetworkSource`): a URL, or a saved HLS manifest of network media.
    var isNetworkSource: Bool { get }
    /// What the input's reads transferred, for adaptive bitrate; nil for local media.
    var network: (any NetworkReadAccount)? { get }
    /// The opening is done (`MediaDemuxer.init`, after its scan of the first packets).
    func finishOpening()

    // MARK: Reading

    /// The next packet, with timestamps on the timeline (`timelineOrigin`); FFmpeg's error codes (`AVERROR_EOF` at the
    /// end).
    func read(_ pkt: inout AVPacket) -> Int32
    /// Seeks to `target` (on the timeline, in the time base of `streams.video`, else `streams.audio`) with
    /// `av_seek_frame`'s `flags`, the streams being those read.
    func seek(to target: Int64, flags: Int32, streams: (video: Int, audio: Int)) -> Int32
    /// Seeks stream `index` to `target` (on the timeline, in its time base).
    func seek(stream index: Int, to target: Int64, flags: Int32) -> Int32
    /// Back to the start of the input, for an input that lands between keyframes (`traits.landsBetweenKeyframes`).
    func rewind()
    /// Reads stream `index` or not: the container skips a stream not read where it can (an HLS rendition is not
    /// downloaded).
    func setReading(_ isRead: Bool, stream index: Int)
    /// Before the first seek of a load with variants: closes those not read, where the container opens every one of a
    /// ladder and closes those discarded only once it reads a packet (DASH). Nothing for others. With `queueLock` released.
    func closeUnusedRepresentations()
    /// Before a seek: streams read that the container stopped at their end (DASH) are read again.
    func prepareSeek(reading indices: [Int])

    /// Closes the input. Behind the demuxer's `lock`, once.
    func close()
}

/// What an input's container does that the demuxer reads around.
struct DemuxerInputTraits: Sendable {
    /// The header describes every stream and the index comes from the file (Matroska, MP4): a seek lands on a keyframe,
    /// and a subtitle stream's packets can be found by the index.
    var hasIndex = false
    /// No index, and timestamps that may jump (MPEG-TS / MPEG-PS, an HLS stream of them): a seek bisects and lands on
    /// whatever packet is nearest, mid-GOP, and the demuxer reads on to a keyframe (`syncToVideoKeyframe`).
    var landsBetweenKeyframes = false
    /// The variants interleave by presentation time, not decode time (FFmpeg's DASH demuxer): a switch holds the new
    /// variant's keyframe for the old one's pictures that decode before it (`MediaDemuxer+VariantHold.swift`).
    var interleavesVariantsByPresentation = false
    /// A second demuxer can open the source by its address, as a file (`EmbeddedSubtitleReader`'s reads): not a playlist
    /// the input assembles itself (HLS).
    var opensAsFile = true
}

/// The bytes and requests of an input's network reads (`FFmpegIOByteCounter`), as adaptive bitrate measures them
/// (`MediaDemuxer.noteRead`). Behind the demuxer's `lock`.
protocol NetworkReadAccount: AnyObject {
    /// Bytes read so far over the network.
    var total: Int64 { get }
    /// Seconds spent opening requests (their latency, no transfer).
    var openSeconds: Double { get }
    /// The latest request opened: when it was asked for and answered, with `total` and `openSeconds` then.
    var lastOpen: (asked: ContinuousClock.Instant, opened: ContinuousClock.Instant, total: Int64, openSeconds: Double)?
    {
        get
    }
    /// The transfers of the requests, each measured apart from its answer.
    var transferMeter: NetworkTransferMeter? { get }
}

extension MediaDemuxer {
    /// A variant as the input groups its streams; see `DemuxerInput.variantCandidates()`.
    struct VariantCandidate {
        let id: Int
        let bandwidth: Int
        let streams: VariantStreams
    }
}
