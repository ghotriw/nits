import CFFmpeg
import CoreMedia
import Foundation

/// Builds the `CMVideoFormatDescription` a stream's samples carry: H.264 / HEVC parameter sets,
/// `av1C` / `vpcC` atoms, colour and HDR extensions, and the Dolby Vision `dvh1` variant.
///
/// Pure: `MediaDemuxer` gathers the inputs (including parameter sets and SEI found by scanning
/// packets) and owns all reading.
struct VideoFormatDescriptionBuilder {
    struct ParameterSets {
        var vps: Data?
        var sps: Data?
        var pps: Data?
    }

    /// HDR metadata carried in an HEVC prefix SEI NAL unit, in bitstream order.
    enum HDRSEIMessage: Equatable {
        /// SEI 137: the 24-byte mastering display colour volume and its peak luminance.
        case masteringDisplay(Data, maxLuminanceNits: Float)
        /// SEI 144: the 4-byte content light level info.
        case contentLightLevel(Data, maxCLL: Int, maxFALL: Int)
    }

    var codec: VideoCodec
    var width: Int
    var height: Int
    var colorPrimaries: CFString
    var transferFunction: CFString
    var yCbCrMatrix: CFString
    var isFullRange: Bool
    var chromaLocation: CFString
    var bitDepth: Int
    var sampleAspectRatio: RationalAspectRatio
    var masteringDisplay: Data?
    var contentLightLevel: Data?
    var parameterSets: ParameterSets
    /// Profile and dvcC/dvvC payload of a Dolby Vision HEVC stream.
    var dolbyVision: (profile: Int, configData: Data)?

    /// - Parameter codecParameters: the video stream's parameters, for `av1C` / `vpcC` extradata.
    func make(codecParameters: UnsafePointer<AVCodecParameters>?) -> CMVideoFormatDescription? {
        var extensionsDict: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: colorPrimaries as String,
            kCVImageBufferTransferFunctionKey as String: transferFunction as String,
            kCVImageBufferYCbCrMatrixKey as String: yCbCrMatrix as String,
            kCMFormatDescriptionExtension_FullRangeVideo as String: isFullRange,
            kCVImageBufferChromaLocationTopFieldKey as String: chromaLocation as String,
            kCVImageBufferChromaLocationBottomFieldKey as String: chromaLocation as String,
            // Lets VTVideoDecoder pick a 10-bit output for high-bit-depth SDR (e.g. VP9 profile 2 / AV1 BT.709),
            // which neither the transfer function nor the codec type reveals.
            kCMFormatDescriptionExtension_BitsPerComponent as String: bitDepth,
        ]

