import CFFmpeg
import CoreMedia
import Foundation
import VideoToolbox
import os

public final class MediaDemuxer: @unchecked Sendable {
    public static let dolbyVisionMetadataAttachmentKey: String = "Nits.DolbyVisionMetadata"

    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int = -1
    private var audioStreamIndex: Int = -1
    public private(set) var timebase: AVRational = AVRational(num: 1, den: 1000)
    public private(set) var audioTimebase: AVRational = AVRational(num: 1, den: 1000)
    public private(set) var codec: VideoCodec = .hevc
    public private(set) var hasVideo: Bool = false
    public private(set) var nominalFrameDuration: Double = 1.0 / 24.0
    public private(set) var hasAudio: Bool = false
    public private(set) var audioCodecId: AVCodecID = AV_CODEC_ID_NONE
    public private(set) var audioChannels: Int = 0
    public private(set) var audioSampleRate: Int = 0
    public struct AudioTrack: Sendable, Identifiable {
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
    private struct LiveSubtitleState {
        var cues: [SubtitleCue] = []
        var version: Int = 0
    }
    /// Live in-band subtitle state is guarded by its own lightweight lock, NOT the I/O `lock`.
    /// `lock` is held across blocking `av_read_frame` / `av_seek_frame` calls (hundreds of ms on
    /// network streams); readers on the main thread must never contend with it.
    /// Lock order: `lock` -> `liveSubtitleState` (never the reverse).
    private let liveSubtitleState = OSAllocatedUnfairLock(initialState: LiveSubtitleState())
    public var liveSubtitleVersion: Int {
        liveSubtitleState.withLock { $0.version }
    }
    private var cachedSubtitleDocuments: [Int: SubtitleDocument] = [:]
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
            state.version += 1
        }
        if let trackId, let track = subtitleTracks.first(where: { $0.id == trackId }) {
            self.selectedSubtitleStreamIndex = track.streamIndex
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
        let cues = liveSubtitleState.withLock { $0.cues }
        return SubtitleDocument(cues: cues)
    }

    /// Retrieves or loads on demand the SubtitleDocument for a given track id.
    public func loadSubtitleDocument(for trackId: Int, url: String, headers: [String: String]) -> SubtitleDocument? {
        lock.lock()
        if let cached = cachedSubtitleDocuments[trackId] {
            lock.unlock()
            return cached
        }
        guard let track = subtitleTracks.first(where: { $0.id == trackId }) else {
            lock.unlock()
            return nil
        }
        let isNetwork = Self.isNetworkURL(url)
        lock.unlock()

        // For network streams, do NOT spin a secondary demuxer loop to EOF.
        // Return whatever live in-band cues we have collected so far.
        if isNetwork {
            return getLiveSubtitleDocument()
        }

        // For local files, secondary background extraction can index the entire file quickly.
        let doc = Self.extractEmbeddedSubtitles(url: url, headers: headers, streamIndex: track.streamIndex)
        if let doc {
            lock.lock()
            self.cachedSubtitleDocuments[trackId] = doc
            lock.unlock()
        }
        return doc
    }

    /// Dedicated fast extraction of text subtitles from media stream without disturbing playback queues.
    private static func extractEmbeddedSubtitles(url: String, headers: [String: String], streamIndex: Int)
        -> SubtitleDocument?
    {
        var options: OpaquePointer? = nil
        defer { if options != nil { av_dict_free(&options) } }

        if Self.isNetworkURL(url) {
            Self.applyNetworkOptions(&options, headers: headers)
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

        while !Task.isCancelled && av_read_frame(ctx, &pkt) >= 0 {
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
    private static func parseSubtitleCue(
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

    /// Ingests a subtitle packet into liveSubtitleCues (called with lock held).
    private func processSubtitlePacket(_ pkt: UnsafeMutablePointer<AVPacket>) {
        guard let ctx = formatCtx, selectedSubtitleStreamIndex >= 0,
            selectedSubtitleStreamIndex < Int(ctx.pointee.nb_streams),
            let stream = ctx.pointee.streams[selectedSubtitleStreamIndex]
        else { return }

        let timebase = stream.pointee.time_base
        let codecId = stream.pointee.codecpar.pointee.codec_id
        let nextIndex = liveSubtitleState.withLock { $0.cues.count } + 1

        guard let newCue = Self.parseSubtitleCue(pkt: pkt, timebase: timebase, codecId: codecId, cueIndex: nextIndex)
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

    public final class InterruptContext: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var _isCancelled = false
        private var _lastErrorCode: Int32?
        private var _lastErrorMessage: String?

        public init() {}

        public var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _isCancelled
        }

        public func cancel() {
            lock.lock()
            _isCancelled = true
            lock.unlock()
        }

        public var lastError: (code: Int32, message: String)? {
            lock.lock()
            defer { lock.unlock() }
            guard let code = _lastErrorCode, let msg = _lastErrorMessage else { return nil }
            return (code, msg)
        }

        public func recordError(code: Int32, message: String) {
            lock.lock()
            _lastErrorCode = code
            _lastErrorMessage = message
            lock.unlock()
        }
    }

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

    public static func isNetworkURL(_ path: String) -> Bool {
        guard let url = URL(string: path), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Adds custom HTTP headers (CRLF-sanitized) plus reconnect and 10 s I/O timeout settings to
    /// `avformat_open_input` options for a network URL.
    static func applyNetworkOptions(_ options: inout OpaquePointer?, headers: [String: String]) {
        if !headers.isEmpty {
            var headerString = ""
            for (key, value) in headers {
                // Sanitize against CRLF injection
                let cleanKey = key.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                let cleanVal = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                guard !cleanKey.isEmpty else { continue }

                if cleanKey.lowercased() == "user-agent" {
                    _ = av_dict_set(&options, "user_agent", cleanVal, 0)
                } else {
                    headerString += "\(cleanKey): \(cleanVal)\r\n"
                }
            }
            if !headerString.isEmpty {
                _ = av_dict_set(&options, "headers", headerString, 0)
            }
        }

        _ = av_dict_set(&options, "reconnect", "1", 0)
        _ = av_dict_set(&options, "reconnect_streamed", "1", 0)
        _ = av_dict_set(&options, "reconnect_delay_max", "5", 0)
        // 10-second timeout in microseconds for network I/O
        _ = av_dict_set(&options, "rw_timeout", "10000000", 0)
        _ = av_dict_set(&options, "timeout", "10000000", 0)
    }

    /// Checks if a network URL points to a local area network (LAN) / private network address
    /// (e.g. 192.168.x.x, 10.x.x.x, 172.16-31.x.x, 127.0.0.1, localhost, .local, etc.)
    public static func isLocalNetworkURL(_ path: String) -> Bool {
        guard let url = URL(string: path), let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // Loopback and local domain suffixes
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") || host.hasSuffix(".localdomain")
        {
            return true
        }

        // IPv4 parsing (e.g. 192.168.1.83)
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 && parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) {
            let p0 = parts[0]
            let p1 = parts[1]
            // 10.0.0.0/8 (10.x.x.x)
            if p0 == 10 { return true }
            // 172.16.0.0/12 (172.16.x.x - 172.31.x.x)
            if p0 == 172 && (16...31).contains(p1) { return true }
            // 192.168.0.0/16 (192.168.x.x)
            if p0 == 192 && p1 == 168 { return true }
            // 169.254.0.0/16 (link-local)
            if p0 == 169 && p1 == 254 { return true }
            // 127.0.0.0/8 (loopback)
            if p0 == 127 { return true }
        }

        // IPv6 Link-Local (fe80::/10) or Unique Local (fc00::/7 - fc.. or fd..)
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }

        return false
    }

    /// Checks if a path points to a remote streaming resource or a mounted remote volume (e.g. NFS, SMB, AFP under /Volumes/).
    /// Opening such resources can incur network latency and must be performed asynchronously.
    public static func isRemoteOrMountedVolume(_ path: String) -> Bool {
        if isNetworkURL(path) {
            return true
        }
        // Network schemes
        if path.hasPrefix("nfs://") || path.hasPrefix("smb://") || path.hasPrefix("afp://") || path.hasPrefix("rtsp://")
        {
            return true
        }
        // Mounted volumes outside boot drive (e.g. /Volumes/Drive/...)
        if path.hasPrefix("/Volumes/") {
            let url = URL(fileURLWithPath: path)
            if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]), let isLocal = values.volumeIsLocal {
                return !isLocal
            }
            // If resourceValues cannot determine or path is under /Volumes/, treat as potentially remote
            return true
        }
        return false
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
        allocatedCtx.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(ctxContext).toOpaque()
        allocatedCtx.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            let unmanagedContext = Unmanaged<InterruptContext>.fromOpaque(opaque)
            let instance = unmanagedContext.takeUnretainedValue()
            return instance.isCancelled ? 1 : 0
        }

