import CFFmpeg
import Foundation

/// CEA-608 closed captions a video stream carries in its pictures: ATSC A/53 `cc_data` in H.264 / HEVC SEI messages
/// (user data registered by ITU-T T.35) and in MPEG-2 picture user data, as US broadcasts and HLS streams carry them.
/// They are no stream of the container, so FFmpeg lists no track for them; and as VideoToolbox decodes the pictures,
/// FFmpeg's decoder never sees the SEI either. The bytes are read from the packets here.
enum ClosedCaptions {
    /// The CEA-608 triplets of a video packet's `cc_data`, in bitstream order, as FFmpeg's `cc_dec` takes them:
    /// `cc_valid` set and `cc_type` 0 (field 1) or 1 (field 2). CEA-708 ones (types 2 and 3) are left out. Empty when
    /// the packet carries none. `lengthSize` is the size of the unit lengths in Matroska and MP4 packets
    /// (`nalLengthSize(of:codec:)`).
    static func cea608Triplets(in packet: UnsafeRawBufferPointer, codec: VideoCodec, lengthSize: Int = 4) -> [UInt8] {
        var triplets: [UInt8] = []
        switch codec {
        case .h264:
            // The units before the first slice.
            forEachNALUnit(in: packet, codec: codec, lengthSize: lengthSize) { unit in
                if unit.first.map({ $0 & 0x1F }) == 6 {
                    appendSEITriplets(rbsp: unescaped(unit.dropFirst(1)), to: &triplets)
                }
            }
        case .hevc:
            // Prefix SEI.
            forEachNALUnit(in: packet, codec: codec, lengthSize: lengthSize) { unit in
                if unit.first.map({ ($0 >> 1) & 0x3F }) == 39, unit.count > 2 {
                    appendSEITriplets(rbsp: unescaped(unit.dropFirst(2)), to: &triplets)
                }
            }
        case .mpeg2:
            appendUserDataTriplets(in: packet, to: &triplets)
        default:
            break
        }
        return triplets
    }

    /// The fields (0 for CC1 / CC2, 1 for CC3 / CC4) the triplets carry captions in. Field 2 counts only with more than
    /// null padding: many encoders fill it with that whether or not it has captions.
    static func fields(of triplets: [UInt8]) -> Set<Int> {
        var fields: Set<Int> = []
        for index in stride(from: 0, to: triplets.count - 2, by: 3) {
            let field = Int(triplets[index] & 1)
            if field == 0 || triplets[index + 1] & 0x7F != 0 || triplets[index + 2] & 0x7F != 0 {
                fields.insert(field)
            }
        }
        return fields
    }

    /// The size of the unit lengths in the packets of a stream whose extradata is an `avcC` / `hvcC` record
    /// (`lengthSizeMinusOne` + 1); 4, as nearly every muxer writes them, for anything else.
    static func nalLengthSize(of parameters: UnsafePointer<AVCodecParameters>, codec: VideoCodec) -> Int {
        let size = Int(parameters.pointee.extradata_size)
        guard let extradata = parameters.pointee.extradata, size > 0, extradata[0] == 1 else { return 4 }
        switch codec {
        case .h264 where size >= 5: return Int(extradata[4] & 3) + 1
        case .hevc where size >= 23: return Int(extradata[21] & 3) + 1
        default: return 4
        }
    }

