import CFFmpeg
import CoreGraphics
import Foundation
import QuartzCore
import os

/// Low-priority background thumbnail generator.
/// Opens its own independent `AVFormatContext` and `AVCodecContext` to demux and decode
/// keyframes across the file without interfering with the playback engine.
public final class ThumbnailGenerator: @unchecked Sendable {
    public static let targetThumbnailWidth: Int32 = 240
    public static let defaultThumbnailCount: Int = 120

    private final class CancelToken: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool {
            lock.withLock { $0 }
        }
        func cancel() {
            lock.withLock { $0 = true }
        }
    }

    private let path: String
    private let duration: Double
    private let headers: [String: String]
    private let cancelToken = CancelToken()

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
    /// Periodically calls `onProgress` with progressive results.
    public func generateThumbnails(
        onProgress: @Sendable @escaping ([ThumbnailItem]) -> Void
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
        onProgress: @Sendable @escaping ([ThumbnailItem]) -> Void
    ) -> [ThumbnailItem] {
        guard !isCancelled else { return [] }

        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let fmtCtx = formatCtx else { return [] }

        // Setup interrupt callback to abort hung network requests or cancellation cleanly.
        let token = self.cancelToken
        typealias CancelCheck = @convention(c) (UnsafeMutableRawPointer?) -> Int32
        let cancelCheck: CancelCheck = { opaque in
            guard let opaque else { return 0 }
            let token = Unmanaged<CancelToken>.fromOpaque(opaque).takeUnretainedValue()
            return token.isCancelled ? 1 : 0
        }
        fmtCtx.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(token).toOpaque()
        fmtCtx.pointee.interrupt_callback.callback = cancelCheck

        var avOptions: OpaquePointer? = nil
        defer {
            if avOptions != nil {
                av_dict_free(&avOptions)
            }
        }

        if MediaDemuxer.isNetworkURL(path) {
            if !headers.isEmpty {
                var headerString = ""
                for (key, value) in headers {
                    let cleanKey = key.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                    let cleanVal = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(
                        of: "\n", with: "")
                    guard !cleanKey.isEmpty else { continue }
                    if cleanKey.lowercased() == "user-agent" {
                        _ = av_dict_set(&avOptions, "user_agent", cleanVal, 0)
                    } else {
                        headerString += "\(cleanKey): \(cleanVal)\r\n"
                    }
                }
                if !headerString.isEmpty {
                    _ = av_dict_set(&avOptions, "headers", headerString, 0)
                }
            }
            _ = av_dict_set(&avOptions, "reconnect", "1", 0)
            _ = av_dict_set(&avOptions, "reconnect_streamed", "1", 0)
            _ = av_dict_set(&avOptions, "reconnect_delay_max", "5", 0)
            _ = av_dict_set(&avOptions, "rw_timeout", "10000000", 0)
            _ = av_dict_set(&avOptions, "timeout", "10000000", 0)
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

        // Target thumbnail size
        let thumbWidth = Self.targetThumbnailWidth
        let thumbHeight = max(16, Int32(round(Float(thumbWidth) * Float(videoHeight) / Float(videoWidth))))

        // Prepare sws_scale context lazily based on codec parameters or decoded frame format
        var sourcePixFmt = AVPixelFormat(codecpar.pointee.format)
        if sourcePixFmt == AV_PIX_FMT_NONE {
            sourcePixFmt = codecCtx.pointee.pix_fmt
        }

        var swsCtx: UnsafeMutablePointer<SwsContext>? = nil
        if sourcePixFmt != AV_PIX_FMT_NONE {
            swsCtx = sws_getContext(
                videoWidth,
                videoHeight,
                sourcePixFmt,
                thumbWidth,
                thumbHeight,
                AV_PIX_FMT_RGBA,
                Int32(SWS_BILINEAR.rawValue),
                nil,
                nil,
                nil
            )
            if let activeCtx = swsCtx {
                Self.configureSwsColorspace(swsCtx: activeCtx, frame: nil, codecpar: codecpar)
            }
        }
        defer {
            if let swsCtx {
                sws_freeContext(swsCtx)
            }
        }

        let frame = av_frame_alloc()
        let frameRGBA = av_frame_alloc()
        let packet = av_packet_alloc()
        defer {
            var f = frame
            var frgba = frameRGBA
            var p = packet
            av_frame_free(&f)
            av_frame_free(&frgba)
            av_packet_free(&p)
        }

        guard let frame, let frameRGBA, let packet else { return [] }

        let rgbaBufferSize = av_image_get_buffer_size(AV_PIX_FMT_RGBA, thumbWidth, thumbHeight, 1)
        guard rgbaBufferSize > 0, let rgbaBuffer = av_malloc(Int(rgbaBufferSize)) else { return [] }
        defer {
            av_free(rgbaBuffer)
        }

        ret = av_image_fill_arrays(
            &frameRGBA.pointee.data.0,
            &frameRGBA.pointee.linesize.0,
            UnsafePointer<UInt8>(OpaquePointer(rgbaBuffer)),
            AV_PIX_FMT_RGBA,
            thumbWidth,
            thumbHeight,
            1
        )
        guard ret >= 0 else { return [] }

        // Generate sample points
        let count = min(Self.defaultThumbnailCount, max(10, Int(durationSeconds / 2.0)))
        let interval = durationSeconds / Double(count)

        var allThumbnails: [ThumbnailItem] = []
        var batchThumbnails: [ThumbnailItem] = []
        var lastEmittedTime = CACurrentMediaTime()
        var addedTimestamps = Set<Int64>()

        for i in 0..<count {
            guard !isCancelled else { break }

            let targetTime = Double(i) * interval
            let targetPts = Int64(round(targetTime * Double(timebase.den) / Double(timebase.num)))

            avcodec_flush_buffers(codecCtx)

            // Seek backward to keyframe (try stream-level seek first, then format-level)
            var seekRet = av_seek_frame(activeFormatCtx, streamIndex, targetPts, AVSEEK_FLAG_BACKWARD)
            if seekRet < 0 {
                let targetPtsAV = Int64(round(targetTime * Double(AV_TIME_BASE)))
                seekRet = av_seek_frame(activeFormatCtx, -1, targetPtsAV, AVSEEK_FLAG_BACKWARD)
            }
            avcodec_flush_buffers(codecCtx)

            // Decode frames until we get one
            var decodedThumbnail: ThumbnailItem? = nil
            var videoPacketsRead = 0
            var totalPacketsRead = 0

            while av_read_frame(activeFormatCtx, packet) >= 0 && videoPacketsRead < 30 && totalPacketsRead < 300 {
                defer { av_packet_unref(packet) }
                totalPacketsRead += 1

                guard !isCancelled else { break }

                if packet.pointee.stream_index == streamIndex {
                    videoPacketsRead += 1
                    if avcodec_send_packet(codecCtx, packet) < 0 {
                        break
                    }

                    while avcodec_receive_frame(codecCtx, frame) == 0 {
                        let pts =
                            frame.pointee.best_effort_timestamp != Int64.min
                            ? frame.pointee.best_effort_timestamp
                            : frame.pointee.pts

                        if !addedTimestamps.contains(pts) {
                            addedTimestamps.insert(pts)

                            let actualFrameWidth = frame.pointee.width > 0 ? frame.pointee.width : videoWidth
                            let actualFrameHeight = frame.pointee.height > 0 ? frame.pointee.height : videoHeight
                            let frameFmt = AVPixelFormat(frame.pointee.format)
                            if swsCtx == nil || frameFmt != sourcePixFmt {
                                if let oldCtx = swsCtx {
                                    sws_freeContext(oldCtx)
                                }
                                sourcePixFmt = frameFmt
                                swsCtx = sws_getContext(
                                    actualFrameWidth,
                                    actualFrameHeight,
                                    frameFmt,
                                    thumbWidth,
                                    thumbHeight,
                                    AV_PIX_FMT_RGBA,
                                    Int32(SWS_BILINEAR.rawValue),
                                    nil,
                                    nil,
                                    nil
                                )
                                if let activeSwsCtx = swsCtx {
                                    Self.configureSwsColorspace(swsCtx: activeSwsCtx, frame: frame, codecpar: codecpar)
                                }
                            }

                            if let activeSwsCtx = swsCtx {
                                // Convert frame to RGBA
                                let scaleRet = withUnsafePointer(to: &frame.pointee.data) { frameDataPtr in
                                    withUnsafePointer(to: &frame.pointee.linesize) { frameLinesizePtr in
                                        withUnsafeMutablePointer(to: &frameRGBA.pointee.data) { rgbaDataPtr in
                                            withUnsafeMutablePointer(to: &frameRGBA.pointee.linesize) {
                                                rgbaLinesizePtr in
                                                let inData = OpaquePointer(frameDataPtr)
                                                let inLinesize = OpaquePointer(frameLinesizePtr)
                                                let outData = OpaquePointer(rgbaDataPtr)
                                                let outLinesize = OpaquePointer(rgbaLinesizePtr)

                                                return sws_scale(
                                                    activeSwsCtx,
                                                    UnsafePointer<UnsafePointer<UInt8>?>(inData),
                                                    UnsafePointer<Int32>(inLinesize),
                                                    0,
                                                    actualFrameHeight,
                                                    UnsafePointer<UnsafeMutablePointer<UInt8>?>(outData),
                                                    UnsafePointer<Int32>(outLinesize)
                                                )
                                            }
                                        }
                                    }
                                }

                                if scaleRet > 0 {
                                    let actualSeconds =
                                        pts != Int64.min && pts >= 0
                                        ? Double(pts) * Double(timebase.num) / Double(timebase.den)
                                        : targetTime

                                    let colorInfo = Self.extractColorInfo(frame: frame, codecpar: codecpar)
                                    if let cgImage = Self.createCGImage(
                                        fromRGBA: frameRGBA.pointee.data.0!,
                                        width: Int(thumbWidth),
                                        height: Int(thumbHeight),
                                        bytesPerRow: Int(frameRGBA.pointee.linesize.0),
                                        colorInfo: colorInfo
                                    ) {
                                        decodedThumbnail = ThumbnailItem(
                                            time: actualSeconds,
                                            image: cgImage,
                                            width: Int(thumbWidth),
                                            height: Int(thumbHeight)
                                        )
                                    }
                                }
                            }
                        }

                        if decodedThumbnail != nil {
                            break
                        }
                    }

                    if decodedThumbnail != nil {
                        break
                    }
                }
            }

            if let item = decodedThumbnail {
                allThumbnails.append(item)
                batchThumbnails.append(item)
            }

            let now = CACurrentMediaTime()
            if (now - lastEmittedTime >= 0.25 || batchThumbnails.count >= 8) && !batchThumbnails.isEmpty {
                onProgress(allThumbnails)
                batchThumbnails.removeAll(keepingCapacity: true)
                lastEmittedTime = now
            }
        }

        // Fallback: If seeking produced 0 thumbnails, decode the first frame linearly from start
        if allThumbnails.isEmpty && !isCancelled {
            _ = av_seek_frame(activeFormatCtx, -1, 0, AVSEEK_FLAG_BACKWARD)
            avcodec_flush_buffers(codecCtx)
            var totalPacketsRead = 0
            while av_read_frame(activeFormatCtx, packet) >= 0 && totalPacketsRead < 300 {
                defer { av_packet_unref(packet) }
                totalPacketsRead += 1
                if packet.pointee.stream_index == streamIndex {
                    if avcodec_send_packet(codecCtx, packet) >= 0 {
                        if avcodec_receive_frame(codecCtx, frame) == 0 {
                            let actualFrameWidth = frame.pointee.width > 0 ? frame.pointee.width : videoWidth
                            let actualFrameHeight = frame.pointee.height > 0 ? frame.pointee.height : videoHeight
                            let frameFmt = AVPixelFormat(frame.pointee.format)
                            if swsCtx == nil || frameFmt != sourcePixFmt {
                                if let oldCtx = swsCtx { sws_freeContext(oldCtx) }
                                sourcePixFmt = frameFmt
                                swsCtx = sws_getContext(
                                    actualFrameWidth, actualFrameHeight, frameFmt, thumbWidth, thumbHeight,
                                    AV_PIX_FMT_RGBA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
                                if let activeSwsCtx = swsCtx {
                                    Self.configureSwsColorspace(swsCtx: activeSwsCtx, frame: frame, codecpar: codecpar)
                                }
                            }
                            if let activeSwsCtx = swsCtx {
                                let scaleRet = withUnsafePointer(to: &frame.pointee.data) { frameDataPtr in
                                    withUnsafePointer(to: &frame.pointee.linesize) { frameLinesizePtr in
                                        withUnsafeMutablePointer(to: &frameRGBA.pointee.data) { rgbaDataPtr in
                                            withUnsafeMutablePointer(to: &frameRGBA.pointee.linesize) {
                                                rgbaLinesizePtr in
                                                let inData = OpaquePointer(frameDataPtr)
                                                let inLinesize = OpaquePointer(frameLinesizePtr)
                                                let outData = OpaquePointer(rgbaDataPtr)
                                                let outLinesize = OpaquePointer(rgbaLinesizePtr)
                                                return sws_scale(
                                                    activeSwsCtx, UnsafePointer<UnsafePointer<UInt8>?>(inData),
                                                    UnsafePointer<Int32>(inLinesize), 0, actualFrameHeight,
                                                    UnsafePointer<UnsafeMutablePointer<UInt8>?>(outData),
                                                    UnsafePointer<Int32>(outLinesize))
                                            }
                                        }
                                    }
                                }
                                if scaleRet > 0 {
                                    let colorInfo = Self.extractColorInfo(frame: frame, codecpar: codecpar)
                                    if let cgImage = Self.createCGImage(
                                        fromRGBA: frameRGBA.pointee.data.0!,
                                        width: Int(thumbWidth),
                                        height: Int(thumbHeight),
                                        bytesPerRow: Int(frameRGBA.pointee.linesize.0),
                                        colorInfo: colorInfo
                                    ) {
                                        allThumbnails.append(
                                            ThumbnailItem(
                                                time: 0, image: cgImage, width: Int(thumbWidth),
                                                height: Int(thumbHeight)))
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if !batchThumbnails.isEmpty {
            onProgress(allThumbnails)
        }

        return allThumbnails
    }

    private struct ColorInfo {
        let isHDR: Bool
        let isPQ: Bool
        let isHLG: Bool
        let isBT2020: Bool
    }

    private static func extractColorInfo(
        frame: UnsafeMutablePointer<AVFrame>,
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> ColorInfo {
        let colorTrc =
            frame.pointee.color_trc != AVCOL_TRC_UNSPECIFIED
            ? frame.pointee.color_trc
            : codecpar.pointee.color_trc

        let colorPrimaries =
            frame.pointee.color_primaries != AVCOL_PRI_UNSPECIFIED
            ? frame.pointee.color_primaries
            : codecpar.pointee.color_primaries

        let colorSpace =
            frame.pointee.colorspace != AVCOL_SPC_UNSPECIFIED
            ? frame.pointee.colorspace
            : codecpar.pointee.color_space

        let isPQ = (colorTrc == AVCOL_TRC_SMPTE2084)
        let isHLG = (colorTrc == AVCOL_TRC_ARIB_STD_B67)
        let isBT2020 =
            (colorPrimaries == AVCOL_PRI_BT2020 || colorSpace == AVCOL_SPC_BT2020_NCL
                || colorSpace == AVCOL_SPC_BT2020_CL)
        let isHDR = isPQ || isHLG || isBT2020

        return ColorInfo(isHDR: isHDR, isPQ: isPQ, isHLG: isHLG, isBT2020: isBT2020)
    }

    private static func configureSwsColorspace(
        swsCtx: UnsafeMutablePointer<SwsContext>,
        frame: UnsafeMutablePointer<AVFrame>?,
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) {
        let colorSpace: AVColorSpace = {
            if let f = frame, f.pointee.colorspace != AVCOL_SPC_UNSPECIFIED {
                return f.pointee.colorspace
            }
            return codecpar.pointee.color_space
        }()

        let colorPrimaries: AVColorPrimaries = {
            if let f = frame, f.pointee.color_primaries != AVCOL_PRI_UNSPECIFIED {
                return f.pointee.color_primaries
            }
            return codecpar.pointee.color_primaries
        }()

        let isBT2020 =
            (colorSpace == AVCOL_SPC_BT2020_NCL || colorSpace == AVCOL_SPC_BT2020_CL
                || colorPrimaries == AVCOL_PRI_BT2020)

        let invTable =
            isBT2020
            ? sws_getCoefficients(SWS_CS_BT2020)
            : (colorSpace == AVCOL_SPC_BT709 ? sws_getCoefficients(SWS_CS_ITU709) : sws_getCoefficients(SWS_CS_DEFAULT))

        let colorRange: AVColorRange = {
            if let f = frame, f.pointee.color_range != AVCOL_RANGE_UNSPECIFIED {
                return f.pointee.color_range
            }
            return codecpar.pointee.color_range
        }()

        let srcRange = (colorRange == AVCOL_RANGE_JPEG) ? Int32(1) : Int32(0)

        _ = sws_setColorspaceDetails(
            swsCtx,
            invTable,
            srcRange,
            sws_getCoefficients(SWS_CS_DEFAULT),
            1,  // output full range RGBA
            0,
            1 << 16,
            1 << 16
        )
    }

    // Precomputed transfer function LUTs (256 entries for fast 8-bit lookup)
    private static let pqToNitsLUT: [Float] = {
        var lut = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let v = Float(i) / 255.0
            let p = pow(max(v, 0.0), 32.0 / 2523.0)
            let ratio = max(p - (3424.0 / 4096.0), 0.0) / max((2413.0 / 128.0) - (2392.0 / 128.0) * p, 1e-6)
            lut[i] = 10000.0 * pow(ratio, 16384.0 / 2610.0)
        }
        return lut
    }()

    private static let hlgToNitsLUT: [Float] = {
        var lut = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let v = Float(i) / 255.0
            let e: Float
            if v <= 0.5 {
                e = (v * v) / 3.0
            } else {
                e = (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0
            }
            lut[i] = 1000.0 * pow(max(e, 0.0), 1.2)
        }
        return lut
    }()

    /// Tone-maps and gamut-maps RGBA pixels from HDR (BT.2020 PQ/HLG) to SDR Display P3 (Gamma 2.2).
    private static func toneMapHDRBufferInPlace(
        buffer: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        isPQ: Bool
    ) {
        let lut = isPQ ? pqToNitsLUT : hlgToNitsLUT

        for y in 0..<height {
            var rowPtr = buffer.advanced(by: y * bytesPerRow)
            for _ in 0..<width {
                let rByte = Int(rowPtr[0])
                let gByte = Int(rowPtr[1])
                let bByte = Int(rowPtr[2])

                let rLin = lut[rByte]
                let gLin = lut[gByte]
                let bLin = lut[bByte]

                // Matrix: BT.2020 Linear -> Display P3 Linear (D65 white point)
                let rP3 = max(1.343578 * rLin - 0.282180 * gLin - 0.061399 * bLin, 0.0)
                let gP3 = max(-0.065297 * rLin + 1.075788 * gLin - 0.010490 * bLin, 0.0)
                let bP3 = max(0.002822 * rLin - 0.019598 * gLin + 1.016777 * bLin, 0.0)

                let maxP3 = max(rP3, max(gP3, bP3))
                if maxP3 <= 1e-4 {
                    rowPtr[0] = 0
                    rowPtr[1] = 0
                    rowPtr[2] = 0
                    rowPtr += 4
                    continue
                }

                // Reference SDR tone curve (reference white 203.0 nits per ITU-R BT.2408)
                let x = maxP3 / 203.0
                let mappedX: Float
                if x <= 0.6 {
                    mappedX = x
                } else {
                    let diff = x - 0.6
                    mappedX = 0.6 + 0.4 * (diff / (diff + 1.2))
                }

                let scale = (mappedX / x) / 203.0
                let rSDR = min(1.0, max(0.0, rP3 * scale))
                let gSDR = min(1.0, max(0.0, gP3 * scale))
                let bSDR = min(1.0, max(0.0, bP3 * scale))

                // Pure Gamma 2.2 output (matches linearToSDRDisplay in HDRToneMapping.metal)
                rowPtr[0] = UInt8(min(255.0, max(0.0, round(pow(rSDR, 1.0 / 2.2) * 255.0))))
                rowPtr[1] = UInt8(min(255.0, max(0.0, round(pow(gSDR, 1.0 / 2.2) * 255.0))))
                rowPtr[2] = UInt8(min(255.0, max(0.0, round(pow(bSDR, 1.0 / 2.2) * 255.0))))
                rowPtr += 4
            }
        }
    }

    /// Creates a CGImage from 32-bit RGBA pixel data with color space and HDR tone mapping applied.
    private static func createCGImage(
        fromRGBA buffer: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        colorInfo: ColorInfo
    ) -> CGImage? {
        if colorInfo.isPQ || colorInfo.isHLG {
            toneMapHDRBufferInPlace(
                buffer: buffer,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                isPQ: colorInfo.isPQ
            )
        }

        let colorSpace: CGColorSpace = {
            if colorInfo.isHDR {
                return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            } else {
                return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            }
        }()

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let byteCount = bytesPerRow * height
        let data = Data(bytes: buffer, count: byteCount)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
