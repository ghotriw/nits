import CFFmpeg
import Foundation

/// Subtitle packets as cues, pictures and ASS events, and reads of a subtitle stream (whole, or around a time) from a
/// secondary demuxer that never disturbs playback.
enum EmbeddedSubtitleReader {
    /// The bitmap subtitle streams of a subtitle file: one for a `.sup`, one per language for a VobSub `.idx`.
    static func bitmapSubtitleStreams(of url: URL) -> [(index: Int, language: String)] {
        var tempCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        // The streams of a .sup and of a VobSub index exist once the header is read; probing would read pictures too.
        guard avformat_open_input(&tempCtx, url.path, nil, nil) == 0, let ctx = tempCtx else { return [] }
        defer { avformat_close_input(&tempCtx) }
        return (0..<Int(ctx.pointee.nb_streams)).compactMap { index in
            guard let stream = ctx.pointee.streams[index], let parameters = stream.pointee.codecpar,
                BitmapSubtitleDecoder.isBitmapCodec(parameters.pointee.codec_id)
            else { return nil }
            let language = av_dict_get(stream.pointee.metadata, "language", nil, 0).map {
                String(cString: $0.pointee.value)
            }
            return (index, language ?? "")
        }
    }

    /// How long a cue whose packet carries no duration stays on screen.
    static let fallbackCueDuration = 4.0

    /// What the packets of one subtitle stream decoded to, before they become a track's document or join what
    /// playback collects (`MediaDemuxer.mergeLiveSubtitles`).
    struct Packets: Sendable {
        var cues: [SubtitleCue] = []
        /// Bitmap sets in read order; applied in that order, they end the sets they replace.
        var bitmapOutputs: [BitmapSubtitleDecoder.Output] = []
        var assEvents: [AssScript.Event] = []
    }

    /// Turns the packets of one subtitle stream into `Packets`.
    private struct PacketCollector {
        let streamIndex: Int
        let codecId: AVCodecID
        let timebase: AVRational
        let bitmapDecoder: BitmapSubtitleDecoder?
        var packets = Packets()

        /// `nil` for a bitmap stream FFmpeg has no decoder for.
        init?(stream: UnsafeMutablePointer<AVStream>, index: Int) {
            streamIndex = index
            codecId = stream.pointee.codecpar.pointee.codec_id
            timebase = stream.pointee.time_base
            bitmapDecoder = BitmapSubtitleDecoder.isBitmapCodec(codecId) ? BitmapSubtitleDecoder(stream: stream) : nil
            if BitmapSubtitleDecoder.isBitmapCodec(codecId), bitmapDecoder == nil { return nil }
        }

        mutating func add(_ pkt: inout AVPacket) {
            guard pkt.stream_index == streamIndex else { return }
            if let bitmapDecoder {
                packets.bitmapOutputs.append(bitmapDecoder.decode(&pkt))
                return
            }
            if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA,
                let event = EmbeddedSubtitleReader.assEvent(from: &pkt, timebase: timebase)
            {
                packets.assEvents.append(event)
            }
            if let cue = EmbeddedSubtitleReader.parseSubtitleCue(
                pkt: &pkt, timebase: timebase, codecId: codecId, cueIndex: packets.cues.count)
            {
                packets.cues.append(cue)
            }
        }
    }

    /// A secondary demuxer of the file, probed. `interrupt` aborts its I/O, blocking reads included (a stalled network
    /// volume); it must outlive the context.
    private static func openInput(url: String, headers: [String: String], interrupt: FFmpegInterrupt?)
        -> UnsafeMutablePointer<AVFormatContext>?
    {
        var options: OpaquePointer? = nil
        defer { if options != nil { av_dict_free(&options) } }
        if MediaURL.isNetworkURL(url) {
            MediaURL.applyNetworkOptions(&options, headers: headers)
        } else {
            for (k, v) in headers {
                av_dict_set(&options, k, v, 0)
            }
        }

        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = ctx else { return nil }
        interrupt?.install(on: allocated)
        guard avformat_open_input(&ctx, url, nil, &options) == 0, let opened = ctx else { return nil }
        guard avformat_find_stream_info(opened, nil) >= 0 else {
            avformat_close_input(&ctx)
            return nil
        }
        return opened
    }

