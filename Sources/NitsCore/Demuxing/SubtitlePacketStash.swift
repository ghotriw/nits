import CFFmpeg
import Foundation

/// The packets of every subtitle stream playback has read, kept so a track chosen later has them at once (as mpv's
/// demuxer cache serves a refresh seek), network sources included, instead of reading them again.
///
/// Reading is in stretches (`Segment`): a seek ends one and starts another where it lands. The packets of picture
/// streams (PGS, VobSub, DVB) share `bitmapByteLimit`, the oldest dropped first; text and ASS take a few hundred
/// kilobytes a film and are kept whole. Closed captions in the video's pictures aren't kept: they would need the video.
struct SubtitlePacketStash {
    /// A packet's reference, owned. Immutable once made, so it may cross threads.
    final class Packet: @unchecked Sendable {
        let packet: UnsafeMutablePointer<AVPacket>
        /// Start on the zero-based timeline, seconds.
        let time: Double

        init?(_ source: UnsafePointer<AVPacket>, time: Double) {
            guard let packet = av_packet_clone(source) else { return nil }
            self.packet = packet
            self.time = time
        }

        deinit {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
        }
    }

    /// The parameters and time base of a stream, in a context of its own, so its packets can be decoded away from the
    /// demuxer's (`EmbeddedSubtitleReader.decode`). Only read once made.
    final class StreamParameters: @unchecked Sendable {
        private var context: UnsafeMutablePointer<AVFormatContext>?
        let stream: UnsafeMutablePointer<AVStream>

        init?(of source: UnsafeMutablePointer<AVStream>) {
            guard let context = avformat_alloc_context() else { return nil }
            self.context = context
            guard let stream = avformat_new_stream(context, nil),
                avcodec_parameters_copy(stream.pointee.codecpar, source.pointee.codecpar) >= 0
            else {
                avformat_free_context(context)
                return nil
            }
            stream.pointee.time_base = source.pointee.time_base
            self.stream = stream
        }

        deinit { avformat_free_context(context) }
    }

    /// What one stream's track had read in one stretch: its packets, and the part of the timeline they cover.
    struct Stretch: Sendable {
        let range: ClosedRange<Double>
        let packets: [Packet]
        /// The stretch playback reads in now, which live packets go on from.
        let isCurrent: Bool
    }

    /// The packets of a track chosen, for `LiveSubtitleTracker.mergeStashed`.
    struct Snapshot: Sendable {
        let parameters: StreamParameters
        let stretches: [Stretch]
    }

    private struct StreamPackets {
        var packets: [Packet] = []
        /// Reading went on past this after packets up to it were dropped (`bitmapByteLimit`).
        var floor: Double?
        /// Positions in the file of the packets kept: a seek's own reads step back (a keyframe search backing off, the
        /// audio read ahead of the landed keyframe), reading packets again, and the ones before them for the first time.
        var positions: Set<Int64> = []
    }

    private struct Segment {
        var start: Double
        /// `nil` while reading goes on in it.
        var end: Double?
        var streams: [Int: StreamPackets] = [:]
    }

    /// How many bytes the packets of all picture streams keep: Blu-ray remuxes carry 10 to 25 PGS tracks of 20 to
    /// 40 MB each. As mpv's `demuxer-max-back-bytes`.
    static let bitmapByteLimit = 64 << 20

    private var segments = [Segment(start: 0)]
    private var bitmapBytes: [Int: Int] = [:]
    /// Picture streams of the file, which share `bitmapByteLimit`; counted at the first packet.
    private var bitmapStreams: Set<Int>?

    /// Keeps a subtitle packet playback read (timestamps already on the zero-based timeline).
    mutating func add(_ pkt: UnsafePointer<AVPacket>, in ctx: UnsafeMutablePointer<AVFormatContext>) {
        let index = Int(pkt.pointee.stream_index)
        guard index >= 0, index < Int(ctx.pointee.nb_streams), let stream = ctx.pointee.streams[index],
            stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE, stream.pointee.time_base.den > 0
        else { return }
        let ticks = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
        guard ticks != Int64.min else { return }
        let timebase = stream.pointee.time_base
        let time = Double(ticks) * Double(timebase.num) / Double(timebase.den)

        let last = segments.count - 1
        let position = pkt.pointee.pos
        let kept = segments[last].streams[index]
        if position >= 0, kept?.positions.contains(position) == true { return }
        // Below what the stretch still covers (packets dropped there, `bitmapByteLimit`): never handed out.
        if let floor = kept?.floor, time < floor { return }
        guard let packet = Packet(pkt, time: time) else { return }
        segments[last].streams[index, default: StreamPackets()].packets.append(packet)
        if position >= 0 { segments[last].streams[index]?.positions.insert(position) }

        let bitmaps = bitmapStreams ?? Self.bitmapStreams(of: ctx)
        bitmapStreams = bitmaps
        guard bitmaps.contains(index) else { return }
        bitmapBytes[index, default: 0] += Int(pkt.pointee.size)
        dropOldest(of: index, keeping: Self.bitmapByteLimit / bitmaps.count)
    }

