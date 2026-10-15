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
    private let cancelToken = FFmpegInterrupt()

    public init(path: String, duration: Double = 0, headers: [String: String] = [:]) {
        self.path = path
        self.duration = duration
        self.headers = headers
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

        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let fmtCtx = formatCtx else { return [] }

        // Setup interrupt callback to abort hung network requests or cancellation cleanly.
        // `self` owns the token and outlives `fmtCtx`, which is closed before this method returns.
        cancelToken.install(on: fmtCtx)

        var avOptions: OpaquePointer? = nil
        defer {
            if avOptions != nil {
                av_dict_free(&avOptions)
            }
        }

        if MediaURL.isNetworkURL(path) {
            MediaURL.applyNetworkOptions(&avOptions, headers: headers)
        }

        let cleanPath = PlayerEngine.normalizeMediaPath(path)

        var ret = avformat_open_input(&formatCtx, cleanPath, nil, &avOptions)
        guard ret >= 0, let activeFormatCtx = formatCtx else {
            let errorMsg = MediaDemuxer.ffmpegErrorDescription(ret)
            AppLog.error(
                .engine,
                "ThumbnailGenerator: avformat_open_input failed with code \(ret) (\(errorMsg)) for '\(cleanPath)'")
            return []
        }
        defer {
            var tempCtx: UnsafeMutablePointer<AVFormatContext>? = activeFormatCtx
            avformat_close_input(&tempCtx)
        }

        guard !isCancelled else { return [] }

        ret = avformat_find_stream_info(activeFormatCtx, nil)
        guard ret >= 0 else {
            let errorMsg = MediaDemuxer.ffmpegErrorDescription(ret)
            AppLog.error(.engine, "ThumbnailGenerator: avformat_find_stream_info failed with code \(ret) (\(errorMsg))")
            return []
        }

        // Find best video stream
        let streamIndex = av_find_best_stream(activeFormatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard streamIndex >= 0 else {
            AppLog.error(.engine, "ThumbnailGenerator: No video stream found in '\(cleanPath)'")
            return []
        }

        let stream = activeFormatCtx.pointee.streams[Int(streamIndex)]!
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

        ret = avcodec_parameters_to_context(codecCtx, codecpar)
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
            } else if activeFormatCtx.pointee.duration > 0 {
                return Double(activeFormatCtx.pointee.duration) / Double(AV_TIME_BASE)
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
        let sampleAspect = av_guess_sample_aspect_ratio(activeFormatCtx, stream, nil)
        let pixelAspect = sampleAspect.num > 0 && sampleAspect.den > 0 ? av_q2d(sampleAspect) : 1
        let thumbSize = Self.thumbnailSize(displayAspect: Double(videoWidth) * pixelAspect / Double(videoHeight))
        guard
            let converter = ThumbnailFrameConverter(
                width: thumbSize.width,
                height: thumbSize.height,
                isDolbyVisionProfile5: Self.isDolbyVisionProfile5(codecpar)
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
        let timelineOrigin = MediaDemuxer.timelineOrigin(of: activeFormatCtx)
        let timelineOffset = MediaDemuxer.timelineOffset(timelineOrigin, in: timebase)
        var seenFramePts = Set<Int64>()

        /// Pulls decoded frames and returns the first one not produced before.
        func receiveNewFrame(fallbackTime: Double) -> ThumbnailItem? {
            while avcodec_receive_frame(codecCtx, frame) == 0 {
                let pts =
                    frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp
                    : frame.pointee.pts
                // Frames without a timestamp can't be told apart, so they skip deduplication.
                guard pts == Int64.min || seenFramePts.insert(pts).inserted,
                    let image = converter.makeImage(from: frame, codecpar: codecpar)
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
                && av_read_frame(activeFormatCtx, packet) >= 0
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
                    guard avcodec_send_packet(codecCtx, packet) >= 0 else { return nil }
                    _ = avcodec_send_packet(codecCtx, nil)
                    return receiveNewFrame(fallbackTime: fallbackTime)
                }

                guard avcodec_send_packet(codecCtx, packet) >= 0 else { return nil }
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
            let targetPts = Int64(round(targetTime * Double(timebase.den) / Double(timebase.num))) + timelineOffset

            // Seek backward to keyframe (try stream-level seek first, then format-level)
            let seekRet = av_seek_frame(activeFormatCtx, streamIndex, targetPts, AVSEEK_FLAG_BACKWARD)
            if seekRet < 0 {
                let targetPtsAV = Int64(round(targetTime * Double(AV_TIME_BASE))) + timelineOrigin
                _ = av_seek_frame(activeFormatCtx, -1, targetPtsAV, AVSEEK_FLAG_BACKWARD)
            }
            avcodec_flush_buffers(codecCtx)

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
            _ = av_seek_frame(activeFormatCtx, -1, 0, AVSEEK_FLAG_BACKWARD)
            avcodec_flush_buffers(codecCtx)
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

    /// True for Dolby Vision Profile 5, whose IPT-PQ-C2 base layer needs its own conversion.
    static func isDolbyVisionProfile5(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        let sideDataCount = Int(codecpar.pointee.nb_coded_side_data)
        if sideDataCount > 0, let sideData = codecpar.pointee.coded_side_data {
            for index in 0..<sideDataCount where sideData[index].type == AV_PKT_DATA_DOVI_CONF {
                guard let data = sideData[index].data,
                    sideData[index].size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
                else { continue }
                let record = UnsafeRawPointer(data).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self)
                return record.pointee.dv_profile == 5
            }
        }
        if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size >= 24 {
            let data = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            return HDRMetadataEncoding.parseDolbyVisionConfigurationBox(from: data)?.profile == 5
        }
        return false
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
