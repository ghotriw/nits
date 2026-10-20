import CFFmpeg
import Foundation

/// Decodes the packets of a bitmap subtitle stream (PGS, VobSub, DVB) into `SubtitleImageCue`s.
///
/// Not thread-safe: the owner serializes calls. A decoder follows one stream in order; `flush()` after a seek.
final class BitmapSubtitleDecoder {
    /// What one packet changes.
    struct Output: Sendable {
        /// The set shown before this packet is replaced or cleared at this time.
        var truncatePreviousAt: Double?
        var cue: SubtitleImageCue?
    }

    /// How long a set that carries no end (a PGS stream's clearing packet never came) stays on screen.
    static let fallbackDuration = 5.0

    static func isBitmapCodec(_ id: AVCodecID) -> Bool {
        id == AV_CODEC_ID_HDMV_PGS_SUBTITLE || id == AV_CODEC_ID_DVD_SUBTITLE || id == AV_CODEC_ID_DVB_SUBTITLE
    }

    private var context: UnsafeMutablePointer<AVCodecContext>?
    private let timebase: AVRational
    private let streamCanvas: (width: Int, height: Int)

    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let parameters = stream.pointee.codecpar, Self.isBitmapCodec(parameters.pointee.codec_id),
            stream.pointee.time_base.den > 0,
            let codec = avcodec_find_decoder(parameters.pointee.codec_id),
            let context = avcodec_alloc_context3(codec)
        else { return nil }
        var opened: UnsafeMutablePointer<AVCodecContext>? = context
        guard avcodec_parameters_to_context(context, parameters) >= 0 else {
            avcodec_free_context(&opened)
            return nil
        }
        context.pointee.pkt_timebase = stream.pointee.time_base
        guard avcodec_open2(context, codec, nil) >= 0 else {
            avcodec_free_context(&opened)
            return nil
        }
        self.context = context
        self.timebase = stream.pointee.time_base
        self.streamCanvas = (Int(parameters.pointee.width), Int(parameters.pointee.height))
    }

    deinit {
        avcodec_free_context(&context)
    }

    /// Forgets the state a seek makes stale: a display set may build on the ones before it.
    func flush() {
        if let context { avcodec_flush_buffers(context) }
    }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>) -> Output {
        guard let context, packet.pointee.size > 0 else { return Output() }
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        guard avcodec_decode_subtitle2(context, &subtitle, &gotSubtitle, packet) >= 0, gotSubtitle != 0 else {
            return Output()
        }
        defer { avsubtitle_free(&subtitle) }

        let noPTS = Int64.min  // AV_NOPTS_VALUE
        let rawPTS = packet.pointee.pts != noPTS ? packet.pointee.pts : packet.pointee.dts
        guard rawPTS != noPTS else { return Output() }
        let seconds = { (ticks: Int64) in Double(ticks) * Double(self.timebase.num) / Double(self.timebase.den) }
        let packetTime = seconds(rawPTS)
        let start = max(0, packetTime + Double(subtitle.start_display_time) / 1000)

        let regions = Self.regions(of: subtitle)
        var output = Output(truncatePreviousAt: start)
        guard !regions.isEmpty else { return output }

        var end = start + Self.fallbackDuration
        var endIsEstimated = false
        if subtitle.end_display_time != 0, subtitle.end_display_time != UInt32.max {
            end = packetTime + Double(subtitle.end_display_time) / 1000
        } else if packet.pointee.duration > 0 {
            end = packetTime + seconds(packet.pointee.duration)
        } else {
            endIsEstimated = true
        }

        // PGS stores the video size in the stream; DVD and DVB give it to the decoder.
        var canvas = (width: Int(context.pointee.width), height: Int(context.pointee.height))
        if canvas.width <= 0 || canvas.height <= 0 { canvas = streamCanvas }
        if canvas.width <= 0 || canvas.height <= 0 { canvas = (0, 0) }

        output.cue = SubtitleImageCue(
            id: SubtitleImageCue.makeID(), startTime: start, endTime: max(end, start), canvasWidth: canvas.width,
            canvasHeight: canvas.height, regions: regions, endIsEstimated: endIsEstimated)
        return output
    }

    /// Copies the bitmap rects out of FFmpeg's buffers; empty rects (a clearing set) are left out.
    private static func regions(of subtitle: AVSubtitle) -> [SubtitleImageCue.Region] {
        guard let rects = subtitle.rects else { return [] }
        return (0..<Int(subtitle.num_rects)).compactMap { index in
            guard let rect = rects[index]?.pointee, rect.type == SUBTITLE_BITMAP, rect.w > 0, rect.h > 0,
                let pixels = rect.data.0, rect.linesize.0 >= rect.w
            else { return nil }
            let width = Int(rect.w)
            var indices = Data(capacity: width * Int(rect.h))
            for row in 0..<Int(rect.h) {
                indices.append(pixels + row * Int(rect.linesize.0), count: width)
            }
            var palette: [UInt32] = []
            if let colors = rect.data.1 {
                let count = min(max(Int(rect.nb_colors), 0), 256)
                palette = colors.withMemoryRebound(to: UInt32.self, capacity: count) {
                    Array(UnsafeBufferPointer(start: $0, count: count))
                }
            }
            return SubtitleImageCue.Region(
                x: Int(rect.x), y: Int(rect.y), width: width, height: Int(rect.h), indices: indices, palette: palette,
                isForced: rect.flags & AV_SUBTITLE_FLAG_FORCED != 0)
        }
    }
}