    /// Calls `body` with each H.264 / HEVC NAL unit of the packet before the first slice: SEI precedes the picture's
    /// slices. Matroska and MP4 packets are units behind lengths of `lengthSize` bytes, MPEG-TS ones behind start
    /// codes; a packet is taken for the former when its lengths add up to it exactly.
    private static func forEachNALUnit(
        in packet: UnsafeRawBufferPointer, codec: VideoCodec, lengthSize: Int,
        _ body: (Slice<UnsafeRawBufferPointer>) -> Void
    ) {
        // HEVC types below 32 are slices.
        let isPicture = { (header: UInt8) in
            codec == .hevc ? (header >> 1) & 0x3F < 32 : (1...5).contains(header & 0x1F)
        }
        let count = packet.count
        let length = { (offset: Int) in packet[offset..<offset + lengthSize].reduce(0) { $0 << 8 | Int($1) } }
        var offset = 0
        while offset + lengthSize <= count {
            let unit = length(offset)
            guard unit > 0, offset + lengthSize + unit <= count else { break }
            offset += lengthSize + unit
        }
        if offset == count, count > 0 {
            offset = 0
            while offset < count {
                let start = offset + lengthSize
                offset = start + length(offset)
                if isPicture(packet[start]) { return }
                body(packet[start..<offset])
            }
            return
        }

        // Annex B: a unit runs from after its start code to the next one (the zero of a 4-byte code is left on it,
        // past the unit's trailing bits). The search ends at the start code of a slice, not past the slice's bytes.
        var start: Int?
        var index = 0
        while index + 2 < count {
            guard packet[index] == 0, packet[index + 1] == 0, packet[index + 2] == 1 else {
                index += 1
                continue
            }
            if let start, start < index { body(packet[start..<index]) }
            index += 3
            if index < count, isPicture(packet[index]) { return }
            start = index
        }
        if let start, start < count { body(packet[start..<count]) }
    }

    /// The payload of a NAL unit without its emulation prevention bytes (the `03` in `00 00 03`).
    private static func unescaped(_ bytes: Slice<UnsafeRawBufferPointer>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            result.append(byte)
        }
        return result
    }

    /// The `cc_data` triplets of an SEI unit's messages: user data registered by ITU-T T.35 (payload type 4).
    private static func appendSEITriplets(rbsp: [UInt8], to triplets: inout [UInt8]) {
        var index = 0
        func varying() -> Int? {
            var value = 0
            while index < rbsp.count, rbsp[index] == 0xFF {
                value += 255
                index += 1
            }
            guard index < rbsp.count else { return nil }
            value += Int(rbsp[index])
            index += 1
            return value
        }
        // The unit ends in its trailing bits (0x80), which read as no whole message.
        while let type = varying(), let size = varying(), index + size <= rbsp.count {
            if type == 4 { appendT35Triplets(rbsp[index..<index + size], to: &triplets) }
            index += size
        }
    }

    /// ATSC user data (A/53 Part 4): country United States, provider ATSC, user identifier `GA94`, then `cc_data`.
    private static func appendT35Triplets(_ payload: ArraySlice<UInt8>, to triplets: inout [UInt8]) {
        let atsc: [UInt8] = [0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03]
        guard payload.starts(with: atsc) else { return }
        appendCCData(payload.dropFirst(atsc.count), to: &triplets)
    }

    /// MPEG-2 picture user data (start code `00 00 01 B2`) holding ATSC `cc_data` (`GA94`, type 3). User data comes
    /// before the picture's slices, so the search ends at the first slice.
    private static func appendUserDataTriplets(in packet: UnsafeRawBufferPointer, to triplets: inout [UInt8]) {
        let marker: [UInt8] = [0x47, 0x41, 0x39, 0x34, 0x03]
        let count = packet.count
        var index = 0
        while index + 3 < count {
            guard packet[index] == 0, packet[index + 1] == 0, packet[index + 2] == 1 else {
                index += 1
                continue
            }
            let code = packet[index + 3]
            if (0x01...0xAF).contains(code) { return }
            index += 4
            if code == 0xB2, packet[index...].starts(with: marker) {
                appendCCData(packet[(index + marker.count)...], to: &triplets)
            }
        }
    }

    /// `cc_data()`: flags and `cc_count`, a reserved byte, then the triplets.
    private static func appendCCData<Bytes: Collection<UInt8>>(_ data: Bytes, to triplets: inout [UInt8]) {
        let bytes = Array(data)
        // `process_cc_data_flag` clear: the data is to be ignored.
        guard bytes.count >= 2, bytes[0] & 0x40 != 0 else { return }
        let count = Int(bytes[0] & 0x1F)
        for index in 0..<count {
            let offset = 2 + index * 3
            guard offset + 3 <= bytes.count else { return }
            let flags = bytes[offset]
            guard flags & 0x04 != 0, flags & 0x03 < 2 else { continue }
            triplets += bytes[offset..<offset + 3]
        }
    }
}