    /// Discards every stream but `kept`, so FFmpeg returns (and, for MPEG-TS, parses) only their packets. Matroska
    /// still reads every block from the file.
    private static func discardStreams(of ctx: UnsafeMutablePointer<AVFormatContext>, except kept: Set<Int>) {
        for index in 0..<Int(ctx.pointee.nb_streams) where !kept.contains(index) {
            ctx.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }
    }

    private static func isCancelled(_ interrupt: FFmpegInterrupt?) -> Bool {
        Task.isCancelled || interrupt?.isCancelled == true
    }

    /// The whole of one subtitle stream of a file: for external bitmap files (`.sup`, `.idx`), small and made of
    /// nothing else. Embedded tracks of media come from the packets playback reads instead (see `readSubtitles`):
    /// reading a whole film for them means every byte of it, as Matroska ignores discarded streams.
    ///
    /// `interrupt` aborts the read; a cancelled or interrupted read returns `nil`, never part of a track.
    static func extractEmbeddedSubtitles(
        url: String, headers: [String: String], streamIndex: Int, interrupt: FFmpegInterrupt? = nil
    ) -> SubtitleDocument? {
        guard let ctx = openInput(url: url, headers: headers, interrupt: interrupt) else { return nil }
        var closable: UnsafeMutablePointer<AVFormatContext>? = ctx
        defer { avformat_close_input(&closable) }
        guard streamIndex < Int(ctx.pointee.nb_streams), let stream = ctx.pointee.streams[streamIndex],
            stream.pointee.time_base.den > 0, var collector = PacketCollector(stream: stream, index: streamIndex)
        else { return nil }
        discardStreams(of: ctx, except: [streamIndex])

        var pkt = AVPacket()
        let origin = MediaDemuxer.timelineOrigin(of: ctx)
        while !isCancelled(interrupt) && av_read_frame(ctx, &pkt) >= 0 {
            MediaDemuxer.rebase(&pkt, origin: origin, in: ctx)
            collector.add(&pkt)
            av_packet_unref(&pkt)
        }
        if isCancelled(interrupt) { return nil }

        var imageCues: [SubtitleImageCue] = []
        for output in collector.packets.bitmapOutputs { imageCues.apply(output) }
        let isASS = collector.codecId == AV_CODEC_ID_ASS || collector.codecId == AV_CODEC_ID_SSA
        let script =
            isASS
            ? AssScript(
                header: assHeader(of: stream), events: collector.packets.assEvents, fonts: attachedFonts(in: ctx))
            : nil
        return SubtitleDocument(cues: collector.packets.cues, imageCues: imageCues, assScript: script)
    }

    /// How far before a time a window read starts: a cue on screen then may have started that long before (mpv's
    /// Matroska subtitle preroll reads up to as much when the index says a cue overlaps).
    static let windowPreroll = 10.0
    /// How far past the time a window read goes when the track is due ahead of everything playback has read (a negative
    /// subtitle delay): the next read is that much later, not one per time tick.
    static let windowLookahead = 10.0

