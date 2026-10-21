import CFFmpeg
import CoreMedia
import Foundation
import VideoToolbox
import os

public final class MediaDemuxer: @unchecked Sendable {
    public static let dolbyVisionMetadataAttachmentKey: String = "Nits.DolbyVisionMetadata"
    /// Sample attachment set when the container had no PTS for the packet (AVI stores decode order
    /// only). The sample's PTS then falls back to its DTS; software decoders must not pass it on as
    /// a real PTS or B-frame reordering skews every presentation timestamp.
    public static let presentationTimeUnknownAttachmentKey: String = "Nits.PresentationTimeUnknown"
    /// Exact-seek target (seconds) on preroll samples. `DoNotDisplay` is decided from the sample's PTS, or
    /// its DTS without one, which is too early for reordered frames; and a frame-per-field deinterlacer's
    /// second field may already reach the target. A decoder that knows the real PTS of what it outputs
    /// should compare it against this instead.
    public static let exactSeekTargetAttachmentKey: String = "Nits.ExactSeekTarget"

    var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    var videoStreamIndex: Int = -1
    var audioStreamIndex: Int = -1
    public internal(set) var timebase: AVRational = AVRational(num: 1, den: 1000)
    public internal(set) var audioTimebase: AVRational = AVRational(num: 1, den: 1000)
    public internal(set) var codec: VideoCodec = .hevc
    public internal(set) var hasVideo: Bool = false
    public internal(set) var nominalFrameDuration: Double = 1.0 / 24.0
    /// Presentation time of the first picture, in seconds on the playback timeline. A file cut between keyframes
    /// starts its video up to a GOP after its audio and subtitles. Read from the first keyframe when the file opens;
    /// 0 when the opening scan doesn't reach it.
    public internal(set) var videoStartTime: Double = 0
    /// The stream is interlaced: it signals a field order (`field_order` TT / BB / TB / BT), or it is standard
    /// definition DV, interlaced by format but without a field order. Frames may still be flagged interlaced
    /// individually when this is `false`.
    public internal(set) var isInterlaced: Bool = false
    public internal(set) var hasAudio: Bool = false
    public internal(set) var audioCodecId: AVCodecID = AV_CODEC_ID_NONE
    public internal(set) var audioChannels: Int = 0
    public internal(set) var audioSampleRate: Int = 0
    public struct AudioTrack: Sendable, Identifiable, Equatable {
        public let id: Int
        public let streamIndex: Int
        public let title: String
        public let language: String
        public let codecName: String
        public let channels: Int
        public let sampleRate: Int
        /// Flagged to play by default (`AV_DISPOSITION_DEFAULT`).
        public let isDefault: Bool
    }

    public internal(set) var audioTracks: [AudioTrack] = []
    public internal(set) var selectedAudioTrackIndex: Int = -1
    public internal(set) var audioExtraData: Data? = nil
    public internal(set) var embeddedArtworkData: Data? = nil
    public internal(set) var chapters: [MediaChapter] = []

