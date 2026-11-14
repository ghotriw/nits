import CFFmpeg
import CoreMedia
import Foundation
import VideoToolbox

extension MediaDemuxer {
    /// The format packets are read as now (`DemuxedVideoPacket.format`).
    var videoFormat: VideoPacketFormat {
        var codecParameters: UnsafePointer<AVCodecParameters>?
        if videoStreamIndex >= 0, let stream = input.stream(videoStreamIndex) {
            codecParameters = UnsafePointer(stream.pointee.codecpar)
        }
        return VideoPacketFormat(
            description: formatDescription, isAnnexB: isAnnexBStream,
            unitLengthSize: unitLengthSize(of: codecParameters),
            timebase: timebase, variantGeneration: variantGeneration, sampleAspectRatio: sampleAspectRatio)
    }

    /// The size of the unit lengths in the video packets of a stream with these parameters: what its `avcC` / `hvcC`
    /// declares, 4 for Annex B packets (rewritten with them) and anything else. The description is made with it
    /// (`VideoFormatDescriptionBuilder.nalUnitHeaderLength`).
    func unitLengthSize(of codecParameters: UnsafePointer<AVCodecParameters>?) -> Int {
        guard !isAnnexBStream, let codecParameters else { return 4 }
        return NALUnitParser.lengthSize(of: codecParameters, codec: codec)
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
            packet: bytes, count: count, codec: codec, isAnnexB: format.isAnnexB, lengthSize: format.unitLengthSize,
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

extension MediaDemuxer {
    /// A video packet as it queues: with the format description of the stream as the packet leaves it. A keyframe whose
    /// parameter sets (in band, H.264 and HEVC in MPEG-TS and the like) differ from the keyframe before starts a new
    /// description, which the packets after it carry and the decoder follows (`VTVideoDecoder` makes a session for
    /// each); the packets queued before keep theirs.
    func videoPacket(from pkt: AVPacket) -> DemuxedVideoPacket {
        refreshVideoFormat(from: pkt)
        let packet = DemuxedVideoPacket(pkt, format: videoFormat)
        noteKeyframe(of: packet)
        return packet
    }

    /// Notes a keyframe queued in `keyframeTrail`, in its own time base (the one it was read with, as `queuedPosition`
    /// reads the queue). Every picture queued comes here: read (`videoPacket(from:)`) or held for a switch and queued
    /// at its splice (`queueHeldVideo`).
    func noteKeyframe(of packet: DemuxedVideoPacket) {
        let base = packet.format.timebase
        guard packet.isKeyFrame, packet.effectivePTS != Int64.min, base.den > 0 else { return }
        keyframeTrail.note(Double(packet.effectivePTS) * Double(base.num) / Double(base.den))
    }

    /// The `avcC` / `hvcC` a key frame brings as new extradata: an HLS stream of fragmented MP4 whose `EXT-X-MAP` changed
    /// at a discontinuity (`HLSLane` hands it on), whose parameter sets are not in band.
    private func newExtradataSets(of pkt: AVPacket) -> VideoFormatDescriptionBuilder.ParameterSets? {
        var packet = pkt
        var size = 0
        guard let side = av_packet_get_side_data(&packet, AV_PKT_DATA_NEW_EXTRADATA, &size), size > 0,
            let parsed = VideoFormatDescriptionBuilder.parameterSets(
                fromExtradata: Data(bytes: side, count: size), codec: codec),
            let sps = parsed.sets.sps, let pps = parsed.sets.pps, !sps.isEmpty, !pps.isEmpty,
            codec != .hevc || parsed.sets.vps != nil
        else { return nil }
        return parsed.sets
    }

    /// The parameter sets a key frame brings: as new extradata, or in band before its slices.
    private func keyframeParameterSets(of pkt: AVPacket) -> VideoFormatDescriptionBuilder.ParameterSets? {
        if let fromSideData = newExtradataSets(of: pkt) { return fromSideData }
        guard isAnnexBStream, let bytes = pkt.data, pkt.size > 0 else { return nil }
        // The sets come before the slices: the start of the packet holds them.
        let head = Data(bytes: bytes, count: min(Int(pkt.size), 4096))
        guard let parsed = VideoFormatDescriptionBuilder.parameterSets(fromExtradata: head, codec: codec),
            parsed.isAnnexB, parsed.sets.sps != nil, parsed.sets.pps != nil,
            codec != .hevc || parsed.sets.vps != nil
        else { return nil }
        return parsed.sets
    }

    private func refreshVideoFormat(from pkt: AVPacket) {
        guard pkt.flags & AV_PKT_FLAG_KEY != 0 else { return }
        // The first keyframe after a slow seek tells the size it lands at, whatever came before it: the player may be
        // showing the size of another stretch (content, an advertisement, content again), which the reading, further on,
        // has left. Told at that keyframe, whatever it brings (without parameter sets, the size of the description now: a
        // keyframe further on with other sets tells the change), as told later, at a change further on, the landing would
        // replace the changes before it (`PlayerEngine.videoSizeWillPlay`).
        let landing = reportsVideoSizeAtNextKeyframe
        reportsVideoSizeAtNextKeyframe = false
        var sizeChanged = false
        // `seen` are the sets the description now is made of (`makeVideoFormatDescription`).
        if codec.requiresParameterSets, let sets = keyframeParameterSets(of: pkt) {
            let seen = lastSeenParameterSets
            lastSeenParameterSets = sets
            if let seen, Self.parameterSetsDiffer(seen, sets) {
                var codecParameters: UnsafePointer<AVCodecParameters>?
                if videoStreamIndex >= 0, let stream = input.stream(videoStreamIndex) {
                    codecParameters = UnsafePointer(stream.pointee.codecpar)
                }
                if let description = makeVideoFormatDescription(parameterSets: sets, codecParameters: codecParameters) {
                    formatDescription = description
                    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                    // Other sets for the same pictures (an encoder varying its SPS' timing) change the description, not
                    // the size the player draws at: it is told when that changes.
                    sizeChanged = Int(dimensions.width) != width || Int(dimensions.height) != height
                    width = Int(dimensions.width)
                    height = Int(dimensions.height)
                } else {
                    // The description is still of the sets before (which `makeVideoFormatDescription` replaced): the
                    // next keyframe with these tries again.
                    lastSeenParameterSets = seen
                    AppLog.warning(
                        .demuxer, "Parameter sets changed in the stream, but no format description came of them")
                }
            }
        }
        guard sizeChanged || landing else { return }
        // From the description the pictures carry, as a variant's change takes it: `width` and `height` are what the open
        // (or the stream's configuration) said, which FFmpeg may not have probed.
        let size = formatDescription.map(CMVideoFormatDescriptionGetDimensions)
        let reportedWidth = size.map { Int($0.width) } ?? width
        let reportedHeight = size.map { Int($0.height) } ?? height
        let time = pkt.pts != Int64.min ? pkt.pts : pkt.dts
        let seconds = timebase.den > 0 ? Double(time) * Double(timebase.num) / Double(timebase.den) : 0
        AppLog.info(.demuxer, "The pictures are \(reportedWidth)x\(reportedHeight) from \(seconds)s")
        onVideoSizeChanged?(
            VideoSizeChange(
                seconds: seconds, width: reportedWidth, height: reportedHeight, sampleAspectRatio: sampleAspectRatio,
                isLanding: landing))
    }
}

extension MediaDemuxer {
    /// Whether two sets of parameter sets are different ones. The bytes may differ by zero bytes after a NAL unit (it is
    /// followed by padding before the next start code, which one extraction keeps and another does not): that is no change.
    static func parameterSetsDiffer(
        _ first: VideoFormatDescriptionBuilder.ParameterSets, _ second: VideoFormatDescriptionBuilder.ParameterSets
    ) -> Bool {
        func trimmed(_ data: Data?) -> Data? {
            guard var data else { return nil }
            while data.last == 0 { data.removeLast() }
            return data
        }
        return trimmed(first.sps) != trimmed(second.sps) || trimmed(first.pps) != trimmed(second.pps)
            || trimmed(first.vps) != trimmed(second.vps)
    }
}
