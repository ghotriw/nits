import CFFmpeg
import Foundation

/// Subtitle files in text formats Nits has no parser of its own for (MicroDVD and SubViewer `.sub`, SAMI `.smi`):
/// FFmpeg reads them and its decoders turn every format into ASS events, which become plain-text cues as SRT's are,
/// drawn in the user's subtitle style.
enum FFmpegTextSubtitles {
    /// Extensions of the files read this way. A `.sub` with a VobSub `.idx` next to it is pictures, loaded through
    /// the index instead.
    static let extensions: Set<String> = ["sub", "smi", "sami"]

    /// The demuxers a file may open with: a subtitle file found next to the media is opened unasked, and FFmpeg would
    /// otherwise take any format its content looks like, playlists that open other URLs included.
    static let formats = ["microdvd", "subviewer", "subviewer1", "mpsub", "sami"]

    /// How much of a file is looked at when it is added.
    static let sniffLength = 64 << 10

    /// Whether the file holds subtitles in one of `formats` (`format(of:path:)` on its beginning, in UTF-8 as `read`
    /// hands FFmpeg the file). Binary files (a VobSub `.sub` without its index is MPEG program stream, possibly
    /// hundreds of megabytes) and text in other formats are left out, so no track is made that would read as nothing.
    static func isReadable(_ url: URL, hints: TextFileEncoding.Hints = .init()) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: sniffLength), !prefix.isEmpty,
            !TextFileEncoding.looksBinary(prefix),
            let text = TextFileEncoding.utf8(prefix, isPrefix: true, hints: hints)
        else { return false }
        return format(of: text, path: url.path) != nil
    }

    /// Which of `formats` the UTF-8 `text` (a file's beginning, or all of it) is in: the one whose own probe knows
    /// it. FFmpeg also scores a format whose extension the file has, by that alone; such a match isn't taken, or any
    /// `.smi` would pass for SAMI. SAMI that FFmpeg's probe misses (it wants `<SAMI>` in capitals at the very start),
    /// its demuxer reads all the same: it is told by its tags here.
    static func format(of text: Data, path: String) -> String? {
        // The probes read past the end by up to `AVPROBE_PADDING_SIZE` bytes, which must be zero.
        var buffer = [UInt8](text) + [UInt8](repeating: 0, count: Int(AVPROBE_PADDING_SIZE))
        let probed = path.withCString { path in
            buffer.withUnsafeMutableBufferPointer { bytes -> String? in
                var probe = AVProbeData(
                    filename: path, buf: bytes.baseAddress, buf_size: Int32(text.count), mime_type: nil)
                // Only a score above an extension's 1 counts.
                var score: Int32 = 1
                return av_probe_input_format2(&probe, 1, &score).map { String(cString: $0.pointee.name) }
            }
        }
        if let probed, formats.contains(probed) { return probed }
        // Also when another demuxer outscored the SAMI one on content it missed.
        let start = String(decoding: text.prefix(4096), as: UTF8.self).lowercased()
        let isSAMI = start.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<sami") && start.contains("<sync")
        return isSAMI ? "sami" : nil
    }

    /// The file's cues, or `nil` when it is in none of `formats` or holds no line. The whole file is decoded in its
    /// encoding (`TextFileEncoding`, with `hints`) and FFmpeg reads a UTF-8 copy: most of its subtitle demuxers look
    /// for ASCII in the bytes, and its decoders drop any line that isn't UTF-8. Blocks while it reads: call it off the
    /// main thread.
    /// - Parameters:
    ///   - frameRate: The video's, for MicroDVD files that count frames without saying at what rate; FFmpeg assumes
    ///     23.976 fps otherwise.
    ///   - interrupt: Aborts the read (a track no longer selected).
    static func read(
        url: URL, frameRate: Double?, hints: TextFileEncoding.Hints = .init(), interrupt: FFmpegInterrupt? = nil
    ) -> SubtitleDocument? {
        guard let data = try? Data(contentsOf: url), let text = TextFileEncoding.utf8(data, hints: hints) else {
            return nil
        }
        guard let name = format(of: text, path: url.path), let inputFormat = av_find_input_format(name) else {
            return nil
        }
        // Same extension: FFmpeg's probes weigh it.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        guard (try? text.write(to: copy)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: copy) }

        var options: OpaquePointer? = nil
        defer { av_dict_free(&options) }
        av_dict_set(&options, "format_whitelist", formats.joined(separator: ","), 0)
        av_dict_set(&options, "protocol_whitelist", "file", 0)
        if let frameRate, frameRate.isFinite, frameRate > 0 {
            av_dict_set(&options, "subfps", String(format: "%.6f", frameRate), 0)
        }
        var openedCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = openedCtx else { return nil }
        interrupt?.install(on: allocated)
        guard avformat_open_input(&openedCtx, copy.path, inputFormat, &options) == 0, let ctx = openedCtx else {
            return nil
        }
        defer { avformat_close_input(&openedCtx) }

        // Subtitle demuxers make their stream while reading the header: nothing to probe.
        guard
            let index = (0..<Int(ctx.pointee.nb_streams)).first(where: { index in
                guard let parameters = ctx.pointee.streams[index]?.pointee.codecpar,
                    parameters.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE,
                    let descriptor = avcodec_descriptor_get(parameters.pointee.codec_id)
                else { return false }
                return descriptor.pointee.props & AV_CODEC_PROP_TEXT_SUB != 0
            }),
            let stream = ctx.pointee.streams[index],
            let codec = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id)
        else { return nil }

        var decoderCtx = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&decoderCtx) }
        guard let decoder = decoderCtx, avcodec_parameters_to_context(decoder, stream.pointee.codecpar) >= 0 else {
            return nil
        }
        decoder.pointee.pkt_timebase = stream.pointee.time_base
        guard avcodec_open2(decoder, codec, nil) >= 0 else { return nil }

        let timebase = stream.pointee.time_base
        let seconds = { (ticks: Int64) in Double(ticks) * Double(timebase.num) / Double(timebase.den) }
        // Cues timed by their start; ends come once the next start is known.
        var timed: [(cue: SubtitleCue, duration: Double?)] = []
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return nil }
        while av_read_frame(ctx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            if interrupt?.isCancelled == true { return nil }
            let noPTS = Int64.min  // AV_NOPTS_VALUE
            guard packet.pointee.stream_index == Int32(index), packet.pointee.pts != noPTS else { continue }
            var subtitle = AVSubtitle()
            var gotSubtitle: Int32 = 0
            guard avcodec_decode_subtitle2(decoder, &subtitle, &gotSubtitle, packet) >= 0, gotSubtitle != 0 else {
                continue
            }
            defer { avsubtitle_free(&subtitle) }

            let start = max(0, seconds(packet.pointee.pts))
            let duration = packet.pointee.duration > 0 ? seconds(packet.pointee.duration) : nil
            for rectIndex in 0..<Int(subtitle.num_rects) {
                guard let rect = subtitle.rects[rectIndex]?.pointee, rect.type == SUBTITLE_ASS, let ass = rect.ass
                else { continue }
                // `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`, as every FFmpeg text decoder writes.
                let fields = String(cString: ass).split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let raw = String(fields[8])
                let text = SubtitleDocument.cleanFormattingTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let cue = SubtitleCue(
                    id: 0, startTime: start, endTime: start, text: text,
                    alignment: SubtitleDocument.parseAlignment(from: raw))
                timed.append((cue, duration))
            }
        }

        // A line with no end of its own (MicroDVD's `{100}{}`) lasts until the next one, `fallbackCueDuration` at most. A
        // shorter one than `minimumCueDuration` is held that long, as embedded tracks' are, but only until the next line:
        // MicroDVD lines a few frames long follow each other, and two would show at once.
        timed.sort { $0.cue.startTime < $1.cue.startTime }
        let cues = timed.indices.map { position in
            let (cue, duration) = timed[position]
            let gap = timed[(position + 1)...].first { $0.cue.startTime > cue.startTime }.map {
                $0.cue.startTime - cue.startTime
            }
            let shown =
                if let duration {
                    max(duration, min(EmbeddedSubtitleReader.minimumCueDuration, gap ?? .infinity))
                } else {
                    min(EmbeddedSubtitleReader.fallbackCueDuration, gap ?? .infinity)
                }
            let end = cue.startTime + shown
            return SubtitleCue(
                id: position + 1, startTime: cue.startTime, endTime: end, text: cue.text, alignment: cue.alignment)
        }
        // A file its format's demuxer finds no line in isn't a track (a `.smi` that only looked like SAMI).
        guard !cues.isEmpty else { return nil }
        AppLog.info(
            .subtitles,
            "Read \(cues.count) cues from \(url.lastPathComponent) (\(String(cString: avcodec_get_name(codec.pointee.id))))"
        )
        return SubtitleDocument(cues: cues)
    }
}