/// Decodes the CEA-608 captions of one field into what the screen shows after each change, with FFmpeg's `cc_dec`
/// in its real-time mode, as mpv uses it: every change of the screen (a caption popped on, a roll-up line, a clear)
/// is a snapshot shown until the next. Captions in a video stream come with the pictures in decode order and are put
/// back into presentation order first.
///
/// Roll-up and paint-on captions change the screen with every pair of characters. Of the changes within a step of
/// `screenInterval` on the timeline only the last is kept, so every decoder of the stream (playback's, a window
/// read's, one started after a seek) gives the same screens at the same times, and the lists can tell them apart from
/// the incomplete ones of a decoder that started mid-caption. `cc_dec`'s own throttle counts from the decoder's start.
///
/// Not thread-safe: the owner serializes calls. A decoder follows one stream in order; `reset()` after a seek.
final class ClosedCaptionDecoder {
    /// What the screen shows from `time` on, until the next screen; an empty `text` clears it.
    struct Screen: Sendable, Equatable {
        let time: Double
        let text: String
        let alignment: SubtitleAlignment
        /// Read up to a stop within its step (a seek, a window's end): a later change in the step, or a picture shown
        /// before it but not read, may be missing. Any screen of the step read through replaces it.
        var isProvisional = false

        /// The step of `screenInterval` the screen falls in.
        var step: Int { ClosedCaptionDecoder.step(of: time) }
    }

    /// How long a screen no later one replaces stays at most, so a caption whose clear was cut off doesn't stay up.
    static let holdLimit = 16.0
    /// The steps of the timeline that keep one screen each, as often as mpv shows captions typed on.
    static let screenInterval = 0.2

    static func step(of time: Double) -> Int { Int((time / screenInterval).rounded(.down)) }

    private var context: UnsafeMutablePointer<AVCodecContext>?
    private let timebase: AVRational
    /// The video codec whose packets carry the captions; `nil` for a stream of `cc_data` triplets (MP4 `c608`).
    private let videoCodec: VideoCodec?
    private let lengthSize: Int
    /// Pictures that may still be shown before one decoded after them (the stream's reordering depth).
    private let reorderDepth: Int
    /// Pictures read whose captions wait for those shown before them, in decode order.
    private var pending: [(time: Double, triplets: [UInt8])] = []
    /// The last screen of the step being decoded: a later change in the step replaces it.
    private var held: Screen?
    private var lastText: String?
    private let field: Int
    /// Whether the decoder has seen a command that sets the caption mode (`setsMode`). It starts in roll-up, so a
    /// pop-on caption being loaded when it starts would be written onto the screen; the first such command starts it
    /// over.
    private var knowsMode = false

    /// Whether the captions ride in the packets of a video stream.
    var readsVideo: Bool { videoCodec != nil }

    /// A decoder for `field` (0: CC1 / CC2, 1: CC3 / CC4) of a video stream's captions or a stream of them; `nil`
    /// for a video codec that carries none.
    init?(field: Int, stream: UnsafeMutablePointer<AVStream>) {
        guard let parameters = stream.pointee.codecpar, stream.pointee.time_base.den > 0,
            let codec = avcodec_find_decoder(AV_CODEC_ID_EIA_608), let context = avcodec_alloc_context3(codec)
        else { return nil }
        if parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
            guard let videoCodec = VideoCodec.from(codecId: parameters.pointee.codec_id),
                [.h264, .hevc, .mpeg2].contains(videoCodec)
            else {
                var unused: UnsafeMutablePointer<AVCodecContext>? = context
                avcodec_free_context(&unused)
                return nil
            }
            self.videoCodec = videoCodec
            lengthSize = ClosedCaptions.nalLengthSize(of: parameters, codec: videoCodec)
            // FFmpeg's guess from the stream may fall short; four covers the B-frame pyramids encoders use.
            reorderDepth = min(max(Int(parameters.pointee.video_delay), 4), 16)
        } else {
            videoCodec = nil
            lengthSize = 4
            reorderDepth = 0
        }
        timebase = stream.pointee.time_base
        self.field = field

