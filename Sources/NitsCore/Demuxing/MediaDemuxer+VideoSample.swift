import CoreMedia
import Foundation
import VideoToolbox

extension MediaDemuxer {
    /// The format packets are read as now (`DemuxedVideoPacket.format`).
    var videoFormat: VideoPacketFormat {
        VideoPacketFormat(description: formatDescription, isAnnexB: isAnnexBStream, timebase: timebase)
    }

    /// A queued packet keeps the format it was read with: a variant switch can change it while the packet waits.
    func createVideoSample(from packet: DemuxedVideoPacket) -> CMSampleBuffer? {
        packet.data.withUnsafeBytes { raw in
            createVideoSample(
                bytes: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: packet.data.count,
                pts: packet.pts,
                dts: packet.dts,
                duration: packet.duration,
                format: packet.format
            )
        }
    }

    func createVideoSample(
        bytes: UnsafePointer<UInt8>?,
        count: Int,
        pts: Int64,
        dts: Int64,
        duration: Int64,
        format: VideoPacketFormat? = nil
    ) -> CMSampleBuffer? {
        let format = format ?? videoFormat
        guard let formatDesc = format.description, let bytes, count > 0 else { return nil }

        let hdrMetadata = FrameHDRMetadata(
            packet: bytes, count: count, codec: codec, isAnnexB: format.isAnnexB,
            readsRPU: dolbyVisionProfile != nil,
            readsHDR10Plus: transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)

        let mem: UnsafeMutableRawPointer
        let finalSize: Int
        if !codec.requiresHVCC {
            finalSize = count
            guard let allocated = malloc(finalSize) else { return nil }
            memcpy(allocated, bytes, finalSize)
            mem = allocated
        } else {
            let isAnnexB: Bool
            if format.isAnnexB {
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

        let timebaseDen = format.timebase.den
        let timebaseNum = Int64(format.timebase.num)
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
            if let hdrMetadata {
                CMSetAttachment(
                    sb, key: Self.hdrMetadataAttachmentKey as CFString,
                    value: FrameHDRMetadataBox(metadata: hdrMetadata),
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
}
