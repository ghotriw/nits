import Accelerate
import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import NitsKernels
import os

/// High-performance software video decoder powered by FFmpeg libavcodec (including VideoLAN's `libdav1d`).
/// Decodes software bitstreams (AV1, VP9, WMV1-3, VC-1, MPEG-4 Part 2, MS-MPEG4, H.263 and future legacy codecs)
/// and converts planar YUV420P / YUVJ420P / YUV420P10 frames directly into hardware-backed `CVPixelBuffer`s
/// (NV12 / P010) via a pre-allocated `CVPixelBufferPool` with Metal and IOSurface backing.
public final class FFmpegVideoDecoder: VideoDecoderProtocol, @unchecked Sendable {
    private let codecLock = OSAllocatedUnfairLock()
    private let poolLock = OSAllocatedUnfairLock()
    private let outputLock = OSAllocatedUnfairLock()
    private let flushGenerationLock = OSAllocatedUnfairLock(initialState: UInt64(1))

    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private var poolPixelFormat: OSType = 0
    private var outputHandler: OutputHandler?
    private let timebase: AVRational
    /// Converts frames the NV12 / P010 copy can't take (4:2:2, 4:4:4, RGB…) to planar 4:2:0.
    private let frameFormatNormalizer = FrameFormatNormalizer()
    private var loggedNormalizationFailure = false
    private let deinterlacerLock = OSAllocatedUnfairLock()
    private var deinterlaceMode: DeinterlaceMode
    /// Created on the first interlaced frame; `nil` afterwards only if Metal is unavailable.
    private var deinterlacer: MetalDeinterlacer?
    private var didCreateDeinterlacer = false
    /// The last interlaced source frame and where it ends, which tells the next one's static detail from motion.
    /// Cleared on flush; used only when the next frame starts where it ends.
    private var previousInterlacedFrame: (pixelBuffer: CVPixelBuffer, end: CMTime)?

    // Tracking metadata across frame-threading latency and B-frame reordering. Keyed by a packet
    // serial that FFmpeg carries from packet to frame (`AV_CODEC_FLAG_COPY_OPAQUE`), so matching
    // doesn't depend on the container having presentation timestamps.
    private struct PacketMeta: Sendable {
        let duration: CMTime
        let doNotDisplay: Bool
        /// `MediaDemuxer.exactSeekTargetAttachmentKey`: overrides `doNotDisplay` once the frame (and field) PTS is known.
        let exactSeekTarget: Double?
    }
    private var inFlightMetadata: [UInt: PacketMeta] = [:]
    private var nextPacketSerial: UInt = 1
    /// PTS + duration of the last emitted frame, for frames the decoder outputs without a timestamp.
    private var lastFrameEnd: CMTime = .invalid

    // Cached color metadata dictionary to preserve attributes across drain() / EOF
    private var cachedColorAttachments: [CFString: CFTypeRef] = [:]
    /// The format description the decoder last took parameter sets from, and its `avcC` / `hvcC` (behind
    /// `codecLock`): an HLS variant switch brings another.
    private var lastFormatDescription: CMFormatDescription?
    private var configuration: Data?

