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

    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int = -1
    private var audioStreamIndex: Int = -1
    public private(set) var timebase: AVRational = AVRational(num: 1, den: 1000)
    public private(set) var audioTimebase: AVRational = AVRational(num: 1, den: 1000)
    public private(set) var codec: VideoCodec = .hevc
    public private(set) var hasVideo: Bool = false
    public private(set) var nominalFrameDuration: Double = 1.0 / 24.0
    /// The stream is interlaced: it signals a field order (`field_order` TT / BB / TB / BT), or it is standard
    /// definition DV, interlaced by format but without a field order. Frames may still be flagged interlaced
    /// individually when this is `false`.
    public private(set) var isInterlaced: Bool = false
    public private(set) var hasAudio: Bool = false
    public private(set) var audioCodecId: AVCodecID = AV_CODEC_ID_NONE
    public private(set) var audioChannels: Int = 0
    public private(set) var audioSampleRate: Int = 0
    public struct AudioTrack: Sendable, Identifiable, Equatable {
        public let id: Int
        public let streamIndex: Int
        public let title: String
        public let language: String
        public let codecName: String
        public let channels: Int
        public let sampleRate: Int
    }

    public private(set) var audioTracks: [AudioTrack] = []
    public private(set) var selectedAudioTrackIndex: Int = -1
    public private(set) var audioExtraData: Data? = nil
    public private(set) var embeddedArtworkData: Data? = nil
    public private(set) var chapters: [MediaChapter] = []

    public private(set) var subtitleTracks: [SubtitleTrack] = []
    public private(set) var selectedSubtitleTrackId: Int? = nil
    private var selectedSubtitleStreamIndex: Int = -1
    /// Whether pictures and ASS events are collected as packets pass: for network sources only, which can't be read
    /// whole. A local file is read whole by `EmbeddedSubtitleReader`, and a list growing all through playback would
    /// only hold memory.
    private var collectsLiveSubtitles = false
    private struct LiveSubtitleState {
        var cues: [SubtitleCue] = []
        var imageCues: [SubtitleImageCue] = []
        /// The script of the selected ASS / SSA track: header and fonts from the stream, events as they are read.
        var assScript: AssScript?
        /// Payloads of the events in `assScript`, to leave out an event read again.
        var assPayloads: Set<String> = []
        var version: Int = 0
    }
    /// Decodes the selected track when it is a bitmap one; used under `lock`, like `processSubtitlePacket`.
    private var liveBitmapDecoder: BitmapSubtitleDecoder?
    /// Live in-band subtitle state is guarded by its own lightweight lock, NOT the I/O `lock`.
    /// `lock` is held across blocking `av_read_frame` / `av_seek_frame` calls (hundreds of ms on
    /// network streams); readers on the main thread must never contend with it.
    /// Lock order: `lock` -> `liveSubtitleState` (never the reverse).
    private let liveSubtitleState = OSAllocatedUnfairLock(initialState: LiveSubtitleState())
    public var liveSubtitleVersion: Int {
        liveSubtitleState.withLock { $0.version }
    }
    private var cachedSubtitleDocuments: [Int: SubtitleDocument] = [:]
    /// Furthest timeline second read from the audio and video streams since the last seek (`-infinity` before any),
    /// `infinity` once the input has been read to its end. Its own lock: `lock` is held through blocking reads.
    private let readAheadState = OSAllocatedUnfairLock(initialState: -Double.infinity)
    /// Timeline second up to which packets have been read ahead of playback; see `readAheadState`.
    public var readAheadSeconds: Double {
        readAheadState.withLock { $0 }
    }
    private var lastAudioPts: Int64 = -1
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
        liveSubtitleState.withLock { state in
            state.cues.removeAll()
            state.imageCues.removeAll()
            state.assScript = nil
            state.assPayloads.removeAll()
            state.version += 1
        }
        liveBitmapDecoder = nil
        if let trackId, let track = subtitleTracks.first(where: { $0.id == trackId }) {
            self.selectedSubtitleStreamIndex = track.streamIndex
            if collectsLiveSubtitles, track.format == .ass, let ctx = formatCtx,
                track.streamIndex < Int(ctx.pointee.nb_streams),
                let stream = ctx.pointee.streams[track.streamIndex]
            {
                let script = AssScript(
                    header: EmbeddedSubtitleReader.assHeader(of: stream),
                    fonts: EmbeddedSubtitleReader.attachedFonts(in: ctx))
                liveSubtitleState.withLock { $0.assScript = script }
            }
            if collectsLiveSubtitles, track.format == .bitmap, let ctx = formatCtx,
                track.streamIndex < Int(ctx.pointee.nb_streams),
                let stream = ctx.pointee.streams[track.streamIndex]
            {
                liveBitmapDecoder = BitmapSubtitleDecoder(stream: stream)
            }
            AppLog.info(
                .subtitles,
                "Subtitle track selected: id=\(trackId), streamIndex=\(track.streamIndex), title='\(track.title)'"
            )
        } else {
            self.selectedSubtitleStreamIndex = -1
        }
    }

    /// Returns a SubtitleDocument with all cues collected in-band so far for the active subtitle track.
    /// Never touches the I/O lock, so it is safe to call from the main thread during network reads/seeks.
    public func getLiveSubtitleDocument() -> SubtitleDocument {
        let (cues, imageCues, script) = liveSubtitleState.withLock { ($0.cues, $0.imageCues, $0.assScript) }
        return SubtitleDocument(cues: cues, imageCues: imageCues, assScript: script)
    }

    /// Retrieves or loads on demand the SubtitleDocument for a given track id. `interrupt` aborts the read of a local
    /// file, which then returns `nil`.
    public func loadSubtitleDocument(
        for trackId: Int, url: String, headers: [String: String], interrupt: InterruptContext? = nil
    ) -> SubtitleDocument? {
        lock.lock()
        if let cached = cachedSubtitleDocuments[trackId] {
            lock.unlock()
            return cached
        }
        guard let track = subtitleTracks.first(where: { $0.id == trackId }) else {
            lock.unlock()
            return nil
        }
        let isNetwork = MediaURL.isNetworkURL(url)
        lock.unlock()

        // For network streams, do NOT spin a secondary demuxer loop to EOF.
        // Return whatever live in-band cues we have collected so far.
        if isNetwork {
            return getLiveSubtitleDocument()
        }

        // For local files, secondary background extraction can index the entire file quickly.
        let doc = EmbeddedSubtitleReader.extractEmbeddedSubtitles(
            url: url, headers: headers, streamIndex: track.streamIndex, interrupt: interrupt)
        if let doc {
            lock.lock()
            self.cachedSubtitleDocuments[trackId] = doc
            lock.unlock()
        }
        return doc
    }

    /// Ingests a subtitle packet into liveSubtitleCues (called with lock held).
    private func processSubtitlePacket(_ pkt: UnsafeMutablePointer<AVPacket>) {
        guard let ctx = formatCtx, selectedSubtitleStreamIndex >= 0,
            selectedSubtitleStreamIndex < Int(ctx.pointee.nb_streams),
            let stream = ctx.pointee.streams[selectedSubtitleStreamIndex]
        else { return }

        if let liveBitmapDecoder {
            let output = liveBitmapDecoder.decode(pkt)
            liveSubtitleState.withLock { state in
                // A seek back decodes sets that are there already.
                if state.imageCues.apply(output, deduplicating: true) { state.version += 1 }
            }
            return
        }

        let timebase = stream.pointee.time_base
        let codecId = stream.pointee.codecpar.pointee.codec_id
        // Only a selected ASS track keeps events (the script is there then); other codecs aren't decoded for them.
        if liveSubtitleState.withLock({ $0.assScript != nil }),
            let event = EmbeddedSubtitleReader.assEvent(from: pkt, timebase: timebase)
        {
            liveSubtitleState.withLock { state in
                // A seek back reads events again; libass drops a repeated ReadOrder, but the list shouldn't grow.
                guard state.assScript != nil, state.assPayloads.insert(event.payload).inserted else { return }
                state.assScript?.events.append(event)
                state.version += 1
            }
        }
        let nextIndex = liveSubtitleState.withLock { $0.cues.count } + 1

        guard
            let newCue = EmbeddedSubtitleReader.parseSubtitleCue(
                pkt: pkt, timebase: timebase, codecId: codecId, cueIndex: nextIndex)
        else {
            return
        }

        liveSubtitleState.withLock { state in
            // Avoid adding duplicate cues if stream loops, repeats packets, or seeks backward
            if state.cues.contains(where: { abs($0.startTime - newCue.startTime) < 0.05 && $0.text == newCue.text }) {
                return
            }
            state.cues.append(newCue)
            state.version += 1
        }
    }

    // Packet queue for demuxed audio packets
    public struct DemuxedAudioPacket: Sendable {
        public let data: Data
        public let pts: Int64
        public let dts: Int64
        public let duration: Int64
        public let isKeyFrame: Bool
    }

    /// Copies an audio packet's payload and timing out of FFmpeg's buffer.
    private static func makeAudioPacket(_ pkt: AVPacket) -> DemuxedAudioPacket {
        DemuxedAudioPacket(
            data: Data(bytes: pkt.data, count: Int(pkt.size)),
            pts: pkt.pts,
            dts: pkt.dts,
            duration: pkt.duration,
            isKeyFrame: (pkt.flags & AV_PKT_FLAG_KEY) != 0
        )
    }

    // Packet queue for demuxed video packets (preserves video if audio pump reads ahead)
    private struct DemuxedVideoPacket: Sendable {
        let data: Data
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let flags: Int32
    }

    /// Fast FIFO queue avoiding O(N) array shifts on pop.
    private struct PacketFifoQueue<T: Sendable>: Sendable {
        private var elements: [T?] = []
        private var headIndex: Int = 0

        var isEmpty: Bool {
            headIndex >= elements.count
        }

        var count: Int {
            max(0, elements.count - headIndex)
        }

        mutating func append(_ element: T) {
            elements.append(element)
        }

        mutating func popFirst() -> T? {
            guard headIndex < elements.count else { return nil }
            let element = elements[headIndex]
            elements[headIndex] = nil
            headIndex += 1
            // Periodically compact buffer to prevent unbounded growth while preserving O(1) amortized pop
            if headIndex > 64 && headIndex * 2 >= elements.count {
                elements.removeFirst(headIndex)
                headIndex = 0
            }
            return element
        }

        mutating func removeAll(keepingCapacity: Bool = false) {
            elements.removeAll(keepingCapacity: keepingCapacity)
            headIndex = 0
        }

        mutating func removeAll(where shouldBeRemoved: (T) -> Bool) {
            var active: [T] = []
            active.reserveCapacity(count)
            for i in headIndex..<elements.count {
                if let el = elements[i], !shouldBeRemoved(el) {
                    active.append(el)
                }
            }
            elements = active.map { Optional($0) }
            headIndex = 0
        }
    }

    private var audioQueue = PacketFifoQueue<DemuxedAudioPacket>()
    private var videoQueue = PacketFifoQueue<DemuxedVideoPacket>()
    private let maxAudioQueueCount = 500
    private let maxVideoQueueCount = 180
    public private(set) var formatDescription: CMVideoFormatDescription?
    public private(set) var durationSeconds: Double = 0
    public private(set) var width: Int = 0
    public private(set) var height: Int = 0
    /// Sample Aspect Ratio (Pixel Aspect Ratio) from stream metadata (e.g. 720:959 or 1:1)
    public private(set) var sampleAspectRatio: RationalAspectRatio = .square
    /// Effective Display Aspect Ratio (DAR) taking SAR into account: (width * sar.multiplier) / height
    public var displayAspectRatio: Double {
        RationalAspectRatio.computeDisplayAspectRatio(width: width, height: height, sar: sampleAspectRatio)
    }
    public private(set) var maxPeakNits: Float = 1000.0
    public private(set) var maxFallNits: Float = 0.0
    public private(set) var colorPrimaries: CFString = kCVImageBufferColorPrimaries_ITU_R_709_2
    public private(set) var transferFunction: CFString = kCVImageBufferTransferFunction_ITU_R_709_2
    public private(set) var yCbCrMatrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    public private(set) var isFullRange: Bool = false
    public private(set) var bitDepth: Int = 8
    public private(set) var isDolbyVisionProfile5: Bool = false
    public private(set) var dolbyVisionProfile: Int? = nil
    public private(set) var dolbyVisionCompatibilityId: Int? = nil
    public private(set) var dolbyVisionConfigData: Data? = nil
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
    public private(set) var isAnnexBStream: Bool = false
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
    private var masteringDisplay: Data?
    private var contentLightLevel: Data?

    /// Cancels this demuxer's blocking I/O; share one across demuxers to cancel a whole load.
    public typealias InterruptContext = FFmpegInterrupt

    private let interruptContext: InterruptContext
    private let ownsInterruptContext: Bool
    private let lock = OSAllocatedUnfairLock()
    private var isEOFInternal: Bool = false
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
        self.collectsLiveSubtitles = isNetworkURL

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

    // MARK: - Stream discovery

    /// Adopts `stream` as the video stream: geometry, timing, colorimetry, Dolby Vision and HDR metadata.
    private func configureVideoStream(
        _ stream: UnsafeMutablePointer<AVStream>, index: Int, codec detectedCodec: VideoCodec,
        in formatCtx: UnsafeMutablePointer<AVFormatContext>
    ) {
        let codecpar = stream.pointee.codecpar!
        self.videoStreamIndex = index
        self.timebase = stream.pointee.time_base
        self.codec = detectedCodec
        self.width = Int(codecpar.pointee.width)
        self.height = Int(codecpar.pointee.height)

        // Guess or extract Sample Aspect Ratio (SAR / PAR)
        let guessedSAR = av_guess_sample_aspect_ratio(formatCtx, stream, nil)
        if guessedSAR.num > 0 && guessedSAR.den > 0 {
            self.sampleAspectRatio = RationalAspectRatio(
                numerator: Int(guessedSAR.num), denominator: Int(guessedSAR.den))
        } else if stream.pointee.sample_aspect_ratio.num > 0 && stream.pointee.sample_aspect_ratio.den > 0 {
            self.sampleAspectRatio = RationalAspectRatio(
                numerator: Int(stream.pointee.sample_aspect_ratio.num),
                denominator: Int(stream.pointee.sample_aspect_ratio.den)
            )
        } else if codecpar.pointee.sample_aspect_ratio.num > 0 && codecpar.pointee.sample_aspect_ratio.den > 0 {
            self.sampleAspectRatio = RationalAspectRatio(
                numerator: Int(codecpar.pointee.sample_aspect_ratio.num),
                denominator: Int(codecpar.pointee.sample_aspect_ratio.den)
            )
        } else {
            self.sampleAspectRatio = .square
        }

        if stream.pointee.duration > 0 {
            self.durationSeconds = Double(stream.pointee.duration) * Double(timebase.num) / Double(timebase.den)
        } else if formatCtx.pointee.duration > 0 {
            self.durationSeconds = Double(formatCtx.pointee.duration) / Double(AV_TIME_BASE)
        }

        // Nominal frame duration from the average frame rate, else the base rate (DV can report an average of
        // 60000 fps), within a sanity range of 1 to 240 fps.
        let plausibleDuration = { (rate: AVRational) -> Double? in
            guard rate.num > 0 && rate.den > 0 else { return nil }
            let duration = Double(rate.den) / Double(rate.num)
            return duration >= (1.0 / 240.0) && duration <= 1.0 ? duration : nil
        }
        self.nominalFrameDuration =
            plausibleDuration(stream.pointee.avg_frame_rate) ?? plausibleDuration(stream.pointee.r_frame_rate)
            ?? (1.0 / 24.0)

        let fieldOrder = codecpar.pointee.field_order
        let isStandardDefinitionDV = codecpar.pointee.codec_id == AV_CODEC_ID_DVVIDEO && height <= 576
        self.isInterlaced =
            fieldOrder == AV_FIELD_UNKNOWN ? isStandardDefinitionDV : fieldOrder != AV_FIELD_PROGRESSIVE

        let colorimetry = StreamColorimetry(codecParameters: codecpar, width: width, height: height)
        self.colorPrimaries = colorimetry.colorPrimaries
        self.transferFunction = colorimetry.transferFunction
        self.yCbCrMatrix = colorimetry.yCbCrMatrix
        self.isFullRange = colorimetry.isFullRange
        self.bitDepth = colorimetry.bitDepth

        // Dolby Vision Detection (Profiles 5, 8.1, 8.4):
        // In MP4/MKV it is identified by dvvC/dvcC box (or stream side data).
        // Profile 5 uses IPTc2 color space with PQ transfer function.
        // Profile 8 uses standard BT.2020 PQ (8.1) or HLG (8.4) with dynamic RPU metadata.
        if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size >= 24 {
            let extraData = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            if let parsed = HDRMetadataEncoding.parseDolbyVisionConfigurationBox(from: extraData) {
                self.dolbyVisionProfile = parsed.profile
                self.dolbyVisionCompatibilityId = parsed.compatibilityId
                self.dolbyVisionConfigData = parsed.configData
                self.bitDepth = 10
                if parsed.profile == 5 {
                    self.isDolbyVisionProfile5 = true
                }
                AppLog.info(
                    .video,
                    "Detected Dolby Vision Profile \(parsed.profile) (dvcC/dvvC payload: \(parsed.configData.count) bytes, compatibility id: \(parsed.compatibilityId))"
                )
            }
        }

        readHDRSideData(of: codecpar)
    }

    /// Dolby Vision configuration (when extradata had none), content light level and mastering display from
    /// the stream's coded side data. Mastering luminance only fills in a peak still at its 1000-nit default.
    private func readHDRSideData(of codecpar: UnsafeMutablePointer<AVCodecParameters>) {
        let sideDataCount = Int(codecpar.pointee.nb_coded_side_data)
        guard sideDataCount > 0, let sideDataList = codecpar.pointee.coded_side_data else { return }
        for s in 0..<sideDataCount {
            let sd = sideDataList[s]
            if self.dolbyVisionProfile == nil && sd.type == AV_PKT_DATA_DOVI_CONF, let sdData = sd.data,
                sd.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            {
                let doviConf = UnsafeMutableRawPointer(sdData).assumingMemoryBound(
                    to: AVDOVIDecoderConfigurationRecord.self)
                let dvProfile = Int(doviConf.pointee.dv_profile)
                let compatId = Int(doviConf.pointee.dv_bl_signal_compatibility_id & 0x0F)
                self.dolbyVisionProfile = dvProfile
                self.dolbyVisionCompatibilityId = compatId
                self.bitDepth = 10
                if dvProfile == 5 {
                    self.isDolbyVisionProfile5 = true
                }
                self.dolbyVisionConfigData = HDRMetadataEncoding.dolbyVisionConfigurationBox(doviConf.pointee)
                AppLog.info(
                    .video,
                    "Detected Dolby Vision Profile \(dvProfile) via FFmpeg side data (compatibility id: \(compatId))"
                )
            } else if sd.type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL, let sdData = sd.data,
                sd.size >= MemoryLayout<AVContentLightMetadata>.size
            {
                let clm = UnsafeMutableRawPointer(sdData).assumingMemoryBound(to: AVContentLightMetadata.self)
                if clm.pointee.MaxCLL > 0 {
                    self.maxPeakNits = Float(clm.pointee.MaxCLL)
                }
                if clm.pointee.MaxFALL > 0 {
                    self.maxFallNits = Float(clm.pointee.MaxFALL)
                }
                self.contentLightLevel = HDRMetadataEncoding.contentLightLevelInfo(clm.pointee)
                AppLog.info(
                    .video,
                    "Extracted ContentLightLevel from side data: MaxCLL=\(clm.pointee.MaxCLL), MaxFALL=\(clm.pointee.MaxFALL)"
                )
            } else if sd.type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA, let sdData = sd.data,
                sd.size >= MemoryLayout<AVMasteringDisplayMetadata>.size
            {
                let mdm = UnsafeMutableRawPointer(sdData).assumingMemoryBound(to: AVMasteringDisplayMetadata.self)
                if mdm.pointee.has_luminance != 0 && mdm.pointee.max_luminance.den > 0 {
                    let maxLum = Float(mdm.pointee.max_luminance.num) / Float(mdm.pointee.max_luminance.den)
                    if self.maxPeakNits == 1000.0 && maxLum > 0 {
                        self.maxPeakNits = maxLum
                    }
                }
                if mdm.pointee.has_primaries != 0 && mdm.pointee.has_luminance != 0 {
                    self.masteringDisplay = HDRMetadataEncoding.masteringDisplayColourVolume(mdm.pointee)
                }
            }
        }
    }

    /// Lists an audio stream as a track; the first one becomes the active track.
    private func registerAudioTrack(_ stream: UnsafeMutablePointer<AVStream>, index: Int) {
        let codecId = stream.pointee.codecpar.pointee.codec_id
        // Read track metadata (title, language)
        var title = ""
        var lang = ""
        if let titleTag = av_dict_get(stream.pointee.metadata, "title", nil, 0) {
            title = String(cString: titleTag.pointee.value)
        }
        if let langTag = av_dict_get(stream.pointee.metadata, "language", nil, 0) {
            lang = String(cString: langTag.pointee.value)
        }
        let codecNameStr: String
        if let codecDesc = avcodec_descriptor_get(codecId), let name = codecDesc.pointee.name {
            codecNameStr = String(cString: name)
        } else {
            codecNameStr = "audio"
        }

        let track = AudioTrack(
            id: self.audioTracks.count,
            streamIndex: index,
            title: title,
            language: lang,
            codecName: codecNameStr,
            channels: Int(stream.pointee.codecpar.pointee.ch_layout.nb_channels),
            sampleRate: Int(stream.pointee.codecpar.pointee.sample_rate)
        )
        self.audioTracks.append(track)

        if self.audioStreamIndex < 0 {
            // First audio stream found - select as default
            self.audioStreamIndex = index
            self.selectedAudioTrackIndex = track.id
            self.audioTimebase = stream.pointee.time_base
            self.audioCodecId = codecId
            self.hasAudio = true
            self.audioChannels = track.channels
            self.audioSampleRate = track.sampleRate
            if let ed = stream.pointee.codecpar.pointee.extradata, stream.pointee.codecpar.pointee.extradata_size > 0 {
                self.audioExtraData = Data(bytes: ed, count: Int(stream.pointee.codecpar.pointee.extradata_size))
            }
        }
    }

    /// Whether a subtitle stream is forced or for the hard of hearing: Matroska and MP4 flag the stream itself, and many
    /// files leave the title empty; older ones only say so in the title.
    static func subtitleFlags(title: String, disposition: Int32) -> (isForced: Bool, isSDH: Bool) {
        (
            (disposition & AV_DISPOSITION_FORCED) != 0 || title.localizedCaseInsensitiveContains("forced"),
            (disposition & AV_DISPOSITION_HEARING_IMPAIRED) != 0 || title.localizedCaseInsensitiveContains("sdh")
        )
    }

    /// Lists a text (SRT, WebVTT, mov_text, ASS, SSA) or bitmap (PGS, VobSub, DVB) subtitle stream as a track.
    private func registerSubtitleTrack(_ stream: UnsafeMutablePointer<AVStream>, index: Int) {
        let codecId = stream.pointee.codecpar.pointee.codec_id
        let isTextSub =
            (codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_WEBVTT || codecId == AV_CODEC_ID_MOV_TEXT
                || codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA)
        let isBitmapSub = BitmapSubtitleDecoder.isBitmapCodec(codecId)
        guard isTextSub || isBitmapSub else { return }
        var title = ""
        var lang = ""
        if let titleTag = av_dict_get(stream.pointee.metadata, "title", nil, 0) {
            title = String(cString: titleTag.pointee.value)
        }
        if let langTag = av_dict_get(stream.pointee.metadata, "language", nil, 0) {
            lang = String(cString: langTag.pointee.value)
        }
        let (isForced, isSDH) = Self.subtitleFlags(title: title, disposition: stream.pointee.disposition)
        let displayTitle =
            title.isEmpty
            ? (lang.isEmpty ? "Subtitle \(self.subtitleTracks.count + 1)" : lang.uppercased()) : title

        let subTrack = SubtitleTrack(
            id: self.subtitleTracks.count,
            streamIndex: index,
            title: displayTitle,
            language: lang,
            isForced: isForced,
            isSDH: isSDH,
            format: isBitmapSub ? .bitmap : (codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA ? .ass : .text)
        )
        self.subtitleTracks.append(subTrack)
    }

    /// Container chapters as FFmpeg exports them (MKV default edition, flattened; MP4 chapter track or
    /// Nero `chpl`). Chapters without a start are skipped; an unset end stays `nil`.
    private static func readChapters(from formatCtx: UnsafeMutablePointer<AVFormatContext>) -> [MediaChapter.Raw] {
        let count = Int(formatCtx.pointee.nb_chapters)
        guard count > 0, let list = formatCtx.pointee.chapters else { return [] }
        let noPTS = Int64.min  // AV_NOPTS_VALUE
        return (0..<count).compactMap { index in
            guard let chapter = list[index]?.pointee, chapter.start != noPTS,
                chapter.time_base.num > 0, chapter.time_base.den > 0
            else { return nil }
            let num = Double(chapter.time_base.num)
            let den = Double(chapter.time_base.den)
            let title = av_dict_get(chapter.metadata, "title", nil, 0).map { String(cString: $0.pointee.value) }
            return MediaChapter.Raw(
                title: title,
                start: Double(chapter.start) * num / den,
                end: chapter.end != noPTS && chapter.end > chapter.start ? Double(chapter.end) * num / den : nil
            )
        }
    }

    /// MPEG-TS / MPEG-PS: no index, and timestamps that continue the source clock. Seeking there bisects on
    /// timestamps and lands on whichever packet is nearest, not on a keyframe.
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
    /// (`readAheadSeconds`).
    private func readPacket(_ ctx: UnsafeMutablePointer<AVFormatContext>, _ pkt: inout AVPacket) -> Int32 {
        let ret = av_read_frame(ctx, &pkt)
        if ret >= 0 {
            Self.rebase(&pkt, origin: timelineOrigin, in: ctx)
            recordReadAhead(pkt, in: ctx)
        } else if ret == Self.averrorEOF {
            readAheadState.withLock { $0 = .infinity }
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

    private func extractVideoFormatDescription() -> CMVideoFormatDescription? {
        guard let ctx = formatCtx else { return nil }
        let codecParameters: UnsafePointer<AVCodecParameters>? =
            videoStreamIndex >= 0
            ? ctx.pointee.streams[videoStreamIndex].map { UnsafePointer($0.pointee.codecpar) } : nil

        // Step 1: Try parsing from container extradata (avcC / hvcC / Annex B header)
        var parameterSets = VideoFormatDescriptionBuilder.ParameterSets()
        if let codecpar = codecParameters, let extradata = codecpar.pointee.extradata,
            codecpar.pointee.extradata_size > 0,
            let parsed = VideoFormatDescriptionBuilder.parameterSets(
                fromExtradata: Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size)), codec: codec)
        {
            parameterSets = parsed.sets
            self.isAnnexBStream = parsed.isAnnexB
        }
        var (vps, sps, pps) = (parameterSets.vps, parameterSets.sps, parameterSets.pps)
        var masteringDisplay: Data?
        var contentLightLevel: Data?

        let hasExtradataParams: Bool
        if codec == .hevc {
            hasExtradataParams = (vps != nil && sps != nil && pps != nil)
        } else {
            hasExtradataParams = (sps != nil && pps != nil)
        }

        // Step 2: Fallback to scanning packets if extradata is missing or for SEI mastering info
        var packetsScanned = 0
        let maxPacketsToScan = hasExtradataParams ? 30 : 120
        var pkt = AVPacket()

        while packetsScanned < maxPacketsToScan && readPacket(ctx, &pkt) >= 0 {
            packetsScanned += 1
            if pkt.stream_index == videoStreamIndex {
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                // If extradata was missing or empty, detect whether the stream is Annex B from the first video packet
                if !hasExtradataParams && packetsScanned == 1 && data.count >= 3 {
                    if data[0] == 0 && data[1] == 0
                        && (data[2] == 1 || (data.count > 3 && data[2] == 0 && data[3] == 1))
                    {
                        self.isAnnexBStream = true
                    }
                }
                let nalus = NALUnitParser.extractNALUnits(from: data, isAnnexB: self.isAnnexBStream)
                for naluData in nalus {
                    guard !naluData.isEmpty else { continue }
                    if codec == .hevc {
                        let nalType = (naluData[0] >> 1) & 0x3F
                        if vps == nil && nalType == 32 {
                            vps = naluData
                        } else if sps == nil && nalType == 33 {
                            sps = naluData
                        } else if pps == nil && nalType == 34 {
                            pps = naluData
                        } else if nalType == 39 {
                            applyHDRSEI(
                                naluData: naluData, masteringDisplay: &masteringDisplay,
                                contentLightLevel: &contentLightLevel)
                        }
                    } else if codec == .h264 {
                        let nalType = naluData[0] & 0x1F
                        if sps == nil && nalType == 7 {
                            sps = naluData
                        } else if pps == nil && nalType == 8 {
                            pps = naluData
                        }
                    }
                }
                av_packet_unref(&pkt)

                let hasParameters: Bool
                if codec == .hevc {
                    hasParameters = (vps != nil && sps != nil && pps != nil)
                } else if codec == .h264 {
                    hasParameters = (sps != nil && pps != nil)
                } else {
                    hasParameters = true
                }

                if hasParameters && (masteringDisplay != nil || packetsScanned > 20) {
                    break
                }
            } else {
                av_packet_unref(&pkt)
            }
        }

        // Rewind to the beginning. A timestamp seek in MPEG-TS / MPEG-PS bisects and can land past the first
        // packet, dropping the keyframe that starts the file (H.264 then can't decode its first GOP). Their data
        // starts at the first byte, so rewind there.
        if Self.isUnindexedStream(ctx) {
            avformat_seek_file(ctx, -1, Int64.min, 0, 0, AVSEEK_FLAG_BYTE)
        } else {
            av_seek_frame(
                ctx, Int32(videoStreamIndex), Self.timelineOffset(timelineOrigin, in: timebase), AVSEEK_FLAG_BACKWARD)
        }
        readAheadState.withLock { $0 = -.infinity }

        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel

        let builder = VideoFormatDescriptionBuilder(
            codec: codec,
            width: width,
            height: height,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            isFullRange: isFullRange,
            bitDepth: bitDepth,
            sampleAspectRatio: sampleAspectRatio,
            masteringDisplay: masteringDisplay,
            contentLightLevel: contentLightLevel,
            parameterSets: .init(vps: vps, sps: sps, pps: pps),
            dolbyVision: dolbyVisionProfile.flatMap { profile in
                dolbyVisionConfigData.map { (profile: profile, configData: $0) }
            }
        )
        return builder.make(codecParameters: codecParameters)
    }

    /// Collects HDR metadata from an HEVC prefix SEI NAL unit. Mastering display luminance only fills in
    /// a peak still at its 1000-nit default; MaxCLL overrides it.
    private func applyHDRSEI(naluData: Data, masteringDisplay: inout Data?, contentLightLevel: inout Data?) {
        for message in VideoFormatDescriptionBuilder.hdrSEIMessages(inPrefixSEI: naluData) {
            switch message {
            case .masteringDisplay(let data, let maxLuminanceNits):
                masteringDisplay = data
                if self.maxPeakNits == 1000.0 && maxLuminanceNits > 0 {
                    self.maxPeakNits = maxLuminanceNits
                }
            case .contentLightLevel(let data, let maxCLL, let maxFALL):
                contentLightLevel = data
                if maxCLL > 0 {
                    self.maxPeakNits = Float(maxCLL)
                }
                if maxFALL > 0 {
                    self.maxFallNits = Float(maxFALL)
                }
            }
        }
    }

    private var targetPts: Int64 = -1
    /// `timelineOrigin(of:)` of this file; subtracted from every packet read, added back when seeking.
    private var timelineOrigin: Int64 = 0
    private var targetAudioPts: Int64 = -1

    private func createVideoSample(from rawData: Data, pts: Int64, dts: Int64, duration: Int64) -> CMSampleBuffer? {
        rawData.withUnsafeBytes { raw in
            createVideoSample(
                bytes: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: rawData.count,
                pts: pts,
                dts: dts,
                duration: duration
            )
        }
    }

    private func createVideoSample(
        bytes: UnsafePointer<UInt8>?,
        count: Int,
        pts: Int64,
        dts: Int64,
        duration: Int64
    ) -> CMSampleBuffer? {
        guard let formatDesc = formatDescription, let bytes, count > 0 else { return nil }

        var doviMetadata: DolbyVisionFrameMetadata?
        if codec == .hevc && dolbyVisionProfile != nil {
            if let nalu = NALUnitParser.findNALUnit62(bytes: bytes, count: count, isAnnexB: self.isAnnexBStream) {
                doviMetadata = DolbyVisionRPUParser.parse(naluData: nalu)
            }
        }

        let mem: UnsafeMutableRawPointer
        let finalSize: Int
        if !codec.requiresHVCC {
            finalSize = count
            guard let allocated = malloc(finalSize) else { return nil }
            memcpy(allocated, bytes, finalSize)
            mem = allocated
        } else {
            let isAnnexB: Bool
            if isAnnexBStream {
                isAnnexB =
                    (bytes[0] == 0 && bytes[1] == 0 && (bytes[2] == 1 || (count > 3 && bytes[2] == 0 && bytes[3] == 1)))
            } else {
                isAnnexB = false
            }

            if !isAnnexB {
                finalSize = count
                guard let allocated = malloc(finalSize) else { return nil }
                memcpy(allocated, bytes, finalSize)
                mem = allocated
            } else {
                let (hvccData, hvccSize) = NALUnitParser.packetDataToHVCC(
                    pktData: bytes,
                    count: count,
                    isAnnexBStream: true
                )
                guard hvccSize > 0, let allocated = malloc(hvccSize) else { return nil }
                _ = hvccData.withUnsafeBytes { rawBytes in
                    memcpy(allocated, rawBytes.baseAddress!, hvccSize)
                }
                mem = allocated
                finalSize = hvccSize
            }
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: mem,
            blockLength: finalSize,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: finalSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        if blockStatus != kCMBlockBufferNoErr {
            free(mem)
            return nil
        }

        let noPtsValue = Int64.min
        let ptsVal = pts != noPtsValue ? pts : dts
        let dtsVal = dts != noPtsValue ? dts : ptsVal

        let timebaseDen = timebase.den
        let timebaseNum = Int64(timebase.num)
        var timing = CMSampleTimingInfo(
            duration: duration > 0 ? CMTime(value: duration * timebaseNum, timescale: timebaseDen) : .invalid,
            presentationTimeStamp: CMTime(value: ptsVal * timebaseNum, timescale: timebaseDen),
            decodeTimeStamp: CMTime(value: dtsVal * timebaseNum, timescale: timebaseDen)
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = finalSize
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        let isBeforeTarget = targetPts >= 0 && ptsVal < targetPts
        // In decode order the first sample past the target is often a P-frame, followed by B-frames that
        // still precede it, so keep flagging preroll for a second past the target. Bounded so that a
        // timestamp discontinuity (MPEG-TS) can't hide every following frame.
        let reorderWindow = Int64(timebaseDen) / max(timebaseNum, 1)
        if targetPts >= 0 && ptsVal >= targetPts + reorderWindow {
            targetPts = -1
        }

        if status == noErr, let sb = sampleBuffer {
            CMSetAttachment(
                sb, key: kCVImageBufferColorPrimariesKey, value: colorPrimaries,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            CMSetAttachment(
                sb, key: kCVImageBufferTransferFunctionKey, value: transferFunction,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            CMSetAttachment(
                sb, key: kCVImageBufferYCbCrMatrixKey, value: yCbCrMatrix,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            if !sampleAspectRatio.isSquare {
                let parDict: NSDictionary = [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey: sampleAspectRatio.numerator,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: sampleAspectRatio.denominator,
                ]
                CMSetAttachment(
                    sb, key: kCVImageBufferPixelAspectRatioKey, value: parDict,
                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            if let masteringDisplay {
                CMSetAttachment(
                    sb, key: kCVImageBufferMasteringDisplayColorVolumeKey, value: masteringDisplay as CFData,
                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            if let contentLightLevel {
                CMSetAttachment(
                    sb, key: kCVImageBufferContentLightLevelInfoKey, value: contentLightLevel as CFData,
                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            if let doviMetadata {
                CMSetAttachment(
                    sb, key: Self.dolbyVisionMetadataAttachmentKey as CFString,
                    value: DolbyVisionMetadataBox(metadata: doviMetadata),
                    attachmentMode: kCMAttachmentMode_ShouldNotPropagate
                )
            }

            if isBeforeTarget || pts == noPtsValue {
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true)
                    as? [NSMutableDictionary], let first = attachments.first
                {
                    if isBeforeTarget {
                        first[kCMSampleAttachmentKey_DoNotDisplay] = true
                    }
                    if isBeforeTarget {
                        first[Self.exactSeekTargetAttachmentKey] =
                            Double(targetPts) * Double(timebaseNum) / Double(timebaseDen)
                    }
                    if pts == noPtsValue {
                        first[Self.presentationTimeUnknownAttachmentKey] = true
                    }
                }
            }
            return sb
        }
        return nil
    }

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
                audioQueue.append(Self.makeAudioPacket(pkt))
                av_packet_unref(&pkt)
            } else if pkt.stream_index == selectedSubtitleStreamIndex {
                // Intercept subtitle packets in-band (crucial for network streams and single-connection media servers)
                processSubtitlePacket(&pkt)
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
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let isKey = (pkt.flags & AV_PKT_FLAG_KEY) != 0
                let audioPacket = DemuxedAudioPacket(
                    data: data,
                    pts: pktPts,
                    dts: pkt.dts,
                    duration: pktDuration,
                    isKeyFrame: isKey
                )
                self.lastAudioPts = pktPts
                av_packet_unref(&pkt)
                return audioPacket
            } else if pkt.stream_index == videoStreamIndex {
                // Symmetric buffering: preserve ALL video packets without dropping GOP frames!
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let videoPacket = DemuxedVideoPacket(
                    data: data,
                    pts: pkt.pts,
                    dts: pkt.dts,
                    duration: pkt.duration,
                    flags: pkt.flags
                )
                videoQueue.append(videoPacket)
                av_packet_unref(&pkt)
            } else if pkt.stream_index == selectedSubtitleStreamIndex {
                // Intercept subtitle packets in-band
                processSubtitlePacket(&pkt)
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

    /// - Parameter forward: Keyframe (non-exact) seeks only. When `true`, lands on the first keyframe at or
    ///   after `seconds` instead of the one before it. Required for sparse-GOP streams (e.g. AV1 with 10 s+
    ///   keyframe intervals) where a backward search would snap a +5 s step back to the same keyframe.
    /// - Parameter audioDelay: Seconds audio plays late against the picture. When positive, the audio heard with the
    ///   landed keyframe precedes it and is read too (see `readAudioAhead`).
    public func seek(to seconds: Double, exact: Bool = true, forward: Bool = false, audioDelay: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx else { return }
        audioQueue.removeAll()
        videoQueue.removeAll()
        liveBitmapDecoder?.flush()
        lastAudioPts = -1
        isEOFInternal = false
        // After the seek's own reads: a keyframe search that backs off, or reads to the end, would leave them ahead.
        defer { readAheadState.withLock { $0 = seconds } }
        if audioTimebase.den > 0 && audioTimebase.num > 0 {
            self.targetAudioPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        } else {
            self.targetAudioPts = -1
        }
        guard timebase.num > 0 else { return }
        let target = Int64(seconds * Double(timebase.den) / Double(timebase.num))
        // If not exact (keyframe seek), don't set targetPts threshold so that the keyframe sample is displayed immediately
        self.targetPts = exact ? target : -1
        let streamIdx = videoStreamIndex >= 0 ? videoStreamIndex : audioStreamIndex
        let useForward = forward && !exact
        let rawTarget = target + Self.timelineOffset(timelineOrigin, in: timebase)
        var ret: Int32 = -1
        if useForward {
            ret = av_seek_frame(ctx, Int32(streamIdx), rawTarget, 0)
        }
        if ret < 0 {
            // Backward search (also the fallback when no keyframe exists after target, e.g. near EOF)
            ret = av_seek_frame(ctx, Int32(streamIdx), rawTarget, AVSEEK_FLAG_BACKWARD)
        }
        AppLog.debug(
            .demuxer,
            "av_seek_frame to targetPts: \(target) (exact: \(exact), forward: \(useForward)), targetAudioPts: \(self.targetAudioPts) (seconds: \(seconds)), stream: \(streamIdx), ret: \(ret)"
        )
        if ret >= 0, videoStreamIndex >= 0, Self.isUnindexedStream(ctx) {
            syncToVideoKeyframe(ctx, target: target, requireAtOrBeforeTarget: exact)
        } else if ret >= 0, audioDelay > 0, videoStreamIndex >= 0, audioStreamIndex >= 0 {
            readAudioAhead(ctx, audioStartSeconds: exact ? seconds - audioDelay : nil, audioDelay: audioDelay)
        }
    }

    /// Reads the audio that plays with the landed keyframe when audio is delayed against the picture.
    ///
    /// A seek lands on a keyframe and reads on from there, but the muxer stores audio next to video of the same
    /// time: the audio for `audioDelay` before the keyframe lies before it in the file and would be skipped, leaving
    /// that much silence after every keyframe seek. Once the keyframe is known, this seeks back to one at or before
    /// the audio start and reads up to the landed keyframe again, keeping the audio and dropping the video before it
    /// (nothing extra is decoded). Reading then continues after the keyframe as it would have.
    ///
    /// - Parameter audioStartSeconds: Where audio must start (exact seeks), or `nil` for the keyframe minus
    ///   `audioDelay` (keyframe seeks).
    private func readAudioAhead(
        _ ctx: UnsafeMutablePointer<AVFormatContext>, audioStartSeconds: Double?, audioDelay: Double
    ) {
        // The landed keyframe, with the audio stored before it, as plain reading would queue them.
        var pkt = AVPacket()
        var keyframe: DemuxedVideoPacket?
        while keyframe == nil, readPacket(ctx, &pkt) >= 0 {
            defer { av_packet_unref(&pkt) }
            if pkt.stream_index == audioStreamIndex {
                audioQueue.append(Self.makeAudioPacket(pkt))
            } else if pkt.stream_index == selectedSubtitleStreamIndex {
                processSubtitlePacket(&pkt)
            } else if pkt.stream_index == videoStreamIndex {
                keyframe = DemuxedVideoPacket(
                    data: Data(bytes: pkt.data, count: Int(pkt.size)),
                    pts: pkt.pts, dts: pkt.dts, duration: pkt.duration, flags: pkt.flags)
            }
        }
        guard let keyframe else { return }
        videoQueue.append(keyframe)

        let keyTime = keyframe.pts != Int64.min ? keyframe.pts : keyframe.dts
        let keySeconds = Double(keyTime) * Double(timebase.num) / Double(timebase.den)
        let audioStart = max(audioStartSeconds ?? keySeconds - audioDelay, 0)
        guard audioStart < keySeconds else { return }

        let rawStart =
            Int64(audioStart * Double(timebase.den) / Double(timebase.num))
            + Self.timelineOffset(timelineOrigin, in: timebase)
        guard av_seek_frame(ctx, Int32(videoStreamIndex), rawStart, AVSEEK_FLAG_BACKWARD) >= 0 else {
            restoreAfterAudioAhead(ctx, keyTime: keyTime)
            return
        }
        var audio: [DemuxedAudioPacket] = []
        var budget = 50_000
        while budget > 0, readPacket(ctx, &pkt) >= 0 {
            budget -= 1
            defer { av_packet_unref(&pkt) }
            if pkt.stream_index == audioStreamIndex {
                audio.append(Self.makeAudioPacket(pkt))
            } else if pkt.stream_index == selectedSubtitleStreamIndex {
                processSubtitlePacket(&pkt)
            } else if pkt.stream_index == videoStreamIndex, (pkt.pts != Int64.min ? pkt.pts : pkt.dts) == keyTime {
                // Back at the keyframe, already queued: the audio read on the way replaces the audio queued above.
                audioQueue.removeAll()
                for packet in audio {
                    audioQueue.append(packet)
                }
                return
            }
        }
        AppLog.warning(.demuxer, "Keyframe at \(keySeconds)s not reached again while reading audio ahead of it")
        restoreAfterAudioAhead(ctx, keyTime: keyTime)
    }

    /// Returns to just after the landed keyframe (already queued, with the audio stored before it) when reading audio
    /// ahead of it failed.
    private func restoreAfterAudioAhead(_ ctx: UnsafeMutablePointer<AVFormatContext>, keyTime: Int64) {
        let rawKey = keyTime + Self.timelineOffset(timelineOrigin, in: timebase)
        guard av_seek_frame(ctx, Int32(videoStreamIndex), rawKey, AVSEEK_FLAG_BACKWARD) >= 0 else { return }
        var pkt = AVPacket()
        while readPacket(ctx, &pkt) >= 0 {
            defer { av_packet_unref(&pkt) }
            if pkt.stream_index == videoStreamIndex, (pkt.pts != Int64.min ? pkt.pts : pkt.dts) >= keyTime {
                return
            }
        }
    }

    /// MPEG-TS / MPEG-PS have no index: `av_seek_frame` bisects on timestamps and lands on whatever
    /// packet is nearest, usually mid-GOP, which the decoder can't start from. Skips ahead to the next
    /// video keyframe and queues it; for exact seeks, backs off further each time that keyframe is past
    /// the target.
    ///
    /// The muxer interleaves audio up to ~0.7 s away from the video of the same time, so audio read
    /// before the keyframe can still be needed: on the attempt that lands it is queued like any audio
    /// read ahead of video (`nextAudioPacket` drops what precedes `targetAudioPts`). Subtitle cues are
    /// kept on every attempt; re-reading them after a back-off is deduplicated.
    private func syncToVideoKeyframe(
        _ ctx: UnsafeMutablePointer<AVFormatContext>, target: Int64, requireAtOrBeforeTarget: Bool
    ) {
        let oneSecond = Int64(Double(timebase.den) / Double(timebase.num))
        let maxAttempts = 5
        var seekTarget = target + Self.timelineOffset(timelineOrigin, in: timebase)
        for attempt in 0..<maxAttempts {
            var pkt = AVPacket()
            var landed = false
            var budget = 20_000
            var audioBeforeKeyframe: [DemuxedAudioPacket] = []
            while budget > 0, readPacket(ctx, &pkt) >= 0 {
                budget -= 1
                defer { av_packet_unref(&pkt) }
                if pkt.stream_index == audioStreamIndex {
                    audioBeforeKeyframe.append(Self.makeAudioPacket(pkt))
                    continue
                }
                if pkt.stream_index == selectedSubtitleStreamIndex {
                    processSubtitlePacket(&pkt)
                    continue
                }
                guard pkt.stream_index == videoStreamIndex, (pkt.flags & AV_PKT_FLAG_KEY) != 0 else { continue }
                let keyPts = pkt.pts != Int64.min ? pkt.pts : pkt.dts
                let isLastChance = attempt == maxAttempts - 1
                if requireAtOrBeforeTarget && keyPts > target && !isLastChance {
                    break
                }
                videoQueue.append(
                    DemuxedVideoPacket(
                        data: Data(bytes: pkt.data, count: Int(pkt.size)),
                        pts: pkt.pts, dts: pkt.dts, duration: pkt.duration, flags: pkt.flags))
                landed = true
                break
            }
            if landed {
                for packet in audioBeforeKeyframe {
                    audioQueue.append(packet)
                }
                return
            }
            seekTarget -= oneSecond << attempt
            // Before the first timestamp the bisection fails: restart from the first byte instead.
            if av_seek_frame(ctx, Int32(videoStreamIndex), seekTarget, AVSEEK_FLAG_BACKWARD) < 0 {
                _ = avformat_seek_file(ctx, -1, Int64.min, 0, 0, AVSEEK_FLAG_BYTE)
            }
        }
        AppLog.warning(.demuxer, "No video keyframe found while syncing seek to \(target)")
    }

    /// Adjusts the target audio presentation timestamp (e.g. to align with the actual decoded keyframe PTS).
    public func setTargetAudioPts(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        if audioTimebase.den > 0 && audioTimebase.num > 0 {
            self.targetAudioPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        } else {
            self.targetAudioPts = -1
        }
    }

    /// Discards any audio packets queued prior to the specified target time in seconds.
    /// This prevents stale audio packets accumulated during video preroll/seeking from corrupting the synchronizer.
    public func purgeAudio(beforeSeconds seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard audioTimebase.den > 0 && audioTimebase.num > 0 else {
            audioQueue.removeAll()
            return
        }
        let thresholdPts = Int64(seconds * Double(audioTimebase.den) / Double(audioTimebase.num))
        audioQueue.removeAll { $0.pts < thresholdPts }
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