    /// The packets of one subtitle stream within `range` of the timeline (`upperBound` may be `infinity`: to the end).
    ///
    /// Playback collects a track as it reads (`MediaDemuxer.processSubtitlePacket`), from where it reads on; this
    /// fills in what it can't (`MediaDemuxer.subtitleWindow`): the cue on screen when a track is chosen or a seek
    /// lands, as mpv's refresh seek and subtitle preroll do, and what playback read before the track was chosen. A
    /// picture or sound stream tells the time, so the read stops at the range's end. `nil` when the file can't be read
    /// there, or the read was cancelled.
    static func readSubtitles(
        url: String, headers: [String: String], streamIndex: Int, in range: ClosedRange<Double>,
        interrupt: FFmpegInterrupt? = nil
    ) -> Packets? {
        guard let ctx = openInput(url: url, headers: headers, interrupt: interrupt) else { return nil }
        var closable: UnsafeMutablePointer<AVFormatContext>? = ctx
        defer { avformat_close_input(&closable) }
        guard streamIndex < Int(ctx.pointee.nb_streams), let stream = ctx.pointee.streams[streamIndex],
            stream.pointee.time_base.den > 0, var collector = PacketCollector(stream: stream, index: streamIndex)
        else { return nil }

        // A file with no picture or sound is a subtitle file: small, read to its end.
        let reference = referenceStream(of: ctx)
        discardStreams(of: ctx, except: reference.map { [streamIndex, $0] } ?? [streamIndex])

        let origin = MediaDemuxer.timelineOrigin(of: ctx)
        // A context just opened is at the start already. A timestamp seek to it could skip the first packets of an
        // MPEG-TS / MPEG-PS stream, or fail before its first timestamp.
        if range.lowerBound > 0 {
            let target = Int64(range.lowerBound * Double(AV_TIME_BASE)) + origin
            guard av_seek_frame(ctx, -1, target, AVSEEK_FLAG_BACKWARD) >= 0 else { return nil }
        }

        let referenceTimebase = reference.flatMap { ctx.pointee.streams[$0]?.pointee.time_base }
        var pkt = AVPacket()
        while !isCancelled(interrupt) && av_read_frame(ctx, &pkt) >= 0 {
            MediaDemuxer.rebase(&pkt, origin: origin, in: ctx)
            defer { av_packet_unref(&pkt) }
            if let reference, Int(pkt.stream_index) == reference {
                // Decode order: presentation times jump back and forth with B-frames, decode times don't. A subtitle
                // packet is muxed by its own time, so one due just before the end may come after a later picture.
                guard let timebase = referenceTimebase, timebase.den > 0 else { continue }
                let ticks = pkt.dts != Int64.min ? pkt.dts : pkt.pts
                let seconds = Double(ticks) * Double(timebase.num) / Double(timebase.den)
                if ticks != Int64.min, seconds > range.upperBound + windowStopMargin { break }
                continue
            }
            collector.add(&pkt)
        }
        return isCancelled(interrupt) ? nil : collector.packets
    }

    /// How far past a window's end its read goes, by the decode time of the picture or sound followed: packets due
    /// just before the end may be muxed a little after it.
    static let windowStopMargin = 0.5

    /// The stream whose timestamps tell how far a read has come: the first picture stream that isn't cover art (a
    /// cover is one packet at 0, and a read would never pass the range's end), else the first sound stream.
    private static func referenceStream(of ctx: UnsafeMutablePointer<AVFormatContext>) -> Int? {
        func first(_ type: AVMediaType) -> Int? {
            (0..<Int(ctx.pointee.nb_streams)).first { index in
                guard let stream = ctx.pointee.streams[index], stream.pointee.codecpar.pointee.codec_type == type
                else { return false }
                return stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0
            }
        }
        return first(AVMEDIA_TYPE_VIDEO) ?? first(AVMEDIA_TYPE_AUDIO)
    }

    /// The stream's script header (script info and styles): the codec private data of an ASS / SSA track.
    static func assHeader(of stream: UnsafeMutablePointer<AVStream>) -> Data {
        guard let parameters = stream.pointee.codecpar, let extradata = parameters.pointee.extradata,
            parameters.pointee.extradata_size > 0
        else { return Data() }
        return Data(bytes: extradata, count: Int(parameters.pointee.extradata_size))
    }

    /// The fonts a container attaches (Matroska attachments), which ASS scripts may name instead of installed fonts.
    static func attachedFonts(in ctx: UnsafeMutablePointer<AVFormatContext>) -> [AssScript.Font] {
        let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
        return (0..<Int(ctx.pointee.nb_streams)).compactMap { index in
            guard let stream = ctx.pointee.streams[index], let parameters = stream.pointee.codecpar,
                parameters.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT, let extradata = parameters.pointee.extradata,
                parameters.pointee.extradata_size > 0,
                let tag = av_dict_get(stream.pointee.metadata, "filename", nil, 0)
            else { return nil }
            let name = String(cString: tag.pointee.value)
            guard fontExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            return AssScript.Font(
                name: name, data: Data(bytes: extradata, count: Int(parameters.pointee.extradata_size)))
        }
    }