    /// - Parameters:
    ///   - formatDescription: the samples' format description. H.264 / HEVC samples arrive length-prefixed (the
    ///     demuxer rewrites Annex B for VideoToolbox), so their `avcC` / `hvcC` replaces the container extradata.
    ///   - deinterlaceMode: how frames flagged interlaced are deinterlaced. `.auto` (a frame per field) suits
    ///     streams declared interlaced, whose player then paces at the field rate (`outputsFieldRate`); tests use
    ///     `.off` to compare against the woven frames.
    public init?(
        codecParameters: UnsafePointer<AVCodecParameters>,
        timebase: AVRational,
        formatDescription: CMFormatDescription? = nil,
        deinterlaceMode: DeinterlaceMode = .frameRate
    ) {
        self.timebase = timebase
        self.deinterlaceMode = deinterlaceMode
        let codecId = codecParameters.pointee.codec_id

        let codec: UnsafePointer<AVCodec>? = {
            if codecId == AV_CODEC_ID_AV1 {
                return avcodec_find_decoder_by_name("libdav1d") ?? avcodec_find_decoder(codecId)
            } else if codecId == AV_CODEC_ID_VP9 {
                return avcodec_find_decoder_by_name("libvpx-vp9") ?? avcodec_find_decoder(codecId)
            }
            return avcodec_find_decoder(codecId)
        }()

        guard let codec else {
            AppLog.error(.video, "FFmpeg decoder not found for codec ID \(codecId.rawValue)")
            return nil
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            AppLog.error(.video, "Failed to allocate AVCodecContext for codec ID \(codecId.rawValue)")
            return nil
        }
        self.codecCtx = ctx

        if avcodec_parameters_to_context(ctx, codecParameters) < 0 {
            AppLog.error(.video, "Failed to copy codec parameters to context for codec ID \(codecId.rawValue)")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        ctx.pointee.pkt_timebase = timebase
        if let configuration = Self.lengthPrefixedConfiguration(codecId: codecId, formatDescription: formatDescription)
        {
            Self.replaceExtradata(of: ctx, with: configuration)
            self.configuration = configuration
            self.lastFormatDescription = formatDescription
        }
        ctx.pointee.flags |= Int32(AV_CODEC_FLAG_COPY_OPAQUE)

        // Slice threading only. Frame threading delays output by one frame per thread, while seek previews
        // and frame steps decode only a few packets past the target, so the target frame would never come
        // out. Decoders without slice threads (MPEG-4 Part 2, WMV, H.263) run on one thread.
        let caps = codec.pointee.capabilities
        let threads = Int32(min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 10))
        if (caps & AV_CODEC_CAP_SLICE_THREADS) != 0 {
            ctx.pointee.thread_type = FF_THREAD_SLICE
            ctx.pointee.thread_count = threads
        } else if (caps & AV_CODEC_CAP_OTHER_THREADS) != 0 {
            // libdav1d and libvpx thread on their own, with as many threads as `thread_count` says: 1 left them on
            // one core (4K AV1 decoded and converted at 42 fps against 53, M2 Pro, release build: headroom for
            // heavier content and higher rates). dav1d also decodes frames in parallel, which delays output as frame
            // threading does; one frame in flight keeps its threads inside the frame (tiles, filters).
            ctx.pointee.thread_count = threads
            if let options = ctx.pointee.priv_data {
                av_opt_set_int(options, "max_frame_delay", 1, 0)
            }
        } else {
            ctx.pointee.thread_count = 1
        }

        if avcodec_open2(ctx, codec, nil) < 0 {
            AppLog.error(.video, "Failed to open FFmpeg codec context for codec ID \(codecId.rawValue)")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        self.frame = av_frame_alloc()
        self.packet = av_packet_alloc()

        guard frame != nil && packet != nil else {
            teardown()
            return nil
        }

        let codecName = String(cString: codec.pointee.name)
        AppLog.info(
            .video,
            "FFmpegVideoDecoder initialized successfully (\(codecName)) with \(ctx.pointee.thread_count) threads.")
    }

    /// The `avcC` / `hvcC` record of an H.264 / HEVC format description: it tells FFmpeg its packets are
    /// length-prefixed (as `MediaDemuxer` delivers them) rather than Annex B.
    private static func lengthPrefixedConfiguration(
        codecId: AVCodecID, formatDescription: CMFormatDescription?
    ) -> Data? {
        let atomKey: String
        switch codecId {
        case AV_CODEC_ID_H264: atomKey = "avcC"
        case AV_CODEC_ID_HEVC: atomKey = "hvcC"
        default: return nil
        }
        guard let formatDescription,
            let atoms = CMFormatDescriptionGetExtension(
                formatDescription, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                as? [String: Any]
        else { return nil }
        return atoms[atomKey] as? Data
    }

    /// Gives the decoder the parameter sets of a sample whose format description changed (an HLS variant switch):
    /// H.264 and HEVC take a new `avcC` / `hvcC` as `AV_PKT_DATA_NEW_EXTRADATA` side data mid-stream. Variants in
    /// MPEG-TS repeat theirs in band, those in fragmented MP4 have them only there. Behind `codecLock`; the side data
    /// goes with the packet's next unref. Returns what `recordConfiguration` takes once the packet is sent: one the
    /// decoder refuses leaves the parameter sets for the next packet to carry.
    private func attachNewConfiguration(
        of sampleBuffer: CMSampleBuffer, to pkt: UnsafeMutablePointer<AVPacket>, codecId: AVCodecID
    ) -> (description: CMFormatDescription, configuration: Data?)? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer), description !== lastFormatDescription
        else { return nil }
        guard let new = Self.lengthPrefixedConfiguration(codecId: codecId, formatDescription: description),
            new != configuration, let side = av_packet_new_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, new.count)
        else { return (description, nil) }
        new.copyBytes(to: side, count: new.count)
        return (description, new)
    }

    /// Behind `codecLock`.
    private func recordConfiguration(_ attached: (description: CMFormatDescription, configuration: Data?)?) {
        guard let attached else { return }
        lastFormatDescription = attached.description
        if let new = attached.configuration { configuration = new }
    }

    private static func replaceExtradata(of ctx: UnsafeMutablePointer<AVCodecContext>, with data: Data) {
        av_freep(&ctx.pointee.extradata)
        guard let buffer = av_mallocz(data.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else {
            ctx.pointee.extradata_size = 0
            return
        }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        ctx.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
        ctx.pointee.extradata_size = Int32(data.count)
    }

    public var outputsFieldRate: Bool { deinterlacerLock.withLock { deinterlaceMode == .auto } }

    public func setDeinterlaceMode(_ mode: DeinterlaceMode) {
        deinterlacerLock.withLock { deinterlaceMode = mode }
    }

    public func setOutputHandler(_ handler: @escaping OutputHandler) {
        outputLock.lock()
        outputHandler = handler
        outputLock.unlock()
    }

    /// RAII container ensuring the underlying FFmpeg `AVFrame` is freed upon deallocation.
    private final class ManagedAVFrame: @unchecked Sendable {
        private var pointer: UnsafeMutablePointer<AVFrame>?

        var rawPointer: UnsafeMutablePointer<AVFrame>? {
            pointer
        }

        init?(borrowingFrom source: UnsafeMutablePointer<AVFrame>) {
            guard let allocated = av_frame_alloc() else {
                AppLog.error(.video, "FFmpegVideoDecoder: Failed to allocate AVFrame for decoupled processing")
                return nil
            }
            av_frame_move_ref(allocated, source)
            self.pointer = allocated
        }

        func free() {
            if pointer != nil {
                av_frame_free(&pointer)
            }
        }

        deinit {
            free()
        }
    }

    private struct RawReceivedFrame {
        let managedFrame: ManagedAVFrame
        let pts: CMTime
        let duration: CMTime
        let doNotDisplay: Bool
        let exactSeekTarget: Double?
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

        // Cache incoming color metadata outside codecLock without holding any locks simultaneously
        updateCachedColorMetadata(from: sampleBuffer)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        var doNotDisplay = false
        var ptsUnknown = false
        var exactSeekTarget: Double?
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [NSDictionary],
            let first = attachments.first
        {
            doNotDisplay = first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool ?? false
            ptsUnknown = first[MediaDemuxer.presentationTimeUnknownAttachmentKey] as? Bool ?? false
            exactSeekTarget = first[MediaDemuxer.exactSeekTargetAttachmentKey] as? Double
        }

        var receivedFrames: [RawReceivedFrame] = []
        var currentGen: UInt64 = 0

        codecLock.lock()
        guard let ctx = self.codecCtx, let frame = self.frame, let pkt = self.packet else {
            codecLock.unlock()
            return
        }
        currentGen = self.flushGenerationLock.withLock { $0 }

        // Convert CMTime (value * timebase.num) into FFmpeg stream units (pts.value / timebase.num)
        let num64 = Int64(max(timebase.num, 1))
        let ffmpegPts = pts.isValid && !ptsUnknown ? (pts.value / num64) : Int64.min
        let ffmpegDts = dts.isValid ? (dts.value / num64) : (ffmpegPts != Int64.min ? ffmpegPts : Int64.min)
        let ffmpegDuration = duration.isValid ? (duration.value / num64) : 0

        let serial = nextPacketSerial
        nextPacketSerial &+= 1
        inFlightMetadata[serial] = PacketMeta(
            duration: duration, doNotDisplay: doNotDisplay, exactSeekTarget: exactSeekTarget)
        // Packets that never produce a frame (dropped, skip_frame) leave entries behind: keep the newest.
        if inFlightMetadata.count > 120 {
            for k in inFlightMetadata.keys.sorted().prefix(inFlightMetadata.count - 60) {
                inFlightMetadata.removeValue(forKey: k)
            }
        }

        av_packet_unref(pkt)
        let attached = attachNewConfiguration(of: sampleBuffer, to: pkt, codecId: ctx.pointee.codec_id)
        // Note: pkt.pointee.data points to CMBlockBuffer memory, valid synchronously for avcodec_send_packet
        pkt.pointee.data = UnsafeMutablePointer<UInt8>(OpaquePointer(dataPtr))
        pkt.pointee.size = Int32(totalLength)
        pkt.pointee.opaque = UnsafeMutableRawPointer(bitPattern: serial)
        if ffmpegPts != Int64.min {
            pkt.pointee.pts = ffmpegPts
        }
        if ffmpegDts != Int64.min {
            pkt.pointee.dts = ffmpegDts
        }
        if ffmpegDuration > 0 {
            pkt.pointee.duration = ffmpegDuration
        }

        let sendRet = avcodec_send_packet(ctx, pkt)
        // Immediately detach borrowed CMBlockBuffer pointer to prevent dangling references in pkt
        pkt.pointee.data = nil
        pkt.pointee.size = 0
        pkt.pointee.pts = Int64.min
        pkt.pointee.dts = Int64.min
        pkt.pointee.opaque = nil

        if sendRet < 0 {
            codecLock.unlock()
            AppLog.error(.video, "FFmpegVideoDecoder: avcodec_send_packet failed with code \(sendRet)")
            return
        }
        recordConfiguration(attached)

        while true {
            let recvRet = avcodec_receive_frame(ctx, frame)
            if recvRet == 0 {
                if let managed = ManagedAVFrame(borrowingFrom: frame), let rawPtr = managed.rawPointer {
                    let timing = extractTimingAndMetadata(from: rawPtr)
                    receivedFrames.append(
                        RawReceivedFrame(
                            managedFrame: managed,
                            pts: timing.pts,
                            duration: timing.duration,
                            doNotDisplay: timing.doNotDisplay,
                            exactSeekTarget: timing.exactSeekTarget
                        )
                    )
                } else {
                    av_frame_unref(frame)
                }
            } else {
                break
            }
        }
        codecLock.unlock()

        convertAndDeliver(receivedFrames: &receivedFrames, generation: currentGen)
    }

    public func flush() {
        flushGenerationLock.withLock { $0 &+= 1 }
        deinterlacerLock.withLock { previousInterlacedFrame = nil }
        codecLock.lock()
        defer { codecLock.unlock() }
        inFlightMetadata.removeAll(keepingCapacity: true)
        lastFrameEnd = .invalid
        if let ctx = codecCtx {
            avcodec_flush_buffers(ctx)
        }
    }

    public func waitForPendingFrames() {
        // Synchronous send/receive with lock; in-flight frames are processed immediately.
    }

    public func drain() {
        var receivedFrames: [RawReceivedFrame] = []
        var currentGen: UInt64 = 0

        codecLock.lock()
        guard let ctx = self.codecCtx, let frame = self.frame else {
            codecLock.unlock()
            return
        }
        currentGen = self.flushGenerationLock.withLock { $0 }

        // Send NULL packet to enter draining mode
        _ = avcodec_send_packet(ctx, nil)

        while true {
            let ret = avcodec_receive_frame(ctx, frame)
            if ret == 0 {
                if let managed = ManagedAVFrame(borrowingFrom: frame), let rawPtr = managed.rawPointer {
                    let timing = extractTimingAndMetadata(from: rawPtr)
                    receivedFrames.append(
                        RawReceivedFrame(
                            managedFrame: managed,
                            pts: timing.pts,
                            duration: timing.duration,
                            doNotDisplay: timing.doNotDisplay,
                            exactSeekTarget: timing.exactSeekTarget
                        )
                    )
                } else {
                    av_frame_unref(frame)
                }
            } else {
                break
            }
        }
        codecLock.unlock()

        convertAndDeliver(receivedFrames: &receivedFrames, generation: currentGen)
    }

    public func resetSession() {
        flushGenerationLock.withLock { $0 &+= 1 }
        deinterlacerLock.withLock { previousInterlacedFrame = nil }
        codecLock.lock()
        inFlightMetadata.removeAll()
        lastFrameEnd = .invalid
        if let ctx = codecCtx {
            avcodec_flush_buffers(ctx)
        }
        codecLock.unlock()

        poolLock.lock()
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
        poolPixelFormat = 0
        cachedColorAttachments.removeAll()
        poolLock.unlock()
    }

    public func setDiscardNonReferenceFrames(_ discard: Bool) {
        codecLock.lock()
        defer { codecLock.unlock() }
        guard let ctx = codecCtx else { return }
        if discard {
            ctx.pointee.skip_frame = AVDISCARD_NONREF
        } else {
            ctx.pointee.skip_frame = AVDISCARD_DEFAULT
        }
    }

    private func convertAndDeliver(receivedFrames: inout [RawReceivedFrame], generation: UInt64) {
        guard !receivedFrames.isEmpty else { return }

        // Fast-path: if generation is already stale before heavy processing begins, discard all frames immediately
        if isFlushStale(generation: generation) {
            while !receivedFrames.isEmpty {
                receivedFrames.removeFirst().managedFrame.free()
            }
            return
        }

        var decodedFrames: [DecodedFrame] = []
        decodedFrames.reserveCapacity(receivedFrames.count)

        // Process frames in-place and clear references promptly to ensure prompt deallocation
        while !receivedFrames.isEmpty {
            let raw = receivedFrames.removeFirst()
            if isFlushStale(generation: generation) {
                raw.managedFrame.free()
                continue
            }

            if let rawPtr = raw.managedFrame.rawPointer, let pixelBuffer = convertAVFrameToPixelBuffer(rawPtr) {
                decodedFrames += progressiveFrames(of: raw, pixelBuffer: pixelBuffer, generation: generation)
            }
            raw.managedFrame.free()
        }

        if !decodedFrames.isEmpty && !isFlushStale(generation: generation) {
            outputLock.lock()
            let handler = self.outputHandler
            outputLock.unlock()

            if let handler {
                for f in decodedFrames {
                    // Check generation before each delivered frame to close any race with a concurrent seek/flush()
                    guard !isFlushStale(generation: generation) else { break }
                    handler(f)
                }
            }
        }
    }

    private func isFlushStale(generation: UInt64) -> Bool {
        flushGenerationLock.withLock { $0 != generation }
    }

    // MARK: - Internal Conversion & Frame Construction

    private func extractTimingAndMetadata(from avFrame: UnsafeMutablePointer<AVFrame>) -> (
        pts: CMTime, duration: CMTime, doNotDisplay: Bool, exactSeekTarget: Double?
    ) {
        var rawPts = avFrame.pointee.best_effort_timestamp
        if rawPts == Int64.min || rawPts < 0 {
            rawPts = avFrame.pointee.pts
        }
        if rawPts == Int64.min || rawPts < 0 {
            rawPts = avFrame.pointee.pkt_dts
        }
        var framePts: CMTime
        if rawPts != Int64.min && rawPts >= 0 && timebase.den > 0 {
            framePts = CMTime(value: rawPts * Int64(timebase.num), timescale: timebase.den)
        } else {
            framePts = .invalid
        }

        var frameDuration: CMTime = .invalid
        var frameDoNotDisplay: Bool = false
        var exactSeekTarget: Double?

        let serial = UInt(bitPattern: avFrame.pointee.opaque)
        if let found = serial != 0 ? inFlightMetadata.removeValue(forKey: serial) : nil {
            frameDuration = found.duration
            frameDoNotDisplay = found.doNotDisplay
            exactSeekTarget = found.exactSeekTarget
            if let target = found.exactSeekTarget, framePts.isValid {
                frameDoNotDisplay = framePts.seconds < target
            }
        } else if avFrame.pointee.duration > 0 && timebase.den > 0 {
            frameDuration = CMTime(value: avFrame.pointee.duration * Int64(timebase.num), timescale: timebase.den)
        }

        // Without container PTS (AVI) the last reordered frame flushed at EOF carries no timestamp
        // at all: it follows the previous one.
        if !framePts.isValid, lastFrameEnd.isValid {
            framePts = lastFrameEnd
        }
        if framePts.isValid {
            lastFrameEnd = frameDuration.isValid ? framePts + frameDuration : .invalid
        }

        return (framePts, frameDuration, frameDoNotDisplay, exactSeekTarget)
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
        if let oldPool = self.pixelBufferPool {
            CVPixelBufferPoolFlush(oldPool, .excessBuffers)
        }
        self.pixelBufferPool = pool
        self.poolWidth = width
        self.poolHeight = height
        self.poolPixelFormat = pixelFormat
        return pool
    }

    /// The frames to deliver for a decoded frame. Progressive frames, and all frames when Metal is unavailable,
    /// pass through. An interlaced frame (`AV_FRAME_FLAG_INTERLACED`) becomes, in `.auto` mode, a progressive
    /// frame per field, the second one presenting a field later, or one frame for the whole interlaced frame when
    /// both fields show the same moment; in `.frameRate` mode (or without a usable timestamp and duration to place
    /// the second field) a single frame keeping the first field.
    private func progressiveFrames(
        of raw: RawReceivedFrame, pixelBuffer: CVPixelBuffer, generation: UInt64
    ) -> [DecodedFrame] {
        let passThrough = [
            DecodedFrame(
                pixelBuffer: pixelBuffer, pts: raw.pts, duration: raw.duration, doNotDisplay: raw.doNotDisplay,
                generation: generation)
        ]
        guard let frame = raw.managedFrame.rawPointer, (frame.pointee.flags & AV_FRAME_FLAG_INTERLACED) != 0 else {
            return passThrough
        }
        deinterlacerLock.lock()
        let mode = deinterlaceMode
        if mode != .off && !didCreateDeinterlacer {
            didCreateDeinterlacer = true
            deinterlacer = MetalDeinterlacer()
            AppLog.info(.video, "FFmpegVideoDecoder: interlaced frames, deinterlacing on the GPU (\(mode.rawValue))")
        }
        let deinterlacer = self.deinterlacer
        // A non-positive duration is as unusable as a missing one.
        let hasDuration = raw.duration.isNumeric && raw.duration.value > 0
        // The previous frame only counts if this one follows it directly (not after a seek or skipped frames).
        let previous = previousInterlacedFrame.flatMap { previous -> CVPixelBuffer? in
            guard previous.end.isValid, raw.pts.isValid else { return nil }
            let tolerance = hasDuration ? raw.duration.seconds / 4 : 0.010
            return abs((raw.pts - previous.end).seconds) <= tolerance ? previous.pixelBuffer : nil
        }
        previousInterlacedFrame = (pixelBuffer, raw.pts.isValid && hasDuration ? raw.pts + raw.duration : .invalid)
        deinterlacerLock.unlock()
        guard mode != .off, let deinterlacer else { return passThrough }

        let topFieldFirst = (frame.pointee.flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != 0
        let fields: [MetalDeinterlacer.Field] = topFieldFirst ? [.top, .bottom] : [.bottom, .top]
        let durations =
            mode == .auto && raw.pts.isValid
            ? FieldTiming.durations(ofFrame: raw.duration, repeatedFields: Int(frame.pointee.repeat_pict)) : nil

        guard let durations else {
            guard
                let first = deinterlacer.deinterlace(pixelBuffer, previous: previous, keeping: [fields[0]])?.frames
                    .first
            else { return passThrough }
            return [
                DecodedFrame(
                    pixelBuffer: first, pts: raw.pts, duration: raw.duration, doNotDisplay: raw.doNotDisplay,
                    generation: generation)
            ]
        }
        guard let output = deinterlacer.deinterlace(pixelBuffer, previous: previous, keeping: fields),
            output.frames.count == 2
        else { return passThrough }
        let secondPts = raw.pts + durations.first
        // An exact seek may land between the fields: the second one shows even when the first is before the target.
        let secondDoNotDisplay = raw.exactSeekTarget.map { secondPts.seconds < $0 } ?? raw.doNotDisplay
        guard output.fieldsDiffer else {
            // Both fields show one moment: a frame per field would repeat it, and frame steps would stall on the
            // repeat. One frame covers both fields, shown while either of them would have been.
            return [
                DecodedFrame(
                    pixelBuffer: output.frames[0], pts: raw.pts, duration: raw.duration,
                    doNotDisplay: secondDoNotDisplay, generation: generation)
            ]
        }
        return [
            DecodedFrame(
                pixelBuffer: output.frames[0], pts: raw.pts, duration: durations.first,
                doNotDisplay: raw.doNotDisplay, generation: generation),
            DecodedFrame(
                pixelBuffer: output.frames[1], pts: secondPts, duration: durations.second,
                doNotDisplay: secondDoNotDisplay, generation: generation),
        ]
    }

    private func convertAVFrameToPixelBuffer(
        _ avFrame: UnsafeMutablePointer<AVFrame>
    ) -> CVPixelBuffer? {
        guard !FrameFormatNormalizer.isDirectlySupported(avFrame.pointee.format) else {
            return copyPlanar420(avFrame)
        }
        guard let normalized = frameFormatNormalizer.convert(avFrame) else {
            if !loggedNormalizationFailure {
                loggedNormalizationFailure = true
                let name = av_get_pix_fmt_name(AVPixelFormat(rawValue: avFrame.pointee.format)).map {
                    String(cString: $0)
                }
                AppLog.error(
                    .video, "FFmpegVideoDecoder: cannot convert pixel format \(name ?? "\(avFrame.pointee.format)")")
            }
            return nil
        }
        var normalizedFrame: UnsafeMutablePointer<AVFrame>? = normalized.frame
        defer { av_frame_free(&normalizedFrame) }
        let pixelBuffer = copyPlanar420(normalized.frame)
        if let pixelBuffer, let matrix = normalized.yCbCrMatrix {
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
        return pixelBuffer
    }

    /// Copies a planar 4:2:0 frame (see `FrameFormatNormalizer.isDirectlySupported`) into an NV12 / P010 buffer.
    private func copyPlanar420(_ avFrame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(avFrame.pointee.width)
        let height = Int(avFrame.pointee.height)
        guard width > 0 && height > 0 else { return nil }

        let format = avFrame.pointee.format

        // Both AVCOL_RANGE_JPEG and AV_PIX_FMT_YUVJ420P represent full range color
        let isFullRange = (avFrame.pointee.color_range == AVCOL_RANGE_JPEG) || (format == AV_PIX_FMT_YUVJ420P.rawValue)
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

        var pixelBufferOut: CVPixelBuffer?
        let auxAttributes =
            [
                kCVPixelBufferPoolAllocationThresholdKey as String: 64
            ] as CFDictionary

        poolLock.lock()
        guard let pool = getOrCreatePool(width: width, height: height, pixelFormat: pixelFormat) else {
            poolLock.unlock()
            return nil
        }

        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxAttributes,
            &pixelBufferOut
        )
        poolLock.unlock()

        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let yDest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
            let uvDest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            return nil
        }

        let destYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let destUVStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        guard
            let ySrc = avFrame.pointee.data.0,
            let uSrc = avFrame.pointee.data.1,
            let vSrc = avFrame.pointee.data.2
        else {
            return nil
        }

        let srcYStride = Int(avFrame.pointee.linesize.0)
        let srcUStride = Int(avFrame.pointee.linesize.1)
        let srcVStride = Int(avFrame.pointee.linesize.2)

        let halfH = (height + 1) / 2
        let halfW = (width + 1) / 2

        // Conversion strategy (measured, 1920x1080 yuv420p10le -> P010 into an IOSurface-backed CVPixelBuffer):
        //   - This hand-written SIMD path: ~0.13 ms/frame in release. Bit-exact vs libswscale.
        //   - libswscale (sws_scale yuv420p10le->p010le): ~1.0 ms/frame — ~8x slower, so NOT adopted
        //     (and GPU/shader conversion like mpv/VLC is rejected: it would bypass the P010 ->
        //     AVSampleBufferDisplayLayer path that gives HDR/XDR passthrough + Dolby Vision).
        //   - A plain scalar loop: ~5x slower than this SIMD under -Onone (debug). So SIMD stays.
        // The SIMD loops live in NitsKernels, built with -O in Debug too (see `BiPlanarConversion`).
        if is10Bit {
            BiPlanarConversion.shift10BitPlane(
                from: ySrc, stride: srcYStride, to: yDest, stride: destYStride, width: width, height: height)
            BiPlanarConversion.interleave10BitChroma(
                u: uSrc, uStride: srcUStride, v: vSrc, vStride: srcVStride,
                to: uvDest, stride: destUVStride, width: halfW, height: halfH)
        } else {
            // 8-bit Y plane: direct row-by-row memory copy
            for row in 0..<height {
                let srcRow = ySrc.advanced(by: row * srcYStride)
                let dstRow = yDest.advanced(by: row * destYStride)
                memcpy(dstRow, srcRow, width)
            }
            BiPlanarConversion.interleave8BitChroma(
                u: uSrc, uStride: srcUStride, v: vSrc, vStride: srcVStride,
                to: uvDest, stride: destUVStride, width: halfW, height: halfH)
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

        poolLock.lock()
        cacheAttachment(key: kCVImageBufferColorPrimariesKey)
        cacheAttachment(key: kCVImageBufferTransferFunctionKey)
        cacheAttachment(key: kCVImageBufferYCbCrMatrixKey)
        cacheAttachment(key: kCVImageBufferPixelAspectRatioKey)
        cacheAttachment(key: kCVImageBufferMasteringDisplayColorVolumeKey)
        cacheAttachment(key: kCVImageBufferContentLightLevelInfoKey)
        poolLock.unlock()
    }

    private func applyColorAttachments(to pixelBuffer: CVPixelBuffer) {
        poolLock.lock()
        let attachments = cachedColorAttachments
        poolLock.unlock()

        for (key, val) in attachments {
            CVBufferSetAttachment(pixelBuffer, key, val, .shouldPropagate)
        }
    }

    private func teardown() {
        flushGenerationLock.withLock { $0 &+= 1 }
        codecLock.lock()
        inFlightMetadata.removeAll()
        lastFrameEnd = .invalid
        if codecCtx != nil {
            avcodec_free_context(&self.codecCtx)
        }
        if frame != nil {
            av_frame_free(&self.frame)
        }
        if packet != nil {
            av_packet_free(&self.packet)
        }
        codecLock.unlock()

        poolLock.lock()
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
        poolPixelFormat = 0
        cachedColorAttachments.removeAll()
        poolLock.unlock()
    }

    deinit {
        outputLock.lock()
        outputHandler = nil
        outputLock.unlock()
        teardown()
    }
}
