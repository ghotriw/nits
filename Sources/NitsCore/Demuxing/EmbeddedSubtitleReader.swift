import CFFmpeg
import Foundation

/// Text subtitle packets (SRT, WebVTT, mov_text, ASS, SSA) as cues, and whole-track extraction from a
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

    /// Dedicated fast extraction of text subtitles from media stream without disturbing playback queues.
    static func extractEmbeddedSubtitles(url: String, headers: [String: String], streamIndex: Int)
        -> SubtitleDocument?
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

        var tempCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        let ret = avformat_open_input(&tempCtx, url, nil, &options)
        guard ret == 0, let ctx = tempCtx else { return nil }
        defer { avformat_close_input(&tempCtx) }

        guard avformat_find_stream_info(ctx, nil) >= 0, streamIndex < Int(ctx.pointee.nb_streams) else {
            return nil
        }

        // Discard packets on all streams except the target subtitle stream to prevent reading heavy video/audio frames
        for i in 0..<Int(ctx.pointee.nb_streams) {
            if i != streamIndex, let st = ctx.pointee.streams[i] {
                st.pointee.discard = AVDISCARD_ALL
            }
        }

        let stream = ctx.pointee.streams[streamIndex]!
        let timebase = stream.pointee.time_base
        let codecId = stream.pointee.codecpar.pointee.codec_id
        guard timebase.den > 0 else { return nil }

        var cues: [SubtitleCue] = []
        var imageCues: [SubtitleImageCue] = []
        var cueIndex = 0
        let bitmapDecoder = BitmapSubtitleDecoder.isBitmapCodec(codecId) ? BitmapSubtitleDecoder(stream: stream) : nil
        let isASS = codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA
        var assEvents: [AssScript.Event] = []
        if BitmapSubtitleDecoder.isBitmapCodec(codecId), bitmapDecoder == nil { return nil }

        var pkt = AVPacket()

        let origin = MediaDemuxer.timelineOrigin(of: ctx)
        while !Task.isCancelled && av_read_frame(ctx, &pkt) >= 0 {
            MediaDemuxer.rebase(&pkt, origin: origin, in: ctx)
            if pkt.stream_index == streamIndex {
                if let bitmapDecoder {
                    imageCues.apply(bitmapDecoder.decode(&pkt))
                } else {
                    if isASS, let event = Self.assEvent(from: &pkt, timebase: timebase) {
                        assEvents.append(event)
                    }
                    if let cue = Self.parseSubtitleCue(
                        pkt: &pkt, timebase: timebase, codecId: codecId, cueIndex: cueIndex)
                    {
                        cueIndex += 1
                        cues.append(cue)
                    }
                }
            }
            av_packet_unref(&pkt)
        }

        let script =
            isASS
            ? AssScript(header: Self.assHeader(of: stream), events: assEvents, fonts: Self.attachedFonts(in: ctx))
            : nil
        return SubtitleDocument(cues: cues, imageCues: imageCues, assScript: script)
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
        guard rawPTS != noPTS, pkt.pointee.duration > 0 else { return nil }
        let seconds = { (ticks: Int64) in Double(ticks) * Double(timebase.num) / Double(timebase.den) }
        return AssScript.Event(
            payload: payload, start: max(0, seconds(rawPTS)), duration: seconds(pkt.pointee.duration))
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
            // Default display duration 4.0 seconds if unspecified
            durationSec = 4.0
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
