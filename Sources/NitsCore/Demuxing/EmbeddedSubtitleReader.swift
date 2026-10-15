import CFFmpeg
import Foundation

/// Text subtitle packets (SRT, WebVTT, mov_text, ASS, SSA) as cues, and whole-track extraction from a
/// secondary demuxer that never disturbs playback.
enum EmbeddedSubtitleReader {
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
        var cueIndex = 0

        var pkt = AVPacket()

        let origin = MediaDemuxer.timelineOrigin(of: ctx)
        while !Task.isCancelled && av_read_frame(ctx, &pkt) >= 0 {
            MediaDemuxer.rebase(&pkt, origin: origin, in: ctx)
            if pkt.stream_index == streamIndex {
                if let cue = Self.parseSubtitleCue(pkt: &pkt, timebase: timebase, codecId: codecId, cueIndex: cueIndex)
                {
                    cueIndex += 1
                    cues.append(cue)
                }
            }
            av_packet_unref(&pkt)
        }

        return SubtitleDocument(cues: cues)
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
        if codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA {
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
            alignment: alignment
        )
    }
}
