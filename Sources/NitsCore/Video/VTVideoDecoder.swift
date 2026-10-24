import CoreMedia
import Foundation
import VideoToolbox
import os

public final class VTVideoDecoder: VideoDecoderProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var session: VTDecompressionSession?
    private var currentFormatDescription: CMFormatDescription?
    private var lastCreationStatus: OSStatus = noErr
    private var _lastDecodeStatus: OSStatus = noErr
    private var _lastCallbackStatus: OSStatus = noErr

    private struct FrameContext: Sendable {
        let doNotDisplay: Bool
        let hdrMetadata: FrameHDRMetadata?
        let pixelAspectRatio: RationalAspectRatio?
    }

    private var nextFrameId: UInt64 = 1
    private var inFlightFrames: [UInt64: FrameContext] = [:]
    private var cachedPixelAspectRatio: RationalAspectRatio?

    public var lastDecodeStatus: OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return _lastDecodeStatus
    }

    public var lastCallbackStatus: OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return _lastCallbackStatus
    }

    /// Frames submitted whose output callback has not run yet.
    public var pendingFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlightFrames.count
    }

    public var hasActiveSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil
    }

    public var sessionStatus: OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return lastCreationStatus
    }

    public typealias DecodedFrame = NitsCore.DecodedFrame

    public typealias OutputHandler = @Sendable (DecodedFrame) -> Void
    private var outputHandler: OutputHandler?

    public init() {}

    public func setOutputHandler(_ handler: @escaping OutputHandler) {
        lock.lock()
        outputHandler = handler
        lock.unlock()
    }

    public func decode(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        lock.lock()
        if let previous = session, currentFormatDescription != formatDesc {
            // Frames of the previous format (an HLS variant switch) come out before its session goes; the output
            // callback takes the lock.
            lock.unlock()
            VTDecompressionSessionWaitForAsynchronousFrames(previous)
            lock.lock()
        }
        if session == nil || currentFormatDescription != formatDesc {
            createSession(formatDescription: formatDesc)
        }
        guard let activeSession = session else {
            lock.unlock()
            return
        }

        // Check if sample has kCMSampleAttachmentKey_DoNotDisplay
        var doNotDisplay = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [NSDictionary],
            let first = attachments.first
        {
            if let val = first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool {
                doNotDisplay = val
            }
        }

        var hdrMetadata: FrameHDRMetadata? = nil
        let metadataKey = MediaDemuxer.hdrMetadataAttachmentKey as CFString
        if let box = CMGetAttachment(sampleBuffer, key: metadataKey, attachmentModeOut: nil) as? FrameHDRMetadataBox {
            hdrMetadata = box.metadata
            CMRemoveAttachment(sampleBuffer, key: metadataKey)
        }

        var parRational: RationalAspectRatio? = nil
        let rawPar =
            CMGetAttachment(sampleBuffer, key: kCVImageBufferPixelAspectRatioKey, attachmentModeOut: nil)
            ?? (CMFormatDescriptionGetExtensions(formatDesc) as? [CFString: Any])?[kCVImageBufferPixelAspectRatioKey]
        if let dict = rawPar as? NSDictionary,
            let h = (dict[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?.intValue,
            let v = (dict[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? NSNumber)?.intValue,
            h > 0, v > 0
        {
            parRational = RationalAspectRatio(numerator: h, denominator: v)
            cachedPixelAspectRatio = parRational
        } else {
            parRational = cachedPixelAspectRatio
        }

        let frameId = nextFrameId
        nextFrameId &+= 1
        if nextFrameId == 0 {
            nextFrameId = 1
        }
        inFlightFrames[frameId] = FrameContext(
            doNotDisplay: doNotDisplay, hdrMetadata: hdrMetadata, pixelAspectRatio: parRational)
        lock.unlock()

        let refCon = UnsafeMutableRawPointer(bitPattern: UInt(frameId))

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            activeSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: refCon,
            infoFlagsOut: &infoFlags
        )

        lock.lock()
        self._lastDecodeStatus = status
        if status != noErr {
            inFlightFrames.removeValue(forKey: frameId)
        }
        lock.unlock()
    }

    private func createSession(formatDescription: CMFormatDescription) {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        inFlightFrames.removeAll(keepingCapacity: true)

        self.currentFormatDescription = formatDescription

        // Determine bit depth and range from formatDescription extensions
        var pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any]
        let isFullRange = (extensions?[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool) ?? false

        // Check if format is 10-bit:
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let depth = (extensions?[kCMFormatDescriptionExtension_Depth as String] as? NSNumber)?.intValue ?? 24
        let transfer = extensions?[kCVImageBufferTransferFunctionKey as String] as? String
        let bitsPerComponent =
            (extensions?[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue ?? 8

        let is10Bit =
            depth > 24 || bitsPerComponent > 8
            || transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            || mediaSubType == kCMVideoCodecType_HEVC || mediaSubType == kCMVideoCodecType_HEVCWithAlpha
            || mediaSubType == kCMVideoCodecType_DolbyVisionHEVC

        if is10Bit {
            pixelFormat =
                isFullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            pixelFormat =
                isFullRange
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: {
                (
                    decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp,
                    presentationDuration
                ) in
                guard let refCon = decompressionOutputRefCon else { return }
                let decoder = Unmanaged<VTVideoDecoder>.fromOpaque(refCon).takeUnretainedValue()

                var frameCtx: FrameContext? = nil
                decoder.lock.lock()
                decoder._lastCallbackStatus = status
                if let sourceFrameRefCon {
                    let frameId = UInt64(UInt(bitPattern: sourceFrameRefCon))
                    frameCtx = decoder.inFlightFrames.removeValue(forKey: frameId)
                }
                let handler = decoder.outputHandler
                decoder.lock.unlock()

                guard status == noErr, let imageBuffer else { return }
                if let par = frameCtx?.pixelAspectRatio, !par.isSquare,
                    CVBufferCopyAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey, nil) == nil
                {
                    let dict: NSDictionary = [
                        kCVImageBufferPixelAspectRatioHorizontalSpacingKey: par.numerator,
                        kCVImageBufferPixelAspectRatioVerticalSpacingKey: par.denominator,
                    ]
                    CVBufferSetAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey, dict, .shouldPropagate)
                }
                let frame = DecodedFrame(
                    pixelBuffer: imageBuffer,
                    pts: presentationTimeStamp,
                    duration: presentationDuration,
                    doNotDisplay: frameCtx?.doNotDisplay ?? false,
                    hdrMetadata: frameCtx?.hdrMetadata
                )
                handler?(frame)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let decoderSpecification: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        self.lastCreationStatus = status
        if status == noErr {
            self.session = newSession
        } else {
            AppLog.error(.video, "VTDecompressionSessionCreate failed: \(status)")
        }
    }

    public func flush() {
        lock.lock()
        let s = session
        lock.unlock()
        if let s {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
        }
        lock.lock()
        inFlightFrames.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func waitForPendingFrames() {
        drain()
    }

    public func drain() {
        lock.lock()
        let s = session
        lock.unlock()
        if let s {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
        }
    }

    /// Explicitly resets and invalidates the decompression session.
    /// Next decode call will create a fresh session, preventing hardware decoder deadlocks.
    public func resetSession() {
        lock.lock()
        let oldSession = self.session
        self.session = nil
        self.currentFormatDescription = nil
        self.inFlightFrames.removeAll(keepingCapacity: true)
        lock.unlock()

        if let oldSession {
            VTDecompressionSessionWaitForAsynchronousFrames(oldSession)
            VTDecompressionSessionInvalidate(oldSession)
        }
    }

    deinit {
        lock.lock()
        outputHandler = nil
        let s = session
        self.session = nil
        self.inFlightFrames.removeAll()
        lock.unlock()
        if let s {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
    }
}
