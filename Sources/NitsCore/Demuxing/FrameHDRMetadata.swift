import Foundation

/// A frame's dynamic HDR metadata, from its packet: what tone mapping adapts to frame by frame.
public struct FrameHDRMetadata: Sendable, Equatable {
    /// The Dolby Vision RPU (NAL unit 62).
    public var dolbyVision: DolbyVisionFrameMetadata?
    /// HDR10+ (SMPTE ST 2094-40), from a prefix SEI.
    public var hdr10Plus: HDR10PlusFrameMetadata?

    public init(dolbyVision: DolbyVisionFrameMetadata? = nil, hdr10Plus: HDR10PlusFrameMetadata? = nil) {
        self.dolbyVision = dolbyVision
        self.hdr10Plus = hdr10Plus
    }

    /// The metadata of a packet, nil without any: an HEVC packet's Dolby Vision RPU (`readsRPU`) and HDR10+ SEI, in
    /// one pass over its NAL units, or an AV1 packet's HDR10+ metadata OBU. HDR10+ only matters to a PQ stream
    /// (`readsHDR10Plus`), and only without L1, which takes its place: its SEIs are parsed only then.
    init?(
        packet bytes: UnsafePointer<UInt8>, count: Int, codec: VideoCodec, isAnnexB: Bool, readsRPU: Bool,
        readsHDR10Plus: Bool
    ) {
        switch codec {
        case .hevc where readsRPU || readsHDR10Plus:
            var rpu: DolbyVisionFrameMetadata?
            // Prefix SEIs come before the RPU, which ends the access unit: kept until it tells whether L1 is there.
            var seis: [UnsafeBufferPointer<UInt8>] = []
            NALUnitParser.forEachHEVCNALUnit(bytes: bytes, count: count, isAnnexB: isAnnexB) { type, nalu in
                if type == 62, readsRPU, rpu == nil {
                    rpu = DolbyVisionRPUParser.parse(naluData: Data(nalu))
                } else if type == 39, readsHDR10Plus {
                    seis.append(nalu)
                }
                return true
            }
            let hdr10Plus =
                rpu?.l1 == nil ? seis.lazy.compactMap { HDR10PlusParser.parse(seiNALU: Data($0)) }.first : nil
            guard rpu != nil || hdr10Plus != nil else { return nil }
            self.init(dolbyVision: rpu, hdr10Plus: hdr10Plus)
        case .av1 where readsHDR10Plus:
            guard let hdr10Plus = HDR10PlusParser.parse(av1Packet: bytes, count: count) else { return nil }
            self.init(hdr10Plus: hdr10Plus)
        default:
            return nil
        }
    }
}

/// Carries `FrameHDRMetadata` as a sample buffer attachment (`MediaDemuxer.hdrMetadataAttachmentKey`) to the decoders.
public final class FrameHDRMetadataBox: NSObject, Sendable {
    public let metadata: FrameHDRMetadata

    public init(metadata: FrameHDRMetadata) {
        self.metadata = metadata
        super.init()
    }
}

/// The scene luminance of an HDR10+ frame (SMPTE ST 2094-40, application 4): what Dolby Vision's L1 tells, for
/// HDR10. The metadata holds per scene: it changes at cuts.
public struct HDR10PlusFrameMetadata: Sendable, Equatable {
    /// The scene's brightest linear colour component (the largest `maxscl`), in nits.
    public let maxNits: Float
    /// The scene's average linear maxRGB (`average_maxrgb`), in nits.
    public let averageNits: Float

    public init(maxNits: Float, averageNits: Float) {
        self.maxNits = maxNits
        self.averageNits = averageNits
    }
}
