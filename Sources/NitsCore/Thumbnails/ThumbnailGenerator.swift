import CFFmpeg
import CoreGraphics
import Foundation
import QuartzCore

/// Low-priority background thumbnail generator.
/// Opens its own independent `AVFormatContext` and `AVCodecContext` to demux and decode
/// keyframes across the file without interfering with the playback engine.
public final class ThumbnailGenerator: @unchecked Sendable {
    /// Covers the 176 pt preview card at 2x scale.
    public static let targetThumbnailWidth: Int32 = 384
    /// Height limit for portrait video.
    public static let maxThumbnailHeight: Int32 = 288
    public static let defaultThumbnailCount: Int = 120

    private let path: String
    private let duration: Double
    private let headers: [String: String]
    private let httpRequestSize: Int?
    private let cancelToken = FFmpegInterrupt()

    public init(path: String, duration: Double = 0, headers: [String: String] = [:], httpRequestSize: Int? = nil) {
        self.path = path
        self.duration = duration
        self.headers = headers
        self.httpRequestSize = httpRequestSize
    }

    public var isCancelled: Bool {
        cancelToken.isCancelled
    }

    public func cancel() {
        cancelToken.cancel()
    }

    /// Generates keyframe thumbnails asynchronously across the duration of the video.
    /// Periodically calls `onProgress` with the results so far and the fraction of sample points processed.
    public func generateThumbnails(
        onProgress: @Sendable @escaping ([ThumbnailItem], Double) -> Void
    ) async -> [ThumbnailItem] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: [])
                        return
                    }

                    let items = self.runGeneration(onProgress: onProgress)
                    continuation.resume(returning: items)
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    private func runGeneration(
        onProgress: @Sendable @escaping ([ThumbnailItem], Double) -> Void
    ) -> [ThumbnailItem] {
        guard !isCancelled else { return [] }

        let cleanPath = MediaURL.normalizeMediaPath(path)
        // A finished HLS stream goes through Nits' own client: FFmpeg has no HLS demuxer left to open it.
        var opened: ThumbnailSource?
        if HLSInput.applies(to: cleanPath) {
            opened = ThumbnailSource.openHLS(url: cleanPath, headers: headers, interrupt: cancelToken)
        } else {
            var failure: Int32 = 0
            opened = ThumbnailSource.openFFmpeg(
                path: path, headers: headers, httpRequestSize: httpRequestSize, interrupt: cancelToken,
                failureCode: &failure)
            // A playlist under a name that tells none: FFmpeg could not open it, or took it for text.
            let mayBePlaylist = opened.map(\.isTextFormat) ?? (failure == MediaDemuxer.averrorInvalidData)
            if mayBePlaylist, !isCancelled,
                HLSInput.sniffsAsPlaylist(cleanPath, headers: headers, interrupt: cancelToken)
            {
                opened?.close()
                opened = ThumbnailSource.openHLS(url: cleanPath, headers: headers, interrupt: cancelToken)
            }
        }
        guard let source = opened else { return [] }
        defer { source.close() }
        guard !isCancelled else { return [] }

        let stream = source.stream
        let streamIndex = source.streamIndex
        let codecpar = stream.pointee.codecpar!
        let timebase = stream.pointee.time_base
        guard timebase.den > 0 else {
            AppLog.error(.engine, "ThumbnailGenerator: Invalid video timebase in '\(cleanPath)'")
            return []
        }

        guard let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            AppLog.error(.engine, "ThumbnailGenerator: Decoder not found for codec ID \(codecpar.pointee.codec_id)")
            return []
        }

        guard let codecCtx = avcodec_alloc_context3(decoder) else {
            AppLog.error(.engine, "ThumbnailGenerator: Failed to allocate AVCodecContext")
            return []
        }
        defer {
            var tempCodecCtx: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&tempCodecCtx)
        }

        var ret = avcodec_parameters_to_context(codecCtx, codecpar)
        guard ret >= 0 else {
            AppLog.error(.engine, "ThumbnailGenerator: avcodec_parameters_to_context failed (code \(ret))")
            return []
        }

        // Configure multithreading for software decoder
        codecCtx.pointee.thread_count = 2
        codecCtx.pointee.thread_type = FF_THREAD_SLICE

        ret = avcodec_open2(codecCtx, decoder, nil)
        guard ret >= 0 else {
            AppLog.error(.engine, "ThumbnailGenerator: avcodec_open2 failed (code \(ret))")
            return []
        }

        let durationSeconds: Double = {
            if duration > 0 {
                return duration
            } else if source.containerDuration > 0 {
                return source.containerDuration
            } else if stream.pointee.duration > 0 {
                return Double(stream.pointee.duration) * Double(timebase.num) / Double(timebase.den)
            }
            return 0
        }()

        guard durationSeconds > 0 else {
            AppLog.warning(.engine, "ThumbnailGenerator: Duration is <= 0 (\(durationSeconds)) for '\(cleanPath)'")
            return []
        }

        let videoWidth = codecpar.pointee.width
        let videoHeight = codecpar.pointee.height
        guard videoWidth > 0 && videoHeight > 0 else {
            AppLog.warning(.engine, "ThumbnailGenerator: Invalid video dimensions \(videoWidth)x\(videoHeight)")
            return []
        }

        // Anamorphic video: the scaler stretches samples to the display aspect ratio.
        let sampleAspect = source.sampleAspect
        let pixelAspect = sampleAspect.num > 0 && sampleAspect.den > 0 ? av_q2d(sampleAspect) : 1
        let thumbSize = Self.thumbnailSize(displayAspect: Double(videoWidth) * pixelAspect / Double(videoHeight))
        guard
            let converter = ThumbnailFrameConverter(
                width: thumbSize.width,
                height: thumbSize.height,
                isDolbyVisionProfile5: Self.dolbyVisionProfile(codecpar) == 5
            )
        else { return [] }

        let frame = av_frame_alloc()
        let packet = av_packet_alloc()
        defer {
            var f = frame
            var p = packet
            av_frame_free(&f)
            av_packet_free(&p)
        }

        guard let frame, let packet else { return [] }

        var seenKeyPackets = Set<Int64>()
        // Same zero-based timeline as MediaDemuxer (MPEG-TS / MPEG-PS start wherever the source clock was).
        let timelineOffset = source.timelineOffset
        var seenFramePts = Set<Int64>()
        let dolbyVisionProfile = Self.dolbyVisionProfile(codecpar)
        let staticLuminance = Self.staticLuminance(codecpar)
        let videoCodec = VideoCodec.from(codecId: codecpar.pointee.codec_id)
        let isPQ = codecpar.pointee.color_trc == AVCOL_TRC_SMPTE2084 || dolbyVisionProfile == 5
        let isAnnexB = videoCodec.map { Self.isAnnexB(codecpar, codec: $0) } ?? false
        let lengthSize = videoCodec.map { NALUnitParser.lengthSize(of: codecpar, codec: $0) } ?? 4
        /// The dynamic HDR metadata of the packets sent since the last seek, by their PTS, for the frames they decode to.
        var hdrMetadataByPts: [Int64: FrameHDRMetadata] = [:]

        func sendPacket() -> Bool {
            if let videoCodec, let data = packet.pointee.data, packet.pointee.size > 4,
                let metadata = FrameHDRMetadata(
                    packet: data, count: Int(packet.pointee.size), codec: videoCodec, isAnnexB: isAnnexB,
                    lengthSize: lengthSize,
                    readsRPU: dolbyVisionProfile != nil, readsHDR10Plus: isPQ)
            {
                hdrMetadataByPts[packet.pointee.pts] = metadata
            }
            return avcodec_send_packet(codecCtx, packet) >= 0
        }

        /// Pulls decoded frames and returns the first one not produced before.
        func receiveNewFrame(fallbackTime: Double) -> ThumbnailItem? {
            while avcodec_receive_frame(codecCtx, frame) == 0 {
                let pts =
                    frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp
                    : frame.pointee.pts
                // Frames without a timestamp can't be told apart, so they skip deduplication.
                let metadata = hdrMetadataByPts[frame.pointee.pts]
                guard pts == Int64.min || seenFramePts.insert(pts).inserted,
                    let image = converter.makeImage(
                        from: frame, codecpar: codecpar,
                        dolbyVision: (dolbyVisionProfile == 5 ? metadata?.dolbyVision : nil)
                            .flatMap(DolbyVisionPixelReshaping.init(metadata:)),
                        curve: staticLuminance.curve(for: metadata))
                else { continue }

                let seconds =
                    pts != Int64.min && pts - timelineOffset >= 0
                    ? Double(pts - timelineOffset) * Double(timebase.num) / Double(timebase.den)
                    : fallbackTime
                return ThumbnailItem(
                    time: seconds,
                    image: image,
                    width: Int(thumbSize.width),
                    height: Int(thumbSize.height)
                )
            }
            return nil
        }

        /// Decodes the first new frame after a seek.
        func decodeFrameAfterSeek(fallbackTime: Double, keyframeShortcut: Bool, maxVideoPackets: Int) -> ThumbnailItem?
        {
            var videoPacketsRead = 0
            var totalPacketsRead = 0
            while videoPacketsRead < maxVideoPackets && totalPacketsRead < 300 && !isCancelled
                && source.read(packet) >= 0
            {
                defer { av_packet_unref(packet) }
                totalPacketsRead += 1
                guard packet.pointee.stream_index == streamIndex else { continue }
                videoPacketsRead += 1

                // The seek landed on a keyframe: decode only that packet and drain, instead of
                // feeding the decoder until its reorder delay releases a frame.
                let isKeyframe = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                if keyframeShortcut && videoPacketsRead == 1 && isKeyframe {
                    let packetTime = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
                    // Several targets inside one GOP land on the same keyframe; decode it once.
                    if packetTime != Int64.min && !seenKeyPackets.insert(packetTime).inserted {
                        return nil
                    }
                    guard sendPacket() else { return nil }
                    _ = avcodec_send_packet(codecCtx, nil)
                    return receiveNewFrame(fallbackTime: fallbackTime)
                }

                guard sendPacket() else { return nil }
                if let item = receiveNewFrame(fallbackTime: fallbackTime) {
                    return item
                }
            }
            return nil
        }

        // Generate sample points
        let count = min(Self.defaultThumbnailCount, max(10, Int(durationSeconds / 2.0)))
        let interval = durationSeconds / Double(count)

        var allThumbnails: [ThumbnailItem] = []
        var pendingCount = 0
        var lastEmittedTime = CACurrentMediaTime()

        for (completed, i) in Self.coarseToFineOrder(count: count).enumerated() {
            guard !isCancelled else { break }

            let targetTime = Double(i) * interval
            source.seek(toSeconds: targetTime)
            avcodec_flush_buffers(codecCtx)
            hdrMetadataByPts.removeAll(keepingCapacity: true)

            if let item = decodeFrameAfterSeek(fallbackTime: targetTime, keyframeShortcut: true, maxVideoPackets: 30) {
                allThumbnails.append(item)
                pendingCount += 1
            }

            let now = CACurrentMediaTime()
            if pendingCount > 0 && (now - lastEmittedTime >= 0.25 || pendingCount >= 8) {
                allThumbnails.sort { $0.time < $1.time }
                onProgress(allThumbnails, Double(completed + 1) / Double(count))
                pendingCount = 0
                lastEmittedTime = now
            }
        }

        // Fallback: If seeking produced 0 thumbnails, decode the first frame linearly from start
        if allThumbnails.isEmpty && !isCancelled {
            source.seekToBeginning()
            avcodec_flush_buffers(codecCtx)
            hdrMetadataByPts.removeAll()
            if let item = decodeFrameAfterSeek(fallbackTime: 0, keyframeShortcut: false, maxVideoPackets: 300) {
                allThumbnails.append(item)
                pendingCount += 1
            }
        }

        // Sample points are visited out of order; callers get thumbnails sorted by time.
        allThumbnails.sort { $0.time < $1.time }
        if pendingCount > 0 {
            onProgress(allThumbnails, 1.0)
        }

        return allThumbnails
    }

    /// Thumbnail pixel size for a display aspect ratio (pixel aspect already applied):
    /// `targetThumbnailWidth` wide, or `maxThumbnailHeight` tall for portrait video.
    static func thumbnailSize(displayAspect aspect: Double) -> (width: Int32, height: Int32) {
        guard aspect > 0, aspect.isFinite else {
            return (targetThumbnailWidth, targetThumbnailWidth * 9 / 16)
        }
        let height = Double(targetThumbnailWidth) / aspect
        if height <= Double(maxThumbnailHeight) {
            return (targetThumbnailWidth, max(16, Int32(height.rounded())))
        }
        return (max(16, Int32((Double(maxThumbnailHeight) * aspect).rounded())), maxThumbnailHeight)
    }

    /// Whether the stream's packets are Annex B (start codes) rather than length-prefixed, as the demuxer tells it:
    /// from the extradata's form (hvcC / avcC, or Annex B parameter sets), Annex B without any (MPEG-TS). The first
    /// bytes of a packet can't tell: a 4-byte length of 256 to 511 reads as a start code.
    static func isAnnexB(_ codecpar: UnsafeMutablePointer<AVCodecParameters>, codec: VideoCodec) -> Bool {
        guard let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else { return true }
        return VideoFormatDescriptionBuilder.parameterSets(
            fromExtradata: Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size)), codec: codec)?
            .isAnnexB ?? (extradata[0] == 0)
    }

    /// The Dolby Vision profile of the stream, nil for none: from its configuration record.
    static func dolbyVisionProfile(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        let sideDataCount = Int(codecpar.pointee.nb_coded_side_data)
        if sideDataCount > 0, let sideData = codecpar.pointee.coded_side_data {
            for index in 0..<sideDataCount where sideData[index].type == AV_PKT_DATA_DOVI_CONF {
                guard let data = sideData[index].data,
                    sideData[index].size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
                else { continue }
                let record = UnsafeRawPointer(data).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self)
                return Int(record.pointee.dv_profile)
            }
        }
        if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size >= 24 {
            let data = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            return HDRMetadataEncoding.parseDolbyVisionConfigurationBox(from: data).map { Int($0.profile) }
        }
        return nil
    }

    /// The stream's static luminance, as the player adapts to it on load (`ToneMapController.adapt`), and the curve of
    /// a frame from it and the frame's dynamic metadata (`ToneMapController.applyFrame`).
    struct StaticLuminance {
        /// MaxCLL, else the mastering display's peak; nil without either.
        let peakNits: Float?
        let fallNits: Float

        func curve(for metadata: FrameHDRMetadata?) -> ThumbnailToneMapper.Curve {
            // Without a static peak, a Profile 5 RPU's source display peak stands in for it.
            var staticPeak = peakNits ?? 1000
            if peakNits == nil, let sourceMaxPQ = metadata?.dolbyVision?.sourceMaxPQ, sourceMaxPQ > 0 {
                staticPeak = max(DolbyVisionRPUParser.pqToNits(Float(sourceMaxPQ) / 4095), 100)
            }
            let staticWhite = ToneMapController.adaptiveTargetNits(maxPeakNits: staticPeak, maxFallNits: fallNits)
            let l1Peak = metadata?.dolbyVision?.l1.map(\.maxNits).flatMap { $0 > 0 ? $0 : nil }
            guard let scenePeak = l1Peak ?? metadata?.hdr10Plus?.maxNits else {
                return ThumbnailToneMapper.Curve(peakNits: staticPeak, whiteNits: staticWhite)
            }
            return ThumbnailToneMapper.Curve(
                peakNits: scenePeak,
                whiteNits: ToneMapController.sceneTargetNits(scenePeakNits: scenePeak, staticTargetNits: staticWhite))
        }
    }

    /// MaxCLL / MaxFALL and the mastering display's peak from the stream's side data.
    static func staticLuminance(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> StaticLuminance {
        var maxCLL: Float?
        var maxFALL: Float = 0
        var masteringPeak: Float?
        let sideDataCount = Int(codecpar.pointee.nb_coded_side_data)
        if sideDataCount > 0, let sideData = codecpar.pointee.coded_side_data {
            for index in 0..<sideDataCount {
                guard let data = sideData[index].data else { continue }
                if sideData[index].type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
                    sideData[index].size >= MemoryLayout<AVContentLightMetadata>.size
                {
                    let level = UnsafeRawPointer(data).assumingMemoryBound(to: AVContentLightMetadata.self).pointee
                    if level.MaxCLL > 0 { maxCLL = Float(level.MaxCLL) }
                    maxFALL = Float(level.MaxFALL)
                } else if sideData[index].type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
                    sideData[index].size >= MemoryLayout<AVMasteringDisplayMetadata>.size
                {
                    let display = UnsafeRawPointer(data).assumingMemoryBound(to: AVMasteringDisplayMetadata.self)
                        .pointee
                    if display.has_luminance != 0, display.max_luminance.den > 0, display.max_luminance.num > 0 {
                        masteringPeak = Float(av_q2d(display.max_luminance))
                    }
                }
            }
        }
        return StaticLuminance(peakNits: maxCLL ?? masteringPeak, fallNits: maxFALL)
    }

    /// Sample indices ordered coarse-to-fine (0, ½, ¼, ¾, ⅛, …) so the whole timeline gets
    /// coverage early and is refined as generation continues.
    static func coarseToFineOrder(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var order: [Int] = []
        order.reserveCapacity(count)
        var visited = [Bool](repeating: false, count: count)
        var step = 1
        while step < count { step *= 2 }
        while step >= 1 {
            for index in stride(from: 0, to: count, by: step) where !visited[index] {
                visited[index] = true
                order.append(index)
            }
            step /= 2
        }
        return order
    }
}