        if !sampleAspectRatio.isSquare {
            let parDict: [String: Int] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: sampleAspectRatio.numerator,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: sampleAspectRatio.denominator,
            ]
            extensionsDict[kCVImageBufferPixelAspectRatioKey as String] = parDict
        }

        if let masteringDisplay {
            extensionsDict[kCVImageBufferMasteringDisplayColorVolumeKey as String] = masteringDisplay
        }
        if let contentLightLevel {
            extensionsDict[kCVImageBufferContentLightLevelInfoKey as String] = contentLightLevel
        }

        var formatDesc: CMVideoFormatDescription?
        if !codec.requiresParameterSets {
            // Codecs that construct format description via configuration atoms (av1C, vpcC, etc.)
            // or directly via CMVideoFormatDescriptionCreate without SPS/PPS parameter sets:
            if codec == .av1, let codecpar = codecParameters, let extradata = codecpar.pointee.extradata,
                codecpar.pointee.extradata_size > 0
            {
                let extraSize = Int(codecpar.pointee.extradata_size)
                let extraData = Data(bytes: extradata, count: extraSize)
                var atoms =
                    (extensionsDict[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                        as? [String: Any]) ?? [:]
                atoms["av1C"] = extraData
                extensionsDict[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms
            } else if codec == .vp9, let codecpar = codecParameters {
                let vpccData: Data
                if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size >= 12 {
                    vpccData = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
                } else {
                    vpccData = Self.synthesizeVPCC(
                        profile: Int(codecpar.pointee.profile),
                        level: Int(codecpar.pointee.level),
                        bitDepth: bitDepth,
                        isFullRange: isFullRange,
                        colorPrimaries: Int(codecpar.pointee.color_primaries.rawValue),
                        colorTransfer: Int(codecpar.pointee.color_trc.rawValue),
                        colorSpace: Int(codecpar.pointee.color_space.rawValue)
                    )
                }
                var atoms =
                    (extensionsDict[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                        as? [String: Any]) ?? [:]
                atoms["vpcC"] = vpccData
                extensionsDict[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms
            }

            var desc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codec.cmVideoCodecType,
                width: Int32(width),
                height: Int32(height),
                extensions: extensionsDict as CFDictionary,
                formatDescriptionOut: &desc
            )
            if status == noErr {
                formatDesc = desc
            }
        } else if let spsData = parameterSets.sps, let ppsData = parameterSets.pps {
            if codec == .hevc, let vpsData = parameterSets.vps {
                vpsData.withUnsafeBytes { vpsBytes in
                    spsData.withUnsafeBytes { spsBytes in
                        ppsData.withUnsafeBytes { ppsBytes in
                            let pointers: [UnsafePointer<UInt8>] = [
                                vpsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ]
                            let sizes: [Int] = [vpsData.count, spsData.count, ppsData.count]

                            var baseFormatDesc: CMVideoFormatDescription?
                            _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pointers,
                                parameterSetSizes: sizes,
                                nalUnitHeaderLength: 4,
                                extensions: extensionsDict as CFDictionary,
                                formatDescriptionOut: &baseFormatDesc
                            )

                            formatDesc = baseFormatDesc
                        }
                    }
                }
            } else if codec == .h264 {
                spsData.withUnsafeBytes { spsBytes in
                    ppsData.withUnsafeBytes { ppsBytes in
                        let pointers: [UnsafePointer<UInt8>] = [
                            spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ]
                        let sizes: [Int] = [spsData.count, ppsData.count]

                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc
                        )
                    }
                }
            }
        }

        if codec == .hevc, let baseDesc = formatDesc, let dolbyVision {
            // For Dolby Vision HEVC (Profile 5, 8.1, etc.), attach the standard configuration box (dvcC for <= 7, dvvC for > 7)
            // and use kCMVideoCodecType_DolbyVisionHEVC ('dvh1') so VideoToolbox decodes the HEVC base layer
            // and parses dynamic DolbyVisionRPUData into CVPixelBuffer attachments.
            let dvProfile = dolbyVision.profile
            let atomKey = dvProfile <= 7 ? "dvcC" : "dvvC"
            if let rawExts = CMFormatDescriptionGetExtensions(baseDesc) as? [String: Any] {
                var newExts = rawExts
                var atoms =
                    (rawExts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any])
                    ?? [:]
                atoms[atomKey] = dolbyVision.configData
                newExts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms

                var dvDesc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    codecType: kCMVideoCodecType_DolbyVisionHEVC,
                    width: Int32(width),
                    height: Int32(height),
                    extensions: newExts as CFDictionary,
                    formatDescriptionOut: &dvDesc
                )
                if status == noErr, let dvDesc {
                    AppLog.info(
                        .video,
                        "Configured Dolby Vision formatDescription (Profile \(dvProfile), codec: dvh1, atom: \(atomKey))"
                    )
                    return dvDesc
                }
            }
        }

        return formatDesc
    }

    // MARK: - Bitstream configuration parsing

    /// Parameter sets from a video stream's extradata: raw Annex B, H.264 `avcC` or HEVC `hvcC`
    /// (ISO/IEC 14496-15). Returns `nil` when the extradata is none of these; otherwise also whether
    /// the stream's packets use Annex B start codes.
    static func parameterSets(fromExtradata data: Data, codec: VideoCodec) -> (
        sets: ParameterSets, isAnnexB: Bool
    )? {
        let size = data.count
        guard size > 0 else { return nil }

        // Case 1: Raw Annex B in extradata (starts with 0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
        if size >= 3 && data[0] == 0 && data[1] == 0 && (data[2] == 1 || (size > 3 && data[2] == 0 && data[3] == 1)) {
            let nalus = NALUnitParser.extractNALUnits(from: data)
            var sets = ParameterSets()
            for nalu in nalus {
                if codec == .hevc {
                    let nalType = (nalu[0] >> 1) & 0x3F
                    if nalType == 32 {
                        sets.vps = nalu
                    } else if nalType == 33 {
                        sets.sps = nalu
                    } else if nalType == 34 {
                        sets.pps = nalu
                    }
                } else if codec == .h264 {
                    let nalType = nalu[0] & 0x1F
                    if nalType == 7 { sets.sps = nalu } else if nalType == 8 { sets.pps = nalu }
                }
            }
            return (sets, true)
        }

        // Case 2: H.264 avcC format (ISO/IEC 14496-15)
        if codec == .h264 && size >= 7 && data[0] == 1 {
            var offset = 5
            let numSPS = Int(data[offset] & 0x1F)
            offset += 1
            var sps: Data?
            for _ in 0..<numSPS {
                guard offset + 2 <= size else { break }
                let spsLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
                guard offset + spsLen <= size else { break }
                sps = data.subdata(in: offset..<(offset + spsLen))
                offset += spsLen
                break  // first SPS is sufficient
            }
            guard offset < size else { return (ParameterSets(sps: sps), false) }
            let numPPS = Int(data[offset])
            offset += 1
            var pps: Data?
            for _ in 0..<numPPS {
                guard offset + 2 <= size else { break }
                let ppsLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
                guard offset + ppsLen <= size else { break }
                pps = data.subdata(in: offset..<(offset + ppsLen))
                offset += ppsLen
                break  // first PPS
            }
            return (ParameterSets(sps: sps, pps: pps), false)
        }

        // Case 3: HEVC hvcC format (ISO/IEC 14496-15)
        if codec == .hevc && size >= 23 && data[0] == 1 {
            var sets = ParameterSets()
            var offset = 22
            let numOfArrays = Int(data[offset])
            offset += 1

            for _ in 0..<numOfArrays {
                guard offset + 3 <= size else { break }
                let nalType = data[offset] & 0x3F
                let numNalus = Int(data[offset + 1]) << 8 | Int(data[offset + 2])
                offset += 3

                for _ in 0..<numNalus {
                    guard offset + 2 <= size else { break }
                    let nalLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                    offset += 2
                    guard offset + nalLen <= size else { break }
                    let naluData = data.subdata(in: offset..<(offset + nalLen))
                    offset += nalLen

                    if nalType == 32 {
                        sets.vps = naluData
                    } else if nalType == 33 {
                        sets.sps = naluData
                    } else if nalType == 34 {
                        sets.pps = naluData
                    }
                }
            }
            return (sets, false)
        }

        return nil
    }

    /// HDR messages (mastering display, content light level) in an HEVC prefix SEI NAL unit.
    static func hdrSEIMessages(inPrefixSEI naluData: Data) -> [HDRSEIMessage] {
        var messages: [HDRSEIMessage] = []
        var p = 2
        while p < naluData.count {
            var payloadType = 0
            while p < naluData.count && naluData[p] == 0xFF {
                payloadType += 255
                p += 1
            }
            if p < naluData.count {
                payloadType += Int(naluData[p])
                p += 1
            }

            var payloadSize = 0
            while p < naluData.count && naluData[p] == 0xFF {
                payloadSize += 255
                p += 1
            }
            if p < naluData.count {
                payloadSize += Int(naluData[p])
                p += 1
            }

            guard p + payloadSize <= naluData.count else { break }
            let rawPayload = naluData.subdata(in: p..<(p + payloadSize))

            // Remove emulation prevention bytes (0x00 0x00 0x03 -> 0x00 0x00)
            var unescaped: [UInt8] = []
            unescaped.reserveCapacity(rawPayload.count)
            var u = 0
            let rawBytes = [UInt8](rawPayload)
            while u < rawBytes.count {
                if u + 2 < rawBytes.count && rawBytes[u] == 0 && rawBytes[u + 1] == 0 && rawBytes[u + 2] == 3 {
                    unescaped.append(0)
                    unescaped.append(0)
                    u += 3
                } else {
                    unescaped.append(rawBytes[u])
                    u += 1
                }
            }

            // SEI 137: Mastering display colour volume (24 bytes)
            if payloadType == 137 && unescaped.count >= 24 {
                let maxLumRaw =
                    (UInt32(unescaped[16]) << 24) | (UInt32(unescaped[17]) << 16) | (UInt32(unescaped[18]) << 8)
                    | UInt32(unescaped[19])
                messages.append(
                    .masteringDisplay(Data(unescaped[0..<24]), maxLuminanceNits: Float(maxLumRaw) / 10000.0))
            }
            // SEI 144: Content light level info (4 bytes: maxCLL 2 bytes, maxFALL 2 bytes)
            else if payloadType == 144 && unescaped.count >= 4 {
                messages.append(
                    .contentLightLevel(
                        Data(unescaped[0..<4]),
                        maxCLL: (Int(unescaped[0]) << 8) | Int(unescaped[1]),
                        maxFALL: (Int(unescaped[2]) << 8) | Int(unescaped[3])))
            }

            p += payloadSize
        }
        return messages
    }

    /// Synthesizes a standard 12-byte VP Codec Configuration Box (`vpcC` per ISO/IEC 14496-15)
    /// for streams (such as WebM / Matroska) where the demuxer does not supply container extradata.
    package static func synthesizeVPCC(
        profile: Int,
        level: Int,
        bitDepth: Int,
        isFullRange: Bool,
        colorPrimaries: Int,
        colorTransfer: Int,
        colorSpace: Int
    ) -> Data {
        var box = [UInt8](repeating: 0, count: 12)
        // Byte 0: version = 1
        box[0] = 1
        // Bytes 1..3: flags = 0
        box[1] = 0
        box[2] = 0
        box[3] = 0
        // Byte 4: profile (0, 1, 2, or 3). Sanitize negative / unset FFmpeg values.
        box[4] = UInt8(max(0, min(profile, 3)))
        // Byte 5: level (e.g. 10 for 1.0, 31 for 3.1, 51 for 5.1). Default to 0 if unknown/unset.
        box[5] = UInt8(max(0, min(level, 255)))
        // Byte 6: bitDepth (4 bits) | chromaSubsampling (3 bits: 0=4:2:0 vertical, 1=4:2:0 colocated, 2=4:2:2, 3=4:4:4) | videoFullRangeFlag (1 bit)
        let depthVal = UInt8(max(8, min(bitDepth, 12)))
        let chromaSubsampling: UInt8 = 1  // 4:2:0 colocated (standard for VP9)
        let fullRangeFlag: UInt8 = isFullRange ? 1 : 0
        box[6] = (depthVal << 4) | (chromaSubsampling << 1) | fullRangeFlag
        // Byte 7: colourPrimaries (ISO/IEC 23001-8 / ITU-T H.273)
        box[7] = UInt8(max(0, min(colorPrimaries, 255)))
        // Byte 8: transferCharacteristics (ISO/IEC 23001-8 / ITU-T H.273)
        box[8] = UInt8(max(0, min(colorTransfer, 255)))
        // Byte 9: matrixCoefficients (ISO/IEC 23001-8 / ITU-T H.273)
        box[9] = UInt8(max(0, min(colorSpace, 255)))
        // Bytes 10..11: codecInitializationDataSize = 0 (16-bit big endian)
        box[10] = 0
        box[11] = 0
        return Data(box)
    }
}
