import Accelerate
import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import os

/// High-performance AV1 software video decoder powered by VideoLAN's `libdav1d` (via FFmpeg libavcodec).
/// Decodes multi-threaded AV1 bitstreams and converts planar YUV420P / YUV420P10 frames directly into
/// hardware-backed `CVPixelBuffer`s (NV12 / P010) via a pre-allocated `CVPixelBufferPool`.
public final class Dav1dVideoDecoder: VideoDecoderProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private var poolPixelFormat: OSType = 0
    private var outputHandler: OutputHandler?
    private let timebase: AVRational

    // Tracking metadata across frame-threading latency
    private struct PacketMeta: Sendable {
        let duration: CMTime
        let doNotDisplay: Bool
    }
    private var inFlightMetadata: [Int64: PacketMeta] = [:]
    private var flushGeneration: UInt64 = 0

    // Cached color metadata dictionary to preserve attributes across drain() / EOF
    private var cachedColorAttachments: [CFString: CFTypeRef] = [:]

    public init?(codecParameters: UnsafePointer<AVCodecParameters>, timebase: AVRational) {
        self.timebase = timebase
        guard let codec = avcodec_find_decoder_by_name("libdav1d") ?? avcodec_find_decoder(AV_CODEC_ID_AV1) else {
            AppLog.error(.video, "libdav1d / AV1 decoder not found in libavcodec")
            return nil
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            AppLog.error(.video, "Failed to allocate AVCodecContext for dav1d")
            return nil
        }
        self.codecCtx = ctx

        if avcodec_parameters_to_context(ctx, codecParameters) < 0 {
            AppLog.error(.video, "Failed to copy codec parameters to context for dav1d")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        ctx.pointee.pkt_timebase = timebase

        // Multi-threading: dav1d manages internal threading via thread_count
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        ctx.pointee.thread_count = Int32(min(max(cpuCount, 2), 8))

        if avcodec_open2(ctx, codec, nil) < 0 {
            AppLog.error(.video, "Failed to open dav1d codec context")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        self.frame = av_frame_alloc()
        self.packet = av_packet_alloc()

        guard frame != nil && packet != nil else {
            teardown()
            return nil
        }

        AppLog.info(.video, "Dav1dVideoDecoder initialized successfully with \(ctx.pointee.thread_count) threads.")
    }

    public func setOutputHandler(_ handler: @escaping OutputHandler) {
        lock.lock()
        outputHandler = handler
        lock.unlock()
    }

    public func decode(sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>? = nil
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPtr = dataPointer, totalLength > 0 else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        var doNotDisplay = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [NSDictionary],
            let first = attachments.first,
            let val = first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool
        {
            doNotDisplay = val
        }

        var decodedFrames: [DecodedFrame] = []
        var currentGen: UInt64 = 0

        lock.lock()
        guard let ctx = codecCtx, let avFrame = frame, let pkt = packet else {
            lock.unlock()
            return
        }
        currentGen = self.flushGeneration

        // Cache incoming color metadata to ensure trailing drain() frames receive accurate color properties
        updateCachedColorMetadata(from: sampleBuffer)

        // Convert CMTime (value * timebase.num) into FFmpeg stream units (pts.value / timebase.num)
        let num64 = Int64(max(timebase.num, 1))
        let ffmpegPts = pts.isValid ? (pts.value / num64) : Int64.min
        let ffmpegDuration = duration.isValid ? (duration.value / num64) : 0

        // Record in-flight metadata keyed by ffmpegPts
        if ffmpegPts != Int64.min {
            inFlightMetadata[ffmpegPts] = PacketMeta(duration: duration, doNotDisplay: doNotDisplay)
            // Prune map if it exceeds reasonable buffering window
            if inFlightMetadata.count > 120 {
                let sortedKeys = inFlightMetadata.keys.sorted()
                let dropCount = inFlightMetadata.count - 60
                for k in sortedKeys.prefix(dropCount) {
                    inFlightMetadata.removeValue(forKey: k)
                }
            }
        }

        av_packet_unref(pkt)
        // Note: pkt.pointee.data points to CMBlockBuffer memory, valid synchronously for avcodec_send_packet
        pkt.pointee.data = UnsafeMutablePointer<UInt8>(OpaquePointer(dataPtr))
        pkt.pointee.size = Int32(totalLength)
        if ffmpegPts != Int64.min {
            pkt.pointee.pts = ffmpegPts
        }
        if ffmpegDuration > 0 {
            pkt.pointee.duration = ffmpegDuration
        }

        let sendRes = avcodec_send_packet(ctx, pkt)
        pkt.pointee.data = nil
        pkt.pointee.size = 0

        if sendRes < 0 {
            lock.unlock()
            return
        }

        while avcodec_receive_frame(ctx, avFrame) == 0 {
            if let decoded = makeDecodedFrame(from: avFrame, sampleBuffer: sampleBuffer) {
                decodedFrames.append(decoded)
            }
        }
        let handler = outputHandler
        let isStale = (self.flushGeneration != currentGen)
        if !isStale, let handler {
            for f in decodedFrames {
                handler(f)
            }
        }
        lock.unlock()
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        self.flushGeneration &+= 1
        self.inFlightMetadata.removeAll(keepingCapacity: true)
        if let ctx = codecCtx {
            avcodec_flush_buffers(ctx)
        }
    }

    public func drain() {
        var drainedFrames: [DecodedFrame] = []
        var currentGen: UInt64 = 0

        lock.lock()
        guard let ctx = codecCtx, let avFrame = frame else {
            lock.unlock()
            return
        }
        currentGen = self.flushGeneration

        // Signal EOF to flush remaining buffered frames from multi-threaded pipeline
        avcodec_send_packet(ctx, nil)

        while avcodec_receive_frame(ctx, avFrame) == 0 {
            if let decoded = makeDecodedFrame(from: avFrame, sampleBuffer: nil) {
                drainedFrames.append(decoded)
            }
        }
        let handler = outputHandler
        let isStale = (self.flushGeneration != currentGen)
        if !isStale, let handler {
            for f in drainedFrames {
                handler(f)
            }
        }
        lock.unlock()
    }

    public func resetSession() {
        flush()
    }

    private func makeDecodedFrame(
        from avFrame: UnsafeMutablePointer<AVFrame>,
        sampleBuffer: CMSampleBuffer?
    ) -> DecodedFrame? {
        guard let pixelBuffer = convertAVFrameToPixelBuffer(avFrame, sampleBuffer: sampleBuffer) else {
            return nil
        }

        let framePts: CMTime
        let rawPts = avFrame.pointee.pts
        if rawPts != Int64.min && timebase.den > 0 {
            framePts = CMTime(value: rawPts * Int64(timebase.num), timescale: timebase.den)
        } else {
            framePts = .invalid
        }

        var frameDuration: CMTime = .invalid
        var frameDoNotDisplay: Bool = false

        if rawPts != Int64.min, let meta = inFlightMetadata.removeValue(forKey: rawPts) {
            frameDuration = meta.duration
            frameDoNotDisplay = meta.doNotDisplay
        } else if avFrame.pointee.duration > 0 && timebase.den > 0 {
            frameDuration = CMTime(value: avFrame.pointee.duration * Int64(timebase.num), timescale: timebase.den)
        }

        return DecodedFrame(
            pixelBuffer: pixelBuffer,
            pts: framePts,
            duration: frameDuration,
            doNotDisplay: frameDoNotDisplay,
            doviMetadata: nil
        )
    }

    private func getOrCreatePool(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBufferPool? {
        if let pool = self.pixelBufferPool,
            self.poolWidth == width,
            self.poolHeight == height,
            self.poolPixelFormat == pixelFormat
        {
            return pool
        }

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 24,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 1.0,
            kCVPixelBufferPoolAllocationThresholdKey as String: 64,
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &newPool
        )
        guard status == kCVReturnSuccess, let pool = newPool else {
            return nil
        }
        self.pixelBufferPool = pool
        self.poolWidth = width
        self.poolHeight = height
        self.poolPixelFormat = pixelFormat
        return pool
    }

    private func convertAVFrameToPixelBuffer(
        _ avFrame: UnsafeMutablePointer<AVFrame>,
        sampleBuffer: CMSampleBuffer?
    ) -> CVPixelBuffer? {
        let width = Int(avFrame.pointee.width)
        let height = Int(avFrame.pointee.height)
        guard width > 0 && height > 0 else { return nil }

        let format = avFrame.pointee.format
        guard
            format == AV_PIX_FMT_YUV420P.rawValue
                || format == AV_PIX_FMT_YUV420P10LE.rawValue
        else {
            AppLog.error(.video, "Dav1dVideoDecoder: Unsupported AV1 pixel format: \(format)")
            return nil
        }

        let isFullRange = (avFrame.pointee.color_range == AVCOL_RANGE_JPEG)
        let is10Bit = (format == AV_PIX_FMT_YUV420P10LE.rawValue)

        let pixelFormat: OSType
        if is10Bit {
            pixelFormat =
                isFullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            pixelFormat =
                isFullRange
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        guard let pool = getOrCreatePool(width: width, height: height, pixelFormat: pixelFormat) else {
            return nil
        }

        var pixelBufferOut: CVPixelBuffer?
        let auxAttributes =
            [
                kCVPixelBufferPoolAllocationThresholdKey as String: 96
            ] as CFDictionary
        let poolStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxAttributes,
            &pixelBufferOut
        )
        guard poolStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            if poolStatus == kCVReturnWouldExceedAllocationThreshold {
                AppLog.warning(.video, "CVPixelBufferPool allocation threshold reached (96 frames)")
            }
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let destY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
            let destUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            return nil
        }

        let destYBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let destUVBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        guard let srcY = avFrame.pointee.data.0,
            let srcU = avFrame.pointee.data.1,
            let srcV = avFrame.pointee.data.2
        else {
            return nil
        }

        let srcYStride = Int(avFrame.pointee.linesize.0)
        let srcUStride = Int(avFrame.pointee.linesize.1)
        let srcVStride = Int(avFrame.pointee.linesize.2)

        // Strict linesize verification to prevent buffer overruns
        let minBytesY = is10Bit ? (width * 2) : width
        let minBytesChroma = is10Bit ? (((width + 1) / 2) * 2) : ((width + 1) / 2)
        guard srcYStride >= minBytesY && srcUStride >= minBytesChroma && srcVStride >= minBytesChroma else {
            AppLog.error(
                .video,
                "Dav1dVideoDecoder: Invalid linesize from AVFrame: Y=\(srcYStride), U=\(srcUStride), V=\(srcVStride)")
            return nil
        }

        // Odd dimension handling
        let halfH = (height + 1) / 2
        let halfW = (width + 1) / 2

        if is10Bit {
            // AV1 10-bit YUV420P10LE (LSB [9:0]) -> P010 (MSB [15:6] BiPlanar)
            let srcYRaw = UnsafeRawPointer(srcY)
            let srcURaw = UnsafeRawPointer(srcU)
            let srcVRaw = UnsafeRawPointer(srcV)

            let destYRaw = UnsafeMutableRawPointer(destY)
            let destUVRaw = UnsafeMutableRawPointer(destUV)

            // Y Plane: vectorized shift left by 6 bits using safe unaligned SIMD16 loads and stores
            let simdStep = 16
            let vecWidth = (width / simdStep) * simdStep

            for y in 0..<height {
                let sRow = srcYRaw.advanced(by: y * srcYStride)
                let dRow = destYRaw.advanced(by: y * destYBytesPerRow)

                var x = 0
                while x < vecWidth {
                    let byteOffset = x * 2
                    let inVec = sRow.advanced(by: byteOffset).loadUnaligned(as: SIMD16<UInt16>.self)
                    let outVec = inVec &<< 6
                    dRow.advanced(by: byteOffset).storeBytes(of: outVec, as: SIMD16<UInt16>.self)
                    x += simdStep
                }
                while x < width {
                    let val = sRow.advanced(by: x * 2).loadUnaligned(as: UInt16.self)
                    dRow.advanced(by: x * 2).storeBytes(of: val &<< 6, as: UInt16.self)
                    x += 1
                }
            }

            // UV Plane: vectorized shift and interleave of U and V planes
            let uvSimdStep = 8
            let uvVecWidth = (halfW / uvSimdStep) * uvSimdStep

            for y in 0..<halfH {
                let uRow = srcURaw.advanced(by: y * srcUStride)
                let vRow = srcVRaw.advanced(by: y * srcVStride)
                let uvRow = destUVRaw.advanced(by: y * destUVBytesPerRow)

                var x = 0
                while x < uvVecWidth {
                    let uVec = uRow.advanced(by: x * 2).loadUnaligned(as: SIMD8<UInt16>.self) &<< 6
                    let vVec = vRow.advanced(by: x * 2).loadUnaligned(as: SIMD8<UInt16>.self) &<< 6

                    // Zip lower and upper halves into interleaved 16-element vectors
                    let lowInterleaved = SIMD8<UInt16>(
                        uVec[0], vVec[0], uVec[1], vVec[1],
                        uVec[2], vVec[2], uVec[3], vVec[3]
                    )
                    let highInterleaved = SIMD8<UInt16>(
                        uVec[4], vVec[4], uVec[5], vVec[5],
                        uVec[6], vVec[6], uVec[7], vVec[7]
                    )

                    let destByteOffset = x * 4
                    uvRow.advanced(by: destByteOffset).storeBytes(of: lowInterleaved, as: SIMD8<UInt16>.self)
                    uvRow.advanced(by: destByteOffset + 16).storeBytes(of: highInterleaved, as: SIMD8<UInt16>.self)

                    x += uvSimdStep
                }
                while x < halfW {
                    let uVal = uRow.advanced(by: x * 2).loadUnaligned(as: UInt16.self) &<< 6
                    let vVal = vRow.advanced(by: x * 2).loadUnaligned(as: UInt16.self) &<< 6
                    let uvPair = SIMD2<UInt16>(uVal, vVal)
                    uvRow.advanced(by: x * 4).storeBytes(of: uvPair, as: SIMD2<UInt16>.self)
                    x += 1
                }
            }
        } else {
            // AV1 8-bit YUV420P -> NV12 (BiPlanar 8-bit)
            let destY8 = destY.assumingMemoryBound(to: UInt8.self)
            let destUV8 = destUV.assumingMemoryBound(to: UInt8.self)

            // Y Plane: row copy
            for y in 0..<height {
                let sRow = srcY.advanced(by: y * srcYStride)
                let dRow = destY8.advanced(by: y * destYBytesPerRow)
                memcpy(dRow, sRow, width)
            }

            // UV Plane: interleave U and V
            for y in 0..<halfH {
                let uRow = srcU.advanced(by: y * srcUStride)
                let vRow = srcV.advanced(by: y * srcVStride)
                let uvRow = destUV8.advanced(by: y * destUVBytesPerRow)
                for x in 0..<halfW {
                    uvRow[x * 2] = uRow[x]
                    uvRow[x * 2 + 1] = vRow[x]
                }
            }
        }

        // Apply color metadata from cache (populated from sampleBuffer extensions / attachments)
        applyColorAttachments(to: pixelBuffer)

        return pixelBuffer
    }

    private func updateCachedColorMetadata(from sampleBuffer: CMSampleBuffer) {
        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        let extensions = formatDesc.flatMap { CMFormatDescriptionGetExtensions($0) as? [CFString: Any] }

        func cacheAttachment(key: CFString) {
            let val: CFTypeRef? =
                (extensions?[key] as CFTypeRef?)
                ?? CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: nil)
            if let val {
                cachedColorAttachments[key] = val
            }
        }

        cacheAttachment(key: kCVImageBufferColorPrimariesKey)
        cacheAttachment(key: kCVImageBufferTransferFunctionKey)
        cacheAttachment(key: kCVImageBufferYCbCrMatrixKey)
        cacheAttachment(key: kCVImageBufferMasteringDisplayColorVolumeKey)
        cacheAttachment(key: kCVImageBufferContentLightLevelInfoKey)
    }

    private func applyColorAttachments(to pixelBuffer: CVPixelBuffer) {
        for (key, val) in cachedColorAttachments {
            CVBufferSetAttachment(pixelBuffer, key, val, .shouldPropagate)
        }
    }

    private func teardown() {
        if codecCtx != nil {
            avcodec_free_context(&self.codecCtx)
        }
        if frame != nil {
            av_frame_free(&self.frame)
        }
        if packet != nil {
            av_packet_free(&self.packet)
        }
        pixelBufferPool = nil
    }

    deinit {
        outputHandler = nil
        teardown()
    }
}