    private static func bitmapStreams(of ctx: UnsafeMutablePointer<AVFormatContext>) -> Set<Int> {
        Set(
            (0..<Int(ctx.pointee.nb_streams)).filter { index in
                guard let parameters = ctx.pointee.streams[index]?.pointee.codecpar else { return false }
                return parameters.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
                    && BitmapSubtitleDecoder.isBitmapCodec(parameters.pointee.codec_id)
            })
    }

    /// Drops the stream's oldest packets, in reading order, until it keeps `limit` bytes at most. What a stretch keeps
    /// covers the timeline from the latest packet dropped: a seek stepping back reads earlier packets after later
    /// ones.
    private mutating func dropOldest(of index: Int, keeping limit: Int) {
        var bytes = bitmapBytes[index] ?? 0
        for position in segments.indices where bytes > limit {
            guard var stream = segments[position].streams[index], !stream.packets.isEmpty else { continue }
            var dropped = 0
            var latest = stream.floor ?? -.infinity
            while bytes > limit, dropped < stream.packets.count {
                let packet = stream.packets[dropped]
                bytes -= Int(packet.packet.pointee.size)
                latest = max(latest, packet.time)
                dropped += 1
            }
            stream.packets.removeFirst(dropped)
            // Just past it: a window read takes the packet dropped there.
            stream.floor = latest.nextUp
            segments[position].streams[index] = stream
        }
        bitmapBytes[index] = bytes
    }

    /// A seek starts: the stretch being read ends at `readAhead`, how far playback had read, and the seek's own reads
    /// belong to the next one (`startStretch`).
    mutating func endStretch(at readAhead: Double) {
        let last = segments.count - 1
        // A stretch with nothing read in it covers nothing.
        if segments[last].streams.isEmpty, readAhead <= segments[last].start {
            segments.removeLast()
        } else {
            segments[last].end = max(segments[last].start, readAhead)
        }
        segments.append(Segment(start: 0))
    }

    /// A seek landed: reading goes on from `seconds`.
    mutating func startStretch(at seconds: Double) {
        segments[segments.count - 1].start = seconds
    }

    /// Reading in the current stretch starts from `seconds`, later than the seek target (a forward keyframe seek).
    mutating func noteReadsStart(at seconds: Double) {
        let last = segments.count - 1
        if segments[last].end == nil, seconds > segments[last].start { segments[last].start = seconds }
    }

    /// The packets of stream `index` read so far, by stretch, and the stream's parameters to decode them; `readAhead`
    /// ends the current stretch. `nil` when no stretch covers anything.
    func snapshot(of index: Int, in ctx: UnsafeMutablePointer<AVFormatContext>, readAhead: Double) -> Snapshot? {
        guard index >= 0, index < Int(ctx.pointee.nb_streams), let stream = ctx.pointee.streams[index],
            let parameters = StreamParameters(of: stream)
        else { return nil }
        let stretches = segments.compactMap { segment -> Stretch? in
            let packets = segment.streams[index]
            let lower = max(segment.start, packets?.floor ?? segment.start)
            let upper = segment.end ?? readAhead
            guard lower.isFinite, upper > lower else { return nil }
            // Only what the stretch covers: below it lie what is left of a PGS set whose first parts were dropped (a
            // decoder without its composition reads the rest as a clear), and packets a seek read before where it
            // landed. A window read gets them whole. In the file's order, as a decoder needs them (the parts of a PGS
            // set share a time): a seek stepping back keeps packets after ones further on.
            let covered = (packets?.packets ?? []).filter { $0.time >= lower }
            let ordered = covered.enumerated().sorted { lhs, rhs in
                let left = (lhs.element.time, lhs.element.packet.pointee.pos, lhs.offset)
                let right = (rhs.element.time, rhs.element.packet.pointee.pos, rhs.offset)
                return left < right
            }
            return Stretch(range: lower...upper, packets: ordered.map(\.element), isCurrent: segment.end == nil)
        }
        return stretches.isEmpty ? nil : Snapshot(parameters: parameters, stretches: stretches)
    }
}