    /// An ASS / SSA packet as the event libass takes: the packet's text with its time and duration.
    static func assEvent(from pkt: UnsafePointer<AVPacket>, timebase: AVRational) -> AssScript.Event? {
        guard pkt.pointee.size > 0, pkt.pointee.data != nil, timebase.den > 0,
            let payload = String(data: Data(bytes: pkt.pointee.data, count: Int(pkt.pointee.size)), encoding: .utf8)
        else { return nil }
        let noPTS = Int64.min  // AV_NOPTS_VALUE
        let rawPTS = pkt.pointee.pts != noPTS ? pkt.pointee.pts : pkt.pointee.dts
        guard rawPTS != noPTS else { return nil }
        let seconds = { (ticks: Int64) in Double(ticks) * Double(timebase.num) / Double(timebase.den) }
        // As long as the text cue of the same packet (`parseSubtitleCue`), so libass doesn't leave it out.
        let duration = pkt.pointee.duration > 0 ? seconds(pkt.pointee.duration) : fallbackCueDuration
        return AssScript.Event(payload: payload, start: max(0, seconds(rawPTS)), duration: duration)
    }

    /// Parses an individual subtitle AVPacket into a SubtitleCue.
    static func parseSubtitleCue(
        pkt: UnsafeMutablePointer<AVPacket>,
        timebase: AVRational,
        codecId: AVCodecID,
        cueIndex: Int
    ) -> SubtitleCue? {
        guard pkt.pointee.size > 0, timebase.den > 0 else { return nil }
        var textData = Data(bytes: pkt.pointee.data, count: Int(pkt.pointee.size))

        // For MP4 mov_text (AV_CODEC_ID_MOV_TEXT), first 2 bytes are uint16_t length prefix
        if codecId == AV_CODEC_ID_MOV_TEXT, textData.count >= 2 {
            let textLength = Int(textData[0]) << 8 | Int(textData[1])
            if textLength <= (textData.count - 2) {
                textData = textData.subdata(in: 2..<(2 + textLength))
            } else {
                textData = textData.dropFirst(2)
            }
        }

        guard var rawString = String(data: textData, encoding: .utf8) ?? String(data: textData, encoding: .ascii) else {
            return nil
        }

        // For ASS / SSA subtitles, strip the leading comma-separated metadata fields
        // Format: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text (8 commas before text)
        // Or if raw line has "Dialogue: " prefix (9 commas before text)
        let isASS = codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA
        let rawPayload = isASS ? rawString : nil
        if isASS {
            if rawString.hasPrefix("Dialogue:") {
                let parts = rawString.components(separatedBy: ",")
                if parts.count >= 10 {
                    rawString = parts.suffix(from: 9).joined(separator: ",")
                }
            } else {
                let parts = rawString.components(separatedBy: ",")
                if parts.count >= 9 {
                    rawString = parts.suffix(from: 8).joined(separator: ",")
                }
            }
        }

        // A vector drawing (`{\p1}m 0 0 l ...`) is not text; libass draws it from the script.
        if isASS, rawString.range(of: #"\{[^}]*\\p[1-9]"#, options: .regularExpression) != nil { return nil }
        let alignment = SubtitleDocument.parseAlignment(from: rawString)
        let clean = SubtitleDocument.cleanFormattingTags(rawString).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        let noPtsValue: Int64 = Int64.min
        let rawPts =
            pkt.pointee.pts != noPtsValue ? pkt.pointee.pts : (pkt.pointee.dts != noPtsValue ? pkt.pointee.dts : 0)
        let startSec = Double(rawPts) * Double(timebase.num) / Double(timebase.den)
        let durationSec: Double
        if pkt.pointee.duration > 0 {
            durationSec = Double(pkt.pointee.duration) * Double(timebase.num) / Double(timebase.den)
        } else {
            durationSec = fallbackCueDuration
        }

        return SubtitleCue(
            id: cueIndex,
            startTime: max(0.0, startSec),
            endTime: max(startSec + 0.5, startSec + durationSec),
            text: clean,
            alignment: alignment,
            rawPayload: rawPayload
        )
    }
}
