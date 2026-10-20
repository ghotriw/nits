import CoreMedia
import Foundation
import VideoToolbox

extension MediaDemuxer {
    func createVideoSample(from rawData: Data, pts: Int64, dts: Int64, duration: Int64) -> CMSampleBuffer? {
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

    func createVideoSample(
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
}