        var avOptions: OpaquePointer? = nil
        defer {
            if avOptions != nil {
                av_dict_free(&avOptions)
            }
        }

        let isNetworkURL = Self.isNetworkURL(url)
        if isNetworkURL {
            Self.applyNetworkOptions(&avOptions, headers: headers)
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

        for i in 0..<Int(formatCtx.pointee.nb_streams) {
            let stream = formatCtx.pointee.streams[i]!
            let codecId = stream.pointee.codecpar.pointee.codec_id
            let isAttachedPic = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                && !isAttachedPic
                && self.videoStreamIndex < 0,
                let detectedCodec = VideoCodec.from(codecId: codecId)
            {
                self.videoStreamIndex = i
                self.timebase = stream.pointee.time_base
                self.codec = detectedCodec
                self.width = Int(stream.pointee.codecpar.pointee.width)
                self.height = Int(stream.pointee.codecpar.pointee.height)

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
                } else if stream.pointee.codecpar.pointee.sample_aspect_ratio.num > 0
                    && stream.pointee.codecpar.pointee.sample_aspect_ratio.den > 0
                {
                    self.sampleAspectRatio = RationalAspectRatio(
                        numerator: Int(stream.pointee.codecpar.pointee.sample_aspect_ratio.num),
                        denominator: Int(stream.pointee.codecpar.pointee.sample_aspect_ratio.den)
                    )
                } else {
                    self.sampleAspectRatio = .square
                }

                if stream.pointee.duration > 0 {
                    self.durationSeconds = Double(stream.pointee.duration) * Double(timebase.num) / Double(timebase.den)
                } else if formatCtx.pointee.duration > 0 {
                    self.durationSeconds = Double(formatCtx.pointee.duration) / Double(AV_TIME_BASE)
                }

                // Compute nominal frame duration from stream frame rate with sanity clamp (1 to 240 fps)
                let avg = stream.pointee.avg_frame_rate
                let r = stream.pointee.r_frame_rate
                let rawDuration: Double =
                    if avg.num > 0 && avg.den > 0 {
                        Double(avg.den) / Double(avg.num)
                    } else if r.num > 0 && r.den > 0 {
                        Double(r.den) / Double(r.num)
                    } else {
                        1.0 / 24.0
                    }
                self.nominalFrameDuration =
                    (rawDuration >= (1.0 / 240.0) && rawDuration <= 1.0) ? rawDuration : (1.0 / 24.0)

                // Dynamically map color primaries
                if let primaries = CVColorPrimariesGetStringForIntegerCodePoint(
                    Int32(stream.pointee.codecpar.pointee.color_primaries.rawValue))
                {
                    self.colorPrimaries = primaries.takeUnretainedValue()
                } else {
                    switch stream.pointee.codecpar.pointee.color_primaries {
                    case AVCOL_PRI_BT709:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2
                    case AVCOL_PRI_BT2020:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_2020
                    case AVCOL_PRI_SMPTE431:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_DCI_P3
                    case AVCOL_PRI_SMPTE432:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_P3_D65
                    default:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2
                    }
                }

                // Dynamically map transfer characteristics (TRC)
                if let trc = CVTransferFunctionGetStringForIntegerCodePoint(
                    Int32(stream.pointee.codecpar.pointee.color_trc.rawValue))
                {
                    self.transferFunction = trc.takeUnretainedValue()
                } else {
                    switch stream.pointee.codecpar.pointee.color_trc {
                    case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_SMPTE240M:
                        self.transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2
                    case AVCOL_TRC_SMPTE2084:
                        self.transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                    case AVCOL_TRC_ARIB_STD_B67:
                        self.transferFunction = kCVImageBufferTransferFunction_ITU_R_2100_HLG
                    case AVCOL_TRC_GAMMA22:
                        self.transferFunction = kCVImageBufferTransferFunction_UseGamma
                    case AVCOL_TRC_LINEAR:
                        self.transferFunction = kCVImageBufferTransferFunction_Linear
                    default:
                        self.transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2
                    }
                }

                // Dynamically map YCbCr color matrix / colorspace
                if let matrix = CVYCbCrMatrixGetStringForIntegerCodePoint(
                    Int32(stream.pointee.codecpar.pointee.color_space.rawValue))
                {
                    self.yCbCrMatrix = matrix.takeUnretainedValue()
                } else {
                    switch stream.pointee.codecpar.pointee.color_space {
                    case AVCOL_SPC_BT709:
                        self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
                    case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL:
                        self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
                    case AVCOL_SPC_SMPTE170M, AVCOL_SPC_SMPTE240M:
                        self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
                    default:
                        self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
                    }
                }

                // Range
                if stream.pointee.codecpar.pointee.color_range == AVCOL_RANGE_JPEG {
                    self.isFullRange = true
                } else {
                    self.isFullRange = false
                }

                // Bit depth detection
                let pixFmt = stream.pointee.codecpar.pointee.format
                if pixFmt == AV_PIX_FMT_YUV420P10LE.rawValue || pixFmt == AV_PIX_FMT_YUV420P10BE.rawValue
                    || pixFmt == AV_PIX_FMT_YUV422P10LE.rawValue || pixFmt == AV_PIX_FMT_YUV444P10LE.rawValue
                    || ((codecId == AV_CODEC_ID_HEVC || codecId == AV_CODEC_ID_AV1 || codecId == AV_CODEC_ID_VP9)
                        && (self.transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                            || self.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG))
                {
                    self.bitDepth = 10
                } else {
                    self.bitDepth = 8
                }

                // Dolby Vision Detection (Profiles 5, 8.1, 8.4):
                // In MP4/MKV it is identified by dvvC/dvcC box (or stream side data).
                // Profile 5 uses IPTc2 color space with PQ transfer function.
                // Profile 8 uses standard BT.2020 PQ (8.1) or HLG (8.4) with dynamic RPU metadata.
                if let extradata = stream.pointee.codecpar.pointee.extradata,
                    stream.pointee.codecpar.pointee.extradata_size >= 24
                {
                    let extraDataSize = Int(stream.pointee.codecpar.pointee.extradata_size)
                    let extraData = Data(bytes: extradata, count: extraDataSize)
                    if let parsed = Self.parseDolbyVisionConfigurationBox(from: extraData) {
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

                let sideDataCount = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
                if sideDataCount > 0, let sideDataList = stream.pointee.codecpar.pointee.coded_side_data {
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
                            // Construct standard 24-byte DOVI configuration box payload per ISO/IEC 14496-15
                            var boxPayload = [UInt8](repeating: 0, count: 24)
                            boxPayload[0] = doviConf.pointee.dv_version_major
                            boxPayload[1] = doviConf.pointee.dv_version_minor
                            let p = doviConf.pointee.dv_profile
                            let l = doviConf.pointee.dv_level
                            let rpu = doviConf.pointee.rpu_present_flag & 0x01
                            let el = doviConf.pointee.el_present_flag & 0x01
                            let bl = doviConf.pointee.bl_present_flag & 0x01
                            boxPayload[2] = ((p & 0x7F) << 1) | ((l >> 5) & 0x01)
                            boxPayload[3] = ((l & 0x1F) << 3) | (rpu << 2) | (el << 1) | bl
                            boxPayload[4] = UInt8(compatId << 4)
                            self.dolbyVisionConfigData = Data(boxPayload)
                            AppLog.info(
                                .video,
                                "Detected Dolby Vision Profile \(dvProfile) via FFmpeg side data (compatibility id: \(compatId))"
                            )
                        } else if sd.type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL, let sdData = sd.data,
                            sd.size >= MemoryLayout<AVContentLightMetadata>.size
                        {
                            let clm = UnsafeMutableRawPointer(sdData).assumingMemoryBound(
                                to: AVContentLightMetadata.self)
                            if clm.pointee.MaxCLL > 0 {
                                self.maxPeakNits = Float(clm.pointee.MaxCLL)
                            }
                            if clm.pointee.MaxFALL > 0 {
                                self.maxFallNits = Float(clm.pointee.MaxFALL)
                            }
                            var cllBytes = [UInt8](repeating: 0, count: 4)
                            cllBytes[0] = UInt8((clm.pointee.MaxCLL >> 8) & 0xFF)
                            cllBytes[1] = UInt8(clm.pointee.MaxCLL & 0xFF)
                            cllBytes[2] = UInt8((clm.pointee.MaxFALL >> 8) & 0xFF)
                            cllBytes[3] = UInt8(clm.pointee.MaxFALL & 0xFF)
                            self.contentLightLevel = Data(cllBytes)
                            AppLog.info(
                                .video,
                                "Extracted ContentLightLevel from side data: MaxCLL=\(clm.pointee.MaxCLL), MaxFALL=\(clm.pointee.MaxFALL)"
                            )
                        } else if sd.type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA, let sdData = sd.data,
                            sd.size >= MemoryLayout<AVMasteringDisplayMetadata>.size
                        {
                            let mdm = UnsafeMutableRawPointer(sdData).assumingMemoryBound(
                                to: AVMasteringDisplayMetadata.self)
                            if mdm.pointee.has_luminance != 0 && mdm.pointee.max_luminance.den > 0 {
                                let maxLum = Float(mdm.pointee.max_luminance.num) / Float(mdm.pointee.max_luminance.den)
                                if self.maxPeakNits == 1000.0 && maxLum > 0 {
                                    self.maxPeakNits = maxLum
                                }
                            }
                            if mdm.pointee.has_primaries != 0 && mdm.pointee.has_luminance != 0 {
                                var mdBytes = [UInt8](repeating: 0, count: 24)
                                let rx = UInt16(
                                    clamping: Int(mdm.pointee.display_primaries.0.0.num) * 50000
                                        / Int(max(1, mdm.pointee.display_primaries.0.0.den)))
                                let ry = UInt16(
                                    clamping: Int(mdm.pointee.display_primaries.0.1.num) * 50000
                                        / Int(max(1, mdm.pointee.display_primaries.0.1.den)))
                                let gx = UInt16(
                                    clamping: Int(mdm.pointee.display_primaries.1.0.num) * 50000
                                        / Int(max(1, mdm.pointee.display_primaries.1.0.den)))
                                let gy = UInt16(
                                    clamping: Int(mdm.pointee.display_primaries.1.1.num) * 50000
                                        / Int(max(1, mdm.pointee.display_primaries.1.1.den)))
                                let bx = UInt16(
                                    clamping: Int(mdm.pointee.display_primaries.2.0.num) * 50000
                                        / Int(max(1, mdm.pointee.display_primaries.2.0.den)))
                                let by = UInt16(
                                    clamping: Int(mdm.pointee.display_primaries.2.1.num) * 50000
                                        / Int(max(1, mdm.pointee.display_primaries.2.1.den)))
                                let wx = UInt16(
                                    clamping: Int(mdm.pointee.white_point.0.num) * 50000
                                        / Int(max(1, mdm.pointee.white_point.0.den)))
                                let wy = UInt16(
                                    clamping: Int(mdm.pointee.white_point.1.num) * 50000
                                        / Int(max(1, mdm.pointee.white_point.1.den)))
                                let maxL = UInt32(
                                    clamping: Int64(mdm.pointee.max_luminance.num) * 10000
                                        / Int64(max(1, mdm.pointee.max_luminance.den)))
                                let minL = UInt32(
                                    clamping: Int64(mdm.pointee.min_luminance.num) * 10000
                                        / Int64(max(1, mdm.pointee.min_luminance.den)))
                                mdBytes[0] = UInt8(rx >> 8)
                                mdBytes[1] = UInt8(rx & 0xFF)
                                mdBytes[2] = UInt8(ry >> 8)
                                mdBytes[3] = UInt8(ry & 0xFF)
                                mdBytes[4] = UInt8(gx >> 8)
                                mdBytes[5] = UInt8(gx & 0xFF)
                                mdBytes[6] = UInt8(gy >> 8)
                                mdBytes[7] = UInt8(gy & 0xFF)
                                mdBytes[8] = UInt8(bx >> 8)
                                mdBytes[9] = UInt8(bx & 0xFF)
                                mdBytes[10] = UInt8(by >> 8)
                                mdBytes[11] = UInt8(by & 0xFF)
                                mdBytes[12] = UInt8(wx >> 8)
                                mdBytes[13] = UInt8(wx & 0xFF)
                                mdBytes[14] = UInt8(wy >> 8)
                                mdBytes[15] = UInt8(wy & 0xFF)
                                mdBytes[16] = UInt8((maxL >> 24) & 0xFF)
                                mdBytes[17] = UInt8((maxL >> 16) & 0xFF)
                                mdBytes[18] = UInt8((maxL >> 8) & 0xFF)
                                mdBytes[19] = UInt8(maxL & 0xFF)
                                mdBytes[20] = UInt8((minL >> 24) & 0xFF)
                                mdBytes[21] = UInt8((minL >> 16) & 0xFF)
                                mdBytes[22] = UInt8((minL >> 8) & 0xFF)
                                mdBytes[23] = UInt8(minL & 0xFF)
                                self.masteringDisplay = Data(mdBytes)
                            }
                        }
                    }
                }
            } else if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
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
                    streamIndex: i,
                    title: title,
                    language: lang,
                    codecName: codecNameStr,
                    channels: Int(stream.pointee.codecpar.pointee.ch_layout.nb_channels),
                    sampleRate: Int(stream.pointee.codecpar.pointee.sample_rate)
                )
                self.audioTracks.append(track)