        var opened: UnsafeMutablePointer<AVCodecContext>? = context
        var options: OpaquePointer? = nil
        defer { av_dict_free(&options) }
        av_dict_set(&options, "real_time", "1", 0)
        // Every change comes out with the picture that makes it; `Screen.step` thins them out.
        av_dict_set(&options, "real_time_latency_msec", "0", 0)
        av_dict_set(&options, "data_field", String(field), 0)
        context.pointee.pkt_timebase = AVRational(num: 1, den: 1_000_000)
        guard avcodec_open2(context, codec, &options) >= 0 else {
            avcodec_free_context(&opened)
            return nil
        }
        self.context = context
    }

    deinit {
        avcodec_free_context(&context)
    }

    /// Forgets the screen and the pictures waiting, as a seek makes them stale; the screen held back for its step,
    /// provisional.
    func reset() -> [Screen] {
        if let context { avcodec_flush_buffers(context) }
        pending.removeAll()
        var screens = held.map { [$0] } ?? []
        for index in screens.indices { screens[index].isProvisional = true }
        held = nil
        lastText = nil
        knowsMode = false
        return screens
    }

    /// The screens a packet of the stream completes: those of pictures now known to be shown before any read later,
    /// whose step has passed.
    func decode(_ packet: UnsafePointer<AVPacket>) -> [Screen] {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return [] }
        let bytes = UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size))
        let noPTS = Int64.min  // AV_NOPTS_VALUE
        let seconds = { (ticks: Int64) in
            ticks == noPTS ? nil : Double(ticks) * Double(self.timebase.num) / Double(self.timebase.den)
        }
        guard let videoCodec else {
            guard let time = seconds(packet.pointee.pts) ?? seconds(packet.pointee.dts) else { return [] }
            var screens = advance(to: time, with: Array(bytes))
            // A caption track has packets only where it has pairs: nothing changes before the packet's end, which
            // may be seconds away. Without a duration, nothing tells.
            let end = packet.pointee.duration > 0 ? seconds(packet.pointee.duration).map { time + $0 } : nil
            if let screen = held, end.map({ Self.step(of: $0) > screen.step }) ?? true {
                screens.append(screen)
                held = nil
            }
            return screens
        }

        let triplets = ClosedCaptions.cea608Triplets(in: bytes, codec: videoCodec, lengthSize: lengthSize)
        guard let time = seconds(packet.pointee.pts) else {
            // A second field's packet without a time of its own belongs to the picture before it.
            if !triplets.isEmpty, !pending.isEmpty { pending[pending.count - 1].triplets += triplets }
            return []
        }
        pending.append((time, triplets))
        var screens: [Screen] = []
        // A picture decoded later is shown no earlier than it is decoded: what is due before that is complete.
        let decoded = seconds(packet.pointee.dts)
        while let first = earliestPending(), (decoded.map { first.time < $0 } ?? false) || pending.count > reorderDepth
        {
            let picture = pending.remove(at: first.index)
            screens += advance(to: picture.time, with: picture.triplets)
        }
        return screens
    }

    /// The screens of the pictures still waiting: the stream has ended, or the read stops there (`provisional`).
    func finish(provisional: Bool = false) -> [Screen] {
        var screens: [Screen] = []
        while let first = earliestPending() {
            let picture = pending.remove(at: first.index)
            screens += advance(to: picture.time, with: picture.triplets)
        }
        if let held { screens.append(held) }
        held = nil
        if provisional {
            for index in screens.indices { screens[index].isProvisional = true }
        }
        return screens
    }

    private func earliestPending() -> (index: Int, time: Double)? {
        pending.indices.min { pending[$0].time < pending[$1].time }.map { ($0, pending[$0].time) }
    }

    /// Decodes the triplets of the picture shown at `time`, after those of every picture shown before it; the held
    /// screen when its step has passed.
    private func advance(to time: Double, with triplets: [UInt8]) -> [Screen] {
        var screens: [Screen] = []
        if let screen = held, Self.step(of: time) > screen.step {
            screens.append(screen)
            held = nil
        }
        if !triplets.isEmpty, let screen = decode(triplets, at: time) { held = screen }
        return screens
    }

    /// Whether the triplets of the decoder's field hold a command that sets the caption mode, as `cc_dec` reads them
    /// (any channel's control prefix): resume caption loading (pop-on captions start with it), roll-up, resume direct
    /// captioning, or a carriage return, which only roll-up sends (some send roll-up once, at the start).
    private func setsMode(_ triplets: [UInt8]) -> Bool {
        stride(from: 0, to: triplets.count - 2, by: 3).contains { index in
            let (flags, hi, lo) = (triplets[index], triplets[index + 1], triplets[index + 2])
            guard flags & 0x04 != 0, Int(flags & 1) == field, hi.nonzeroBitCount % 2 == 1,
                lo.nonzeroBitCount % 2 == 1
            else { return false }
            return [0x14, 0x15, 0x1C].contains(hi & 0x7F) && [0x20, 0x25, 0x26, 0x27, 0x29, 0x2D].contains(lo & 0x7F)
        }
    }

    /// Hands `cc_dec` one picture's triplets; the screen it shows after them, if it changed. None until the mode is
    /// known (`knowsMode`).
    private func decode(_ triplets: [UInt8], at time: Double) -> Screen? {
        guard let context else { return nil }
        if !knowsMode, setsMode(triplets) {
            // Start over: what was written before may be on either screen, and pop-on loads onto one it doesn't clear.
            avcodec_flush_buffers(context)
            knowsMode = true
        }
        guard let packet = av_packet_alloc() else { return nil }
        var freed: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&freed) }
        guard av_new_packet(packet, Int32(triplets.count)) == 0 else { return nil }
        triplets.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: $0.count) }
        packet.pointee.pts = Int64((time * 1_000_000).rounded())

        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        guard avcodec_decode_subtitle2(context, &subtitle, &gotSubtitle, packet) >= 0, gotSubtitle != 0 else {
            return nil
        }
        defer { avsubtitle_free(&subtitle) }
        // Changes within the picture's pairs: the last is what stays on screen.
        guard subtitle.num_rects > 0, let rect = subtitle.rects[Int(subtitle.num_rects) - 1]?.pointee,
            rect.type == SUBTITLE_ASS, let ass = rect.ass
        else { return nil }
        // `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`, as FFmpeg's text decoders write it.
        let fields = String(cString: ass).split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return nil }
        let screen = Self.screen(fromASS: String(fields[8]), at: time)
        guard knowsMode, screen.text != lastText else { return nil }
        lastText = screen.text
        return screen
    }

    /// `cc_dec` writes each row of the screen as `{\an7}{\pos(x,y)}` and its text, rows apart by `\N`, on a 384 x 288
    /// script: the text is drawn in the user's style, at the top when every row is in the upper half.
    static func screen(fromASS text: String, at time: Double) -> Screen {
        var rows: [String] = []
        var isTop = true
        for row in text.components(separatedBy: "\\N") {
            if let match = row.firstMatch(of: #/\\pos\(\d+,(\d+)\)/#), let y = Int(match.1), y >= 144 {
                isTop = false
            }
            let line = row.replacing(#/\{[^}]*\}/#, with: "").replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { rows.append(line) }
        }
        return Screen(
            time: time, text: rows.joined(separator: "\n"),
            alignment: isTop && !rows.isEmpty ? .topCenter : .bottomCenter)
    }
}