    public internal(set) var subtitleTracks: [SubtitleTrack] = []
    public private(set) var selectedSubtitleTrackId: Int? = nil
    let subtitleTracker = LiveSubtitleTracker()
    public var liveSubtitleVersion: Int {
        subtitleTracker.version
    }
    /// Furthest timeline second read from the audio and video streams since the last seek (`-infinity` before any),
    /// `infinity` once the input has been read to its end. Its own lock: `lock` is held through blocking reads.
    let readAheadState = OSAllocatedUnfairLock(initialState: -Double.infinity)
    /// Timeline second up to which packets have been read ahead of playback; see `readAheadState`.
    public var readAheadSeconds: Double {
        readAheadState.withLock { $0 }
    }
    var lastAudioPts: Int64 = -1
    public var currentAudioPtsSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastAudioPts >= 0 && audioTimebase.den > 0 else { return 0 }
        return Double(lastAudioPts) * Double(audioTimebase.num) / Double(audioTimebase.den)
    }

    public func getAudioCodecParameters() -> UnsafePointer<AVCodecParameters>? {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx, audioStreamIndex >= 0 else { return nil }
        return UnsafePointer(ctx.pointee.streams[audioStreamIndex]!.pointee.codecpar)
    }

    public func getVideoCodecParameters() -> UnsafePointer<AVCodecParameters>? {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx, videoStreamIndex >= 0 else { return nil }
        return UnsafePointer(ctx.pointee.streams[videoStreamIndex]!.pointee.codecpar)
    }

    public func selectAudioTrack(trackId: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx, let track = audioTracks.first(where: { $0.id == trackId }) else { return }
        self.audioStreamIndex = track.streamIndex
        self.selectedAudioTrackIndex = track.id
        let stream = ctx.pointee.streams[track.streamIndex]!
        self.audioTimebase = stream.pointee.time_base
        self.audioCodecId = stream.pointee.codecpar.pointee.codec_id
        self.audioChannels = Int(stream.pointee.codecpar.pointee.ch_layout.nb_channels)
        self.audioSampleRate = Int(stream.pointee.codecpar.pointee.sample_rate)
        if let ed = stream.pointee.codecpar.pointee.extradata, stream.pointee.codecpar.pointee.extradata_size > 0 {
            self.audioExtraData = Data(bytes: ed, count: Int(stream.pointee.codecpar.pointee.extradata_size))
        } else {
            self.audioExtraData = nil
        }
        if !hasVideo {
            self.timebase = self.audioTimebase
        }
        self.audioQueue.removeAll()
    }

    /// Selects an embedded subtitle track by id (or nil to disable).
    public func selectSubtitleTrack(trackId: Int?) {
        lock.lock()
        defer { lock.unlock() }
        self.selectedSubtitleTrackId = trackId
        // Packets from where the reads are now on belong to the new track; what came before is for a window read.
        let readAhead = readAheadState.withLock { $0 }
        subtitleTracker.selectTrack(id: trackId, tracks: subtitleTracks, in: formatCtx, readAhead: readAhead)
    }

    /// Returns a SubtitleDocument with all cues collected in-band so far for the active subtitle track.
    /// Never touches the I/O lock, so it is safe to call from the main thread during network reads/seeks.
    public func getLiveSubtitleDocument() -> SubtitleDocument {
        subtitleTracker.getLiveSubtitleDocument()
    }

    /// Identifies the current track selection and reading stretch for `mergeLiveSubtitles`, with the stream to read
    /// for it (`-1` for none) and, for closed captions, their field. Never touches the I/O lock, like
    /// `getLiveSubtitleDocument()`.
    var liveSubtitleSelection: (id: Int, streamIndex: Int, captionField: Int?, span: Int) {
        subtitleTracker.liveSubtitleSelection
    }

    /// The part of the timeline a window read (`EmbeddedSubtitleReader.readSubtitles`) must read so the selected track
    /// is whole at `time` (track time: the subtitle delay applied), less what the lists hold already; `nil` when
    /// nothing is missing.
    func subtitleWindow(around time: Double) -> ClosedRange<Double>? {
        let readAhead = readAheadState.withLock { $0 }
        return subtitleTracker.subtitleWindow(around: time, readAhead: readAhead)
    }

    /// Playback reads from `seconds` on, not from the seek target: a forward keyframe seek lands past it, and what it
    /// jumped over wasn't read. Called with the time a seek landed at.
    func noteSubtitleReadsStart(at seconds: Double) {
        subtitleTracker.noteSubtitleReadsStart(at: seconds)
    }

    /// Adds the packets of a window read (`EmbeddedSubtitleReader.readSubtitles`) for the selection `selection` and
    /// reading stretch `span` to what playback collected, leaving out what is there already. Dropped (returning
    /// `false`) if another track was chosen or a seek started another stretch meanwhile.
    @discardableResult
    func mergeLiveSubtitles(
        _ packets: EmbeddedSubtitleReader.Packets, covering range: ClosedRange<Double>, selection: Int, span: Int
    ) -> Bool {
        subtitleTracker.mergeLiveSubtitles(packets, covering: range, selection: selection, span: span)
    }

    /// The starts of each subtitle stream's packets by the file's own index (`EmbeddedSubtitleReader.readIndex`), once
    /// read: `[:]` from opening for a file whose index doesn't come from the file.
    private let subtitleIndexState = OSAllocatedUnfairLock<[Int: [Double]]?>(initialState: nil)

    /// Whether the file's index of subtitle streams is still to read (`storeSubtitleIndex`).
    var needsSubtitleIndex: Bool {
        subtitleIndexState.withLock { $0 == nil }
    }

    /// Takes what `EmbeddedSubtitleReader.readIndex` read.
    func storeSubtitleIndex(_ starts: [Int: [Double]]) {
        subtitleIndexState.withLock { $0 = starts.mapValues { $0.sorted() } }
    }

    /// The starts of the packets of subtitle stream `streamIndex` within `range` by the file's own index (Matroska
    /// Cues, an MP4 sample table), `nil` when it doesn't list them or isn't read yet: with none, a window read would
    /// find nothing. Never touches the I/O lock.
    func indexedSubtitleStarts(of streamIndex: Int, in range: ClosedRange<Double>) -> [Double]? {
        subtitleIndexState.withLock { $0?[streamIndex]?.filter { range.contains($0) } }
    }

    /// What playback read of the selected track before it was chosen, once (`LiveSubtitleTracker.takeStashedSubtitles`).
    /// Never touches the I/O lock.
    func takeStashedSubtitles() -> (snapshot: SubtitlePacketStash.Snapshot, selection: Int, span: Int)? {
        subtitleTracker.takeStashedSubtitles()
    }

    /// Adds what a stash snapshot decoded to (`LiveSubtitleTracker.mergeStashed`).
    @discardableResult
    func mergeStashed(
        _ decoded: [EmbeddedSubtitleReader.Packets], of snapshot: SubtitlePacketStash.Snapshot, selection: Int,
        span: Int
    ) -> Bool {
        subtitleTracker.mergeStashed(decoded, of: snapshot, selection: selection, span: span)
    }

    var audioQueue = PacketFifoQueue<DemuxedAudioPacket>()
    var videoQueue = PacketFifoQueue<DemuxedVideoPacket>()
    private let maxAudioQueueCount = 500
    private let maxVideoQueueCount = 180
    public internal(set) var formatDescription: CMVideoFormatDescription?
    public internal(set) var durationSeconds: Double = 0
    public internal(set) var width: Int = 0
    public internal(set) var height: Int = 0
    /// Sample Aspect Ratio (Pixel Aspect Ratio) from stream metadata (e.g. 720:959 or 1:1)
    public internal(set) var sampleAspectRatio: RationalAspectRatio = .square
    /// Effective Display Aspect Ratio (DAR) taking SAR into account: (width * sar.multiplier) / height
    public var displayAspectRatio: Double {
        RationalAspectRatio.computeDisplayAspectRatio(width: width, height: height, sar: sampleAspectRatio)
    }
    public internal(set) var maxPeakNits: Float = 1000.0
    public internal(set) var maxFallNits: Float = 0.0
    public internal(set) var colorPrimaries: CFString = kCVImageBufferColorPrimaries_ITU_R_709_2
    public internal(set) var transferFunction: CFString = kCVImageBufferTransferFunction_ITU_R_709_2
    public internal(set) var yCbCrMatrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    public internal(set) var isFullRange: Bool = false
    public internal(set) var bitDepth: Int = 8
    public internal(set) var isDolbyVisionProfile5: Bool = false
    public internal(set) var dolbyVisionProfile: Int? = nil
    public internal(set) var dolbyVisionCompatibilityId: Int? = nil
    public internal(set) var dolbyVisionConfigData: Data? = nil
    public var dolbyVisionProfileString: String? {
        guard let p = dolbyVisionProfile else { return nil }
        if p == 8 {
            if let cid = dolbyVisionCompatibilityId {
                if cid == 1 { return "8.1" }
                if cid == 2 { return "8.2" }
                if cid == 4 { return "8.4" }
                return "8 (Compat \(cid))"
            }
            return "8.1"
        }
        if p == 5 { return "5" }
        if p == 7 { return "7" }
        if p == 9 { return "9" }
        return "\(p)"
    }
    public internal(set) var isAnnexBStream: Bool = false
    public var isHDR: Bool {
        if isDolbyVisionProfile5 { return true }
        if let p = dolbyVisionProfile {
            // Profile 8.2 has an SDR (BT.709) base layer; Profile 8.1 (PQ) and 8.4 (HLG) are HDR
            if p == 8 {
                if dolbyVisionCompatibilityId == 2 { return false }
                return true
            }
            if p == 5 || p == 7 { return true }
            if p == 9 { return false }  // Profile 9 is 8-bit AVC / SDR base layer
        }
        if transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            || transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG
        {
            return true
        }
        if colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020 && bitDepth >= 10 {
            return true
        }
        return false
    }
    var masteringDisplay: Data?
    var contentLightLevel: Data?
    /// CEA-608 fields the first pictures carry captions in (`ClosedCaptions.fields(of:)`), found while opening.
    var closedCaptionFields: Set<Int> = []

    /// Cancels this demuxer's blocking I/O; share one across demuxers to cancel a whole load.
    public typealias InterruptContext = FFmpegInterrupt

    private let interruptContext: InterruptContext
    private let ownsInterruptContext: Bool
    /// I/O lock is held across blocking `av_read_frame` / `av_seek_frame` calls (hundreds of ms on
    /// network streams); readers on the main thread must never contend with it.
    /// Lock order: `lock` -> the lock inside `subtitleTracker` (never the reverse).
    let lock = OSAllocatedUnfairLock()
    var isEOFInternal: Bool = false
    public var isEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEOFInternal
    }

    /// Returns human-readable error description from FFmpeg av_strerror.
    public static func ffmpegErrorDescription(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let res = av_strerror(code, &buffer, 256)
        if res == 0 {
            return buffer.withUnsafeBufferPointer { ptr in
                String(cString: ptr.baseAddress!)
            }
        }
        return "FFmpeg error (\(code))"
    }

    public convenience init?(url: String) {
        self.init(url: url, headers: [:], interruptContext: nil)
    }

    public init?(
        url: String,
        headers: [String: String] = [:],
        interruptContext: InterruptContext? = nil
    ) {
        let ctxContext = interruptContext ?? InterruptContext()
        self.interruptContext = ctxContext
        self.ownsInterruptContext = (interruptContext == nil)

        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocatedCtx = ctx else { return nil }

        // Setup interrupt callback to abort hung network requests cleanly.
        // `self.interruptContext` keeps a strong reference to `ctxContext` across the lifetime of MediaDemuxer.
        ctxContext.install(on: allocatedCtx)

        var avOptions: OpaquePointer? = nil
        defer {
            if avOptions != nil {
                av_dict_free(&avOptions)
            }
        }

        let isNetworkURL = MediaURL.isNetworkURL(url)
        if isNetworkURL {
            MediaURL.applyNetworkOptions(&avOptions, headers: headers)
        }

        let ret = avformat_open_input(&ctx, url, nil, &avOptions)
        guard ret >= 0, let formatCtx = ctx else {
            let errorMsg = Self.ffmpegErrorDescription(ret)
            ctxContext.recordError(code: ret, message: errorMsg)
            AppLog.error(.demuxer, "avformat_open_input failed with code \(ret) (\(errorMsg)) for '\(url)'")
            // Per FFmpeg avformat_open_input contract: user-allocated AVFormatContext is automatically freed on failure.
            return nil
        }
        self.formatCtx = formatCtx

        let streamInfoRet = avformat_find_stream_info(formatCtx, nil)
        guard streamInfoRet >= 0 else {
            let errorMsg = Self.ffmpegErrorDescription(streamInfoRet)
            ctxContext.recordError(code: streamInfoRet, message: errorMsg)
            AppLog.error(
                .demuxer, "avformat_find_stream_info failed with code \(streamInfoRet) (\(errorMsg)) for '\(url)'")
            avformat_close_input(&self.formatCtx)
            return nil
        }

        self.timelineOrigin = Self.timelineOrigin(of: formatCtx)
        // FFmpeg indexes what its seeks read past `readPacket` elsewhere (the MPEG-TS timestamp search, the generic
        // seek): only the index of Matroska and MP4 comes from the file.
        if !Self.describesStreams(formatCtx) { storeSubtitleIndex([:]) }
        if timelineOrigin != 0 {
            AppLog.info(
                .demuxer,
                "Rebasing timestamps to a zero timeline (start_time \(Double(timelineOrigin) / Double(AV_TIME_BASE))s)")
        }

        for i in 0..<Int(formatCtx.pointee.nb_streams) {
            let stream = formatCtx.pointee.streams[i]!
            let codecType = stream.pointee.codecpar.pointee.codec_type
            let isAttachedPic = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            if codecType == AVMEDIA_TYPE_VIDEO && !isAttachedPic && self.videoStreamIndex < 0,
                let detectedCodec = VideoCodec.from(codecId: stream.pointee.codecpar.pointee.codec_id)
            {
                configureVideoStream(stream, index: i, codec: detectedCodec, in: formatCtx)
            } else if codecType == AVMEDIA_TYPE_AUDIO {
                registerAudioTrack(stream, index: i)
            } else if codecType == AVMEDIA_TYPE_SUBTITLE {
                registerSubtitleTrack(stream, index: i)
            }

            // Extract embedded artwork (cover art / attached picture) if present
            if isAttachedPic, self.embeddedArtworkData == nil {
                let attachedPic = stream.pointee.attached_pic
                if let picData = attachedPic.data, attachedPic.size > 0 {
                    self.embeddedArtworkData = Data(bytes: picData, count: Int(attachedPic.size))
                }
            }
        }

        if videoStreamIndex >= 0 {
            self.hasVideo = true
            self.formatDescription = extractVideoFormatDescription()
            registerClosedCaptionTracks()
        } else if audioStreamIndex >= 0 {
            self.hasVideo = false
            self.timebase = self.audioTimebase
            let stream = formatCtx.pointee.streams[audioStreamIndex]!
            if stream.pointee.duration > 0 {
                self.durationSeconds = Double(stream.pointee.duration) * Double(timebase.num) / Double(timebase.den)
            } else if formatCtx.pointee.duration > 0 {
                self.durationSeconds = Double(formatCtx.pointee.duration) / Double(AV_TIME_BASE)
            }
        } else {
            avformat_close_input(&self.formatCtx)
            return nil
        }

        self.chapters = MediaChapter.normalized(Self.readChapters(from: formatCtx), duration: durationSeconds)
    }

    /// MPEG-TS / MPEG-PS: no index, and timestamps that continue the source clock. Seeking there bisects on
    /// timestamps and lands on whichever packet is nearest, not on a keyframe.
    /// Matroska and MP4: their header describes every stream (codec, parameters, time base) and their index comes from
    /// the file (Cues, the sample table), with a timeline that starts at zero.
    static func describesStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        guard let iformat = ctx.pointee.iformat else { return false }
        let name = String(cString: iformat.pointee.name)
        return name.hasPrefix("matroska") || name.hasPrefix("mov")
    }

    package static func isUnindexedStream(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        guard let iformat = ctx.pointee.iformat else { return false }
        return (iformat.pointee.flags & AVFMT_TS_DISCONT) != 0
    }

    /// Start of the playback timeline in `AV_TIME_BASE` units. MPEG-TS / MPEG-PS timestamps continue the
    /// source's clock (a DVD starts around 0.5 s, a broadcast capture hours in), so their first timestamp
    /// becomes zero. Other containers already start near zero (or slightly before, via edit lists) and
    /// are left as they are.
    package static func timelineOrigin(of ctx: UnsafeMutablePointer<AVFormatContext>) -> Int64 {
        guard isUnindexedStream(ctx),
            ctx.pointee.start_time != Int64.min, ctx.pointee.start_time > 0
        else { return 0 }
        return ctx.pointee.start_time
    }

    /// `origin` (`AV_TIME_BASE` units) in the time base of `stream`.
    package static func timelineOffset(_ origin: Int64, in timebase: AVRational) -> Int64 {
        guard origin != 0, timebase.num > 0, timebase.den > 0 else { return 0 }
        return av_rescale_q(origin, AVRational(num: 1, den: AV_TIME_BASE), timebase)
    }

    /// Moves a packet's timestamps onto the zero-based timeline (see `timelineOrigin(of:)`).
    package static func rebase(
        _ pkt: inout AVPacket, origin: Int64, in ctx: UnsafeMutablePointer<AVFormatContext>
    ) {
        guard origin != 0, pkt.stream_index >= 0, pkt.stream_index < Int32(ctx.pointee.nb_streams),
            let stream = ctx.pointee.streams[Int(pkt.stream_index)]
        else { return }
        let offset = timelineOffset(origin, in: stream.pointee.time_base)
        if pkt.pts != Int64.min { pkt.pts -= offset }
        if pkt.dts != Int64.min { pkt.dts -= offset }
    }

    /// `AVERROR_EOF` (`-MKTAG('E', 'O', 'F', ' ')`); the macro does not import into Swift.
    static let averrorEOF: Int32 = -0x2046_4F45

    /// `av_read_frame` with timestamps on the zero-based timeline. Records how far audio and video have been read
    /// (`readAheadSeconds`), and hands subtitle packets to `subtitleTracker`, as playback takes embedded subtitles in
    /// band: the main way for every source. A network source is opened again only to read its index and the windows
    /// that index tells of; a server with a single connection fails the index read, and no window is read.
    func readPacket(_ ctx: UnsafeMutablePointer<AVFormatContext>, _ pkt: inout AVPacket) -> Int32 {
        let ret = av_read_frame(ctx, &pkt)
        if ret >= 0 {
            Self.rebase(&pkt, origin: timelineOrigin, in: ctx)
            recordReadAhead(pkt, in: ctx)
            subtitleTracker.readPacket(&pkt, in: ctx)
        } else if ret == Self.averrorEOF {
            readAheadState.withLock { $0 = .infinity }
            subtitleTracker.finishCaptions()
        }
        return ret
    }

    /// End of a packet (`pts` plus a positive `duration`), saturating instead of trapping on the corrupt timestamps
    /// near `Int64.max` a damaged stream can carry.
    static func packetEnd(pts: Int64, duration: Int64) -> Int64 {
        let (end, overflow) = pts.addingReportingOverflow(max(duration, 0))
        return overflow ? .max : end
    }

    private func recordReadAhead(_ pkt: AVPacket, in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard pkt.stream_index == videoStreamIndex || pkt.stream_index == audioStreamIndex,
            let stream = ctx.pointee.streams[Int(pkt.stream_index)]
        else { return }
        let timebase = stream.pointee.time_base
        let start = pkt.pts != Int64.min ? pkt.pts : pkt.dts
        guard start != Int64.min, timebase.num > 0, timebase.den > 0 else { return }
        let end =
            Double(Self.packetEnd(pts: start, duration: pkt.duration)) * Double(timebase.num) / Double(timebase.den)
        readAheadState.withLock { $0 = max($0, end) }
    }

    var targetPts: Int64 = -1
    /// `timelineOrigin(of:)` of this file; subtracted from every packet read, added back when seeking.
    var timelineOrigin: Int64 = 0
    var targetAudioPts: Int64 = -1

    public func nextVideoSample() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }

        // Drain videoQueue first if audio reading buffered video packets
        while let vp = videoQueue.popFirst() {
            if let sample = createVideoSample(from: vp.data, pts: vp.pts, dts: vp.dts, duration: vp.duration) {
                return sample
            }
        }

        guard let ctx = formatCtx, formatDescription != nil else { return nil }

        var pkt = AVPacket()
        while readPacket(ctx, &pkt) >= 0 {
            if pkt.stream_index == videoStreamIndex {
                subtitleTracker.processVideoPacket(&pkt)
                let sample = createVideoSample(
                    bytes: pkt.data,
                    count: Int(pkt.size),
                    pts: pkt.pts,
                    dts: pkt.dts,
                    duration: pkt.duration
                )
                av_packet_unref(&pkt)
                if let sample {
                    return sample
                }
            } else if pkt.stream_index == audioStreamIndex {
                // Buffer audio packet for Stage 2 audio pipeline
                audioQueue.append(DemuxedAudioPacket(pkt))
                av_packet_unref(&pkt)
            } else {
                av_packet_unref(&pkt)
            }
        }
        if videoQueue.isEmpty && audioQueue.isEmpty {
            self.isEOFInternal = true
        }
        return nil
    }

    /// Retrieves next queued audio packet if available, or pumps stream until one arrives
    public func nextAudioPacket() -> DemuxedAudioPacket? {
        lock.lock()
        defer { lock.unlock() }

        while let p = audioQueue.popFirst() {
            if targetAudioPts >= 0 {
                let packetEndPts = Self.packetEnd(pts: p.pts, duration: p.duration)
                if packetEndPts < targetAudioPts {
                    continue
                }
                targetAudioPts = -1
            }
            self.lastAudioPts = p.pts
            return p
        }

        // If audio queue is empty, pump demuxer to find the next audio packet
        guard let ctx = formatCtx, audioStreamIndex >= 0 else { return nil }

        // Backpressure check: if videoQueue is already large, don't read endlessly ahead
        if videoQueue.count >= maxVideoQueueCount {
            return nil
        }

        var pkt = AVPacket()
        while readPacket(ctx, &pkt) >= 0 {
            if pkt.stream_index == audioStreamIndex {
                let pktPts = pkt.pts
                let pktDuration = pkt.duration
                if targetAudioPts >= 0 {
                    let packetEndPts = Self.packetEnd(pts: pktPts, duration: pktDuration)
                    if packetEndPts < targetAudioPts {
                        av_packet_unref(&pkt)
                        continue
                    }
                    targetAudioPts = -1
                }
                let audioPacket = DemuxedAudioPacket(pkt)
                self.lastAudioPts = pktPts
                av_packet_unref(&pkt)
                return audioPacket
            } else if pkt.stream_index == videoStreamIndex {
                // Symmetric buffering: preserve ALL video packets without dropping GOP frames!
                subtitleTracker.processVideoPacket(&pkt)
                let videoPacket = DemuxedVideoPacket(pkt)
                videoQueue.append(videoPacket)
                av_packet_unref(&pkt)
            } else {
                av_packet_unref(&pkt)
            }
        }
        if videoQueue.isEmpty && audioQueue.isEmpty {
            self.isEOFInternal = true
        }
        return nil
    }

    public func cancel() {
        interruptContext.cancel()
    }

    deinit {
        if ownsInterruptContext {
            interruptContext.cancel()
        }
        lock.lock()
        defer { lock.unlock() }
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
        }
    }
}