                if self.audioStreamIndex < 0 {
                    // First audio stream found - select as default
                    self.audioStreamIndex = i
                    self.selectedAudioTrackIndex = track.id
                    self.audioTimebase = stream.pointee.time_base
                    self.audioCodecId = codecId
                    self.hasAudio = true
                    self.audioChannels = track.channels
                    self.audioSampleRate = track.sampleRate
                    if let ed = stream.pointee.codecpar.pointee.extradata,
                        stream.pointee.codecpar.pointee.extradata_size > 0
                    {
                        self.audioExtraData = Data(
                            bytes: ed, count: Int(stream.pointee.codecpar.pointee.extradata_size))
                    }
                }
            } else if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                // Support text subtitle formats: subrip (SRT), webvtt, mov_text, ASS, SSA
                let isTextSub =
                    (codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_WEBVTT || codecId == AV_CODEC_ID_MOV_TEXT
                        || codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA)
                if isTextSub {
                    var title = ""
                    var lang = ""
                    if let titleTag = av_dict_get(stream.pointee.metadata, "title", nil, 0) {
                        title = String(cString: titleTag.pointee.value)
                    }
                    if let langTag = av_dict_get(stream.pointee.metadata, "language", nil, 0) {
                        lang = String(cString: langTag.pointee.value)
                    }
                    let isForced = title.localizedCaseInsensitiveContains("forced")
                    let isSDH = title.localizedCaseInsensitiveContains("sdh")
                    let displayTitle =
                        title.isEmpty
                        ? (lang.isEmpty ? "Subtitle \(self.subtitleTracks.count + 1)" : lang.uppercased()) : title

                    let subTrack = SubtitleTrack(
                        id: self.subtitleTracks.count,
                        streamIndex: i,
                        title: displayTitle,
                        language: lang,
                        isExternal: false,
                        isForced: isForced,
                        isSDH: isSDH
                    )
                    self.subtitleTracks.append(subTrack)
                }
            }

            // Extract embedded artwork (cover art / attached picture) if present
            if (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0,
                self.embeddedArtworkData == nil
            {
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

    /// Parses an ISOBMFF dvcC/dvvC Dolby Vision configuration box from extradata.
    public static func parseDolbyVisionConfigurationBox(from data: Data) -> (
        profile: Int, compatibilityId: Int, configData: Data
    )? {
        guard data.count >= 24 else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            for k in 0..<(count - 8) {
                let isDvcC = (bytes[k] == 0x64 && bytes[k + 1] == 0x76 && bytes[k + 2] == 0x63 && bytes[k + 3] == 0x43)
                let isDvvC = (bytes[k] == 0x64 && bytes[k + 1] == 0x76 && bytes[k + 2] == 0x76 && bytes[k + 3] == 0x43)
                if isDvcC || isDvvC {
                    let dvProfile = Int((bytes[k + 6] >> 1) & 0x7F)
                    let compatId = Int((bytes[k + 8] >> 4) & 0x0F)
                    let boxPayloadStart = k + 4
                    guard count - boxPayloadStart >= 24 else { return nil }
                    let configData = Data(bytes[boxPayloadStart..<(boxPayloadStart + 24)])
                    return (profile: dvProfile, compatibilityId: compatId, configData: configData)
                }
            }
            return nil
        }
    }

    private func parseExtradata() -> (vps: Data?, sps: Data?, pps: Data?) {
        guard let ctx = formatCtx, videoStreamIndex >= 0 else { return (nil, nil, nil) }
        let stream = ctx.pointee.streams[videoStreamIndex]!
        guard let extradata = stream.pointee.codecpar.pointee.extradata,
            stream.pointee.codecpar.pointee.extradata_size > 0
        else {
            return (nil, nil, nil)
        }
        let size = Int(stream.pointee.codecpar.pointee.extradata_size)
        let data = Data(bytes: extradata, count: size)

        // Case 1: Raw Annex B in extradata (starts with 0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
        if size >= 3 && data[0] == 0 && data[1] == 0 && (data[2] == 1 || (size > 3 && data[2] == 0 && data[3] == 1)) {
            self.isAnnexBStream = true
            let nalus = Self.extractNALUnits(from: data)
            var vps: Data?
            var sps: Data?
            var pps: Data?
            for nalu in nalus {
                if codec == .hevc {
                    let nalType = (nalu[0] >> 1) & 0x3F
                    if nalType == 32 {
                        vps = nalu
                    } else if nalType == 33 {
                        sps = nalu
                    } else if nalType == 34 {
                        pps = nalu
                    }
                } else if codec == .h264 {
                    let nalType = nalu[0] & 0x1F
                    if nalType == 7 { sps = nalu } else if nalType == 8 { pps = nalu }
                }
            }
            return (vps, sps, pps)
        }

        // Case 2: H.264 avcC format (ISO/IEC 14496-15)
        if codec == .h264 && size >= 7 && data[0] == 1 {
            self.isAnnexBStream = false
            var offset = 5
            let numSPS = Int(data[offset] & 0x1F)
            offset += 1
            var sps: Data?
            for _ in 0..<numSPS {
                guard offset + 2 <= size else { break }
                let spsLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
                guard offset + spsLen <= size else { break }
                sps = data.subdata(in: offset..<(offset + spsLen))
                offset += spsLen
                break  // first SPS is sufficient
            }
            guard offset < size else { return (nil, sps, nil) }
            let numPPS = Int(data[offset])
            offset += 1
            var pps: Data?
            for _ in 0..<numPPS {
                guard offset + 2 <= size else { break }
                let ppsLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
                guard offset + ppsLen <= size else { break }
                pps = data.subdata(in: offset..<(offset + ppsLen))
                offset += ppsLen
                break  // first PPS
            }
            return (nil, sps, pps)
        }

        // Case 3: HEVC hvcC format (ISO/IEC 14496-15)
        if codec == .hevc && size >= 23 && data[0] == 1 {
            self.isAnnexBStream = false
            var vps: Data?
            var sps: Data?
            var pps: Data?
            var offset = 22
            let numOfArrays = Int(data[offset])
            offset += 1

            for _ in 0..<numOfArrays {
                guard offset + 3 <= size else { break }
                let nalType = data[offset] & 0x3F
                let numNalus = Int(data[offset + 1]) << 8 | Int(data[offset + 2])
                offset += 3

                for _ in 0..<numNalus {
                    guard offset + 2 <= size else { break }
                    let nalLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                    offset += 2
                    guard offset + nalLen <= size else { break }
                    let naluData = data.subdata(in: offset..<(offset + nalLen))
                    offset += nalLen

                    if nalType == 32 {
                        vps = naluData
                    } else if nalType == 33 {
                        sps = naluData
                    } else if nalType == 34 {
                        pps = naluData
                    }
                }
            }
            return (vps, sps, pps)
        }

        return (nil, nil, nil)
    }

    /// Synthesizes a standard 12-byte VP Codec Configuration Box (`vpcC` per ISO/IEC 14496-15)
    /// for streams (such as WebM / Matroska) where the demuxer does not supply container extradata.
    package static func synthesizeVPCC(
        profile: Int,
        level: Int,
        bitDepth: Int,
        isFullRange: Bool,
        colorPrimaries: Int,
        colorTransfer: Int,
        colorSpace: Int
    ) -> Data {
        var box = [UInt8](repeating: 0, count: 12)
        // Byte 0: version = 1
        box[0] = 1
        // Bytes 1..3: flags = 0
        box[1] = 0
        box[2] = 0
        box[3] = 0
        // Byte 4: profile (0, 1, 2, or 3). Sanitize negative / unset FFmpeg values.
        box[4] = UInt8(max(0, min(profile, 3)))
        // Byte 5: level (e.g. 10 for 1.0, 31 for 3.1, 51 for 5.1). Default to 0 if unknown/unset.
        box[5] = UInt8(max(0, min(level, 255)))
        // Byte 6: bitDepth (4 bits) | chromaSubsampling (3 bits: 0=4:2:0 vertical, 1=4:2:0 colocated, 2=4:2:2, 3=4:4:4) | videoFullRangeFlag (1 bit)
        let depthVal = UInt8(max(8, min(bitDepth, 12)))
        let chromaSubsampling: UInt8 = 1  // 4:2:0 colocated (standard for VP9)
        let fullRangeFlag: UInt8 = isFullRange ? 1 : 0
        box[6] = (depthVal << 4) | (chromaSubsampling << 1) | fullRangeFlag
        // Byte 7: colourPrimaries (ISO/IEC 23001-8 / ITU-T H.273)
        box[7] = UInt8(max(0, min(colorPrimaries, 255)))
        // Byte 8: transferCharacteristics (ISO/IEC 23001-8 / ITU-T H.273)
        box[8] = UInt8(max(0, min(colorTransfer, 255)))
        // Byte 9: matrixCoefficients (ISO/IEC 23001-8 / ITU-T H.273)
        box[9] = UInt8(max(0, min(colorSpace, 255)))
        // Bytes 10..11: codecInitializationDataSize = 0 (16-bit big endian)
        box[10] = 0
        box[11] = 0
        return Data(box)
    }

    private func extractVideoFormatDescription() -> CMVideoFormatDescription? {
        guard let ctx = formatCtx else { return nil }

        // Step 1: Try parsing from container extradata (avcC / hvcC / Annex B header)
        var (vps, sps, pps) = parseExtradata()
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

        while packetsScanned < maxPacketsToScan && av_read_frame(ctx, &pkt) >= 0 {
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
                let nalus = Self.extractNALUnits(from: data, isAnnexB: self.isAnnexBStream)
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
                            parsePrefixSEI(
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

        // Rewind to beginning of stream
        av_seek_frame(ctx, Int32(videoStreamIndex), 0, AVSEEK_FLAG_BACKWARD)

        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel

        var extensionsDict: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: colorPrimaries as String,
            kCVImageBufferTransferFunctionKey as String: transferFunction as String,
            kCVImageBufferYCbCrMatrixKey as String: yCbCrMatrix as String,
            kCMFormatDescriptionExtension_FullRangeVideo as String: isFullRange,
            kCVImageBufferChromaLocationTopFieldKey as String: kCVImageBufferChromaLocation_Left as String,
            kCVImageBufferChromaLocationBottomFieldKey as String: kCVImageBufferChromaLocation_Left as String,
        ]

        if !sampleAspectRatio.isSquare {
            let parDict: [String: Int] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: sampleAspectRatio.numerator,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: sampleAspectRatio.denominator,
            ]
            extensionsDict[kCVImageBufferPixelAspectRatioKey as String] = parDict
        }

        if let masteringDisplay {
            extensionsDict[kCVImageBufferMasteringDisplayColorVolumeKey as String] = masteringDisplay
        }
        if let contentLightLevel {
            extensionsDict[kCVImageBufferContentLightLevelInfoKey as String] = contentLightLevel
        }

        var formatDesc: CMVideoFormatDescription?
        if !codec.requiresParameterSets {
            // Codecs that construct format description via configuration atoms (av1C, vpcC, etc.)
            // or directly via CMVideoFormatDescriptionCreate without SPS/PPS parameter sets:
            if codec == .av1, videoStreamIndex >= 0, let stream = ctx.pointee.streams[videoStreamIndex],
                let extradata = stream.pointee.codecpar.pointee.extradata,
                stream.pointee.codecpar.pointee.extradata_size > 0
            {
                let extraSize = Int(stream.pointee.codecpar.pointee.extradata_size)
                let extraData = Data(bytes: extradata, count: extraSize)
                var atoms =
                    (extensionsDict[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                        as? [String: Any]) ?? [:]
                atoms["av1C"] = extraData
                extensionsDict[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms
            } else if codec == .vp9, videoStreamIndex >= 0, let stream = ctx.pointee.streams[videoStreamIndex] {
                let vpccData: Data
                if let extradata = stream.pointee.codecpar.pointee.extradata,
                    stream.pointee.codecpar.pointee.extradata_size >= 12
                {
                    vpccData = Data(bytes: extradata, count: Int(stream.pointee.codecpar.pointee.extradata_size))
                } else {
                    vpccData = Self.synthesizeVPCC(
                        profile: Int(stream.pointee.codecpar.pointee.profile),
                        level: Int(stream.pointee.codecpar.pointee.level),
                        bitDepth: self.bitDepth,
                        isFullRange: self.isFullRange,
                        colorPrimaries: Int(stream.pointee.codecpar.pointee.color_primaries.rawValue),
                        colorTransfer: Int(stream.pointee.codecpar.pointee.color_trc.rawValue),
                        colorSpace: Int(stream.pointee.codecpar.pointee.color_space.rawValue)
                    )
                }
                var atoms =
                    (extensionsDict[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                        as? [String: Any]) ?? [:]
                atoms["vpcC"] = vpccData
                extensionsDict[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms
            }

            var desc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codec.cmVideoCodecType,
                width: Int32(width),
                height: Int32(height),
                extensions: extensionsDict as CFDictionary,
                formatDescriptionOut: &desc
            )
            if status == noErr {
                formatDesc = desc
            }
        } else if let spsData = sps, let ppsData = pps {
            if codec == .hevc, let vpsData = vps {
                vpsData.withUnsafeBytes { vpsBytes in
                    spsData.withUnsafeBytes { spsBytes in
                        ppsData.withUnsafeBytes { ppsBytes in
                            let pointers: [UnsafePointer<UInt8>] = [
                                vpsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ]
                            let sizes: [Int] = [vpsData.count, spsData.count, ppsData.count]

                            var baseFormatDesc: CMVideoFormatDescription?
                            _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pointers,
                                parameterSetSizes: sizes,
                                nalUnitHeaderLength: 4,
                                extensions: extensionsDict as CFDictionary,
                                formatDescriptionOut: &baseFormatDesc
                            )

                            formatDesc = baseFormatDesc
                        }
                    }
                }
            } else if codec == .h264 {
                spsData.withUnsafeBytes { spsBytes in
                    ppsData.withUnsafeBytes { ppsBytes in
                        let pointers: [UnsafePointer<UInt8>] = [
                            spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ]
                        let sizes: [Int] = [spsData.count, ppsData.count]

                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc
                        )
                    }
                }
            }
        }

        if codec == .hevc, let baseDesc = formatDesc, let doviData = dolbyVisionConfigData,
            let dvProfile = dolbyVisionProfile
        {
            // For Dolby Vision HEVC (Profile 5, 8.1, etc.), attach the standard configuration box (dvcC for <= 7, dvvC for > 7)
            // and use kCMVideoCodecType_DolbyVisionHEVC ('dvh1') so VideoToolbox decodes the HEVC base layer
            // and parses dynamic DolbyVisionRPUData into CVPixelBuffer attachments.
            let atomKey = dvProfile <= 7 ? "dvcC" : "dvvC"
            if let rawExts = CMFormatDescriptionGetExtensions(baseDesc) as? [String: Any] {
                var newExts = rawExts
                var atoms =
                    (rawExts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any])
                    ?? [:]
                atoms[atomKey] = doviData
                newExts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms

                var dvDesc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    codecType: kCMVideoCodecType_DolbyVisionHEVC,
                    width: Int32(self.width),
                    height: Int32(self.height),
                    extensions: newExts as CFDictionary,
                    formatDescriptionOut: &dvDesc
                )
                if status == noErr, let dvDesc {
                    AppLog.info(
                        .video,
                        "Configured Dolby Vision formatDescription (Profile \(dvProfile), codec: dvh1, atom: \(atomKey))"
                    )
                    return dvDesc
                }
            }
        }

        return formatDesc
    }

    private func parsePrefixSEI(naluData: Data, masteringDisplay: inout Data?, contentLightLevel: inout Data?) {
        var p = 2
        while p < naluData.count {
            var payloadType = 0
            while p < naluData.count && naluData[p] == 0xFF {
                payloadType += 255
                p += 1
            }
            if p < naluData.count {
                payloadType += Int(naluData[p])
                p += 1
            }

            var payloadSize = 0
            while p < naluData.count && naluData[p] == 0xFF {
                payloadSize += 255
                p += 1
            }
            if p < naluData.count {
                payloadSize += Int(naluData[p])
                p += 1
            }

            guard p + payloadSize <= naluData.count else { break }
            let rawPayload = naluData.subdata(in: p..<(p + payloadSize))

            // Remove emulation prevention bytes (0x00 0x00 0x03 -> 0x00 0x00)
            var unescaped: [UInt8] = []
            unescaped.reserveCapacity(rawPayload.count)
            var u = 0
            let rawBytes = [UInt8](rawPayload)
            while u < rawBytes.count {
                if u + 2 < rawBytes.count && rawBytes[u] == 0 && rawBytes[u + 1] == 0 && rawBytes[u + 2] == 3 {
                    unescaped.append(0)
                    unescaped.append(0)
                    u += 3
                } else {
                    unescaped.append(rawBytes[u])
                    u += 1
                }
            }

            // SEI 137: Mastering display colour volume (24 bytes)
            if payloadType == 137 && unescaped.count >= 24 {
                masteringDisplay = Data(unescaped[0..<24])
                if self.maxPeakNits == 1000.0 {
                    let maxLumRaw =
                        (UInt32(unescaped[16]) << 24) | (UInt32(unescaped[17]) << 16) | (UInt32(unescaped[18]) << 8)
                        | UInt32(unescaped[19])
                    let maxLumNits = Float(maxLumRaw) / 10000.0
                    if maxLumNits > 0 {
                        self.maxPeakNits = maxLumNits
                    }
                }
            }
            // SEI 144: Content light level info (4 bytes: maxCLL 2 bytes, maxFALL 2 bytes)
            else if payloadType == 144 && unescaped.count >= 4 {
                contentLightLevel = Data(unescaped[0..<4])
                let maxCLL = (Int(unescaped[0]) << 8) | Int(unescaped[1])
                let maxFALL = (Int(unescaped[2]) << 8) | Int(unescaped[3])
                if maxCLL > 0 {
                    self.maxPeakNits = Float(maxCLL)
                }
                if maxFALL > 0 {
                    self.maxFallNits = Float(maxFALL)
                }
            }

            p += payloadSize
        }
    }

    private var targetPts: Int64 = -1
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
            if let nalu = Self.findNALUnit62(bytes: bytes, count: count, isAnnexB: self.isAnnexBStream) {
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
                let (hvccData, hvccSize) = Self.packetDataToHVCC(
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
        if targetPts >= 0 && ptsVal >= targetPts {
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

            if isBeforeTarget {
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true)
                    as? [NSMutableDictionary], let first = attachments.first
                {
                    first[kCMSampleAttachmentKey_DoNotDisplay] = true
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
        while av_read_frame(ctx, &pkt) >= 0 {
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
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let isKey = (pkt.flags & AV_PKT_FLAG_KEY) != 0
                let audioPacket = DemuxedAudioPacket(
                    data: data,
                    pts: pkt.pts,
                    dts: pkt.dts,
                    duration: pkt.duration,
                    isKeyFrame: isKey
                )
                audioQueue.append(audioPacket)
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
                let packetEndPts = p.pts + (p.duration > 0 ? p.duration : 0)
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
        while av_read_frame(ctx, &pkt) >= 0 {
            if pkt.stream_index == audioStreamIndex {
                let pktPts = pkt.pts
                let pktDuration = pkt.duration
                if targetAudioPts >= 0 {
                    let packetEndPts = pktPts + (pktDuration > 0 ? pktDuration : 0)
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
    public func seek(to seconds: Double, exact: Bool = true, forward: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx else { return }
        audioQueue.removeAll()
        videoQueue.removeAll()
        lastAudioPts = -1
        isEOFInternal = false
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
        var ret: Int32 = -1
        if useForward {
            ret = av_seek_frame(ctx, Int32(streamIdx), target, 0)
        }
        if ret < 0 {
            // Backward search (also the fallback when no keyframe exists after target, e.g. near EOF)
            ret = av_seek_frame(ctx, Int32(streamIdx), target, AVSEEK_FLAG_BACKWARD)
        }
        AppLog.debug(
            .demuxer,
            "av_seek_frame to targetPts: \(target) (exact: \(exact), forward: \(useForward)), targetAudioPts: \(self.targetAudioPts) (seconds: \(seconds)), stream: \(streamIdx), ret: \(ret)"
        )
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

    // MARK: - Annex B / HVCC Utilities

    /// Parses NAL units from either Annex B byte stream (0x000001 or 0x00000001 start codes)
    /// or MP4/hvcC format (4-byte big endian length prefixed).
    static func extractNALUnits(from data: Data, isAnnexB: Bool? = nil) -> [Data] {
        guard data.count >= 4 else { return [] }

        let bytes = [UInt8](data)
        let count = bytes.count

        // If format is explicitly known, use it; otherwise inspect start code
        let annexB: Bool
        if let isAnnexB {
            annexB = isAnnexB
        } else {
            annexB =
                (bytes[0] == 0 && bytes[1] == 0 && (bytes[2] == 1 || (count > 3 && bytes[2] == 0 && bytes[3] == 1)))
        }

        if annexB {
            var nalus: [Data] = []
            var starts: [(offset: Int, prefixLen: Int)] = []

            var i = 0
            while i + 2 < count {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 {
                        starts.append((offset: i, prefixLen: 3))
                        i += 3
                        continue
                    } else if i + 3 < count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                        starts.append((offset: i, prefixLen: 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }

            for (idx, start) in starts.enumerated() {
                let nalStart = start.offset + start.prefixLen
                let nalEnd = (idx + 1 < starts.count) ? starts[idx + 1].offset : count
                if nalEnd > nalStart {
                    nalus.append(data.subdata(in: nalStart..<nalEnd))
                }
            }
            return nalus
        } else {
            // Standard MP4 length-prefixed format
            var nalus: [Data] = []
            var offset = 0
            while offset + 4 <= count {
                let naluLen =
                    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                    | Int(bytes[offset + 3])
                offset += 4
                guard naluLen > 0, offset + naluLen <= count else { break }
                nalus.append(data.subdata(in: offset..<(offset + naluLen)))
                offset += naluLen
            }
            return nalus
        }
    }

    /// Fast scan for HEVC NAL unit type 62 (Dolby Vision RPU) without allocating all NAL units.
    static func findNALUnit62(in data: Data, isAnnexB: Bool) -> Data? {
        data.withUnsafeBytes { ptr -> Data? in
            guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return findNALUnit62(bytes: bytes, count: data.count, isAnnexB: isAnnexB)
        }
    }

    static func findNALUnit62(bytes: UnsafePointer<UInt8>, count: Int, isAnnexB: Bool) -> Data? {
        guard count >= 5 else { return nil }
        if isAnnexB {
            var i = 0
            while i + 4 < count {
                let prefixLen: Int
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 {
                        prefixLen = 3
                    } else if bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                        prefixLen = 4
                    } else {
                        i += 1
                        continue
                    }
                } else {
                    i += 1
                    continue
                }

                let nalStart = i + prefixLen
                guard nalStart < count else { break }
                let nalType = (bytes[nalStart] >> 1) & 0x3F

                if nalType == 62 {
                    // Find the end of this NALU (next start code or EOF)
                    var next = nalStart + 1
                    while next + 2 < count {
                        if bytes[next] == 0 && bytes[next + 1] == 0
                            && (bytes[next + 2] == 1
                                || (next + 3 < count && bytes[next + 2] == 0 && bytes[next + 3] == 1))
                        {
                            break
                        }
                        next += 1
                    }
                    let nalEnd = (next + 2 < count) ? next : count
                    return Data(bytes: bytes.advanced(by: nalStart), count: nalEnd - nalStart)
                }

                i = nalStart
            }
            return nil
        } else {
            var offset = 0
            while offset + 4 <= count {
                let naluLen =
                    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                    | Int(bytes[offset + 3])
                offset += 4
                guard naluLen > 0, offset + naluLen <= count else { break }
                let nalType = (bytes[offset] >> 1) & 0x3F
                if nalType == 62 {
                    return Data(bytes: bytes.advanced(by: offset), count: naluLen)
                }
                offset += naluLen
            }
            return nil
        }
    }

    /// Converts an input packet to HVCC format expected by VideoToolbox (4-byte length prefix).
    /// If packet is already in length-prefixed format, it returns the raw packet bytes directly.
    static func packetDataToHVCC(pktData: UnsafePointer<UInt8>?, count: Int, isAnnexBStream: Bool = false) -> (
        Data, Int
    ) {
        guard let pktData, count >= 4 else {
            return (Data(), 0)
        }

        // Only treat as Annex B if either the stream is known to be Annex B,
        // or the packet starts with Annex B and cannot be a 4-byte length prefix.
        let isAnnexB: Bool
        if isAnnexBStream {
            isAnnexB =
                (pktData[0] == 0 && pktData[1] == 0
                    && (pktData[2] == 1 || (count > 3 && pktData[2] == 0 && pktData[3] == 1)))
        } else {
            // For container streams (MP4/MKV), packets are length-prefixed (avcC/hvcC format).
            // A packet starting with 0x00 0x00 0x01 ... has a 4-byte length between 65536 and 131071.
            // Do NOT re-parse as Annex B unless the stream format is Annex B!
            isAnnexB = false
        }

        if !isAnnexB {
            let data = Data(bytes: pktData, count: count)
            return (data, count)
        }

        // Convert Annex B to 4-byte length prefix
        var starts: [(offset: Int, prefixLen: Int)] = []
        var i = 0
        while i + 2 < count {
            if pktData[i] == 0 && pktData[i + 1] == 0 {
                if pktData[i + 2] == 1 {
                    starts.append((offset: i, prefixLen: 3))
                    i += 3
                    continue
                } else if i + 3 < count && pktData[i + 2] == 0 && pktData[i + 3] == 1 {
                    starts.append((offset: i, prefixLen: 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        var hvccData = Data()
        hvccData.reserveCapacity(count + 32)

        for (idx, start) in starts.enumerated() {
            let nalStart = start.offset + start.prefixLen
            let nalEnd = (idx + 1 < starts.count) ? starts[idx + 1].offset : count
            let nalSize = nalEnd - nalStart
            guard nalSize > 0 else { continue }

            var bigEndianLength = UInt32(nalSize).bigEndian
            withUnsafeBytes(of: &bigEndianLength) { lenBytes in
                hvccData.append(contentsOf: lenBytes)
            }
            let nalPtr = pktData.advanced(by: nalStart)
            hvccData.append(nalPtr, count: nalSize)
        }

        let finalCount = hvccData.count
        return (hvccData, finalCount)
    }
}
