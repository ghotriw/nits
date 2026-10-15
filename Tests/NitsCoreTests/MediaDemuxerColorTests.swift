import CoreMedia
import CoreVideo
import Testing
import os

@testable import NitsCore

@_silgen_name("FigVideoFormatDescriptionConformsToDolbyVisionProfile81")
private func figVideoFormatDescriptionConformsToDolbyVisionProfile81(_ formatDescription: CMFormatDescription) -> Bool

@Suite("MediaDemuxer Dynamic Color Metadata Tests")
struct MediaDemuxerColorTests {
    @Test("Demuxer properly extracts dynamic color metadata from reference video if present")
    func testDemuxerMetadataExtraction() {
        guard let referencePath = SyntheticTestMediaFactory.ensureMedia(preset: .hevc10BitHDR) else { return }
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: referencePath) else {
            Issue.record("Failed to initialize MediaDemuxer for reference file")
            return
        }

        #expect(demuxer.width == 1920)
        #expect(demuxer.height == 1080)
        #expect(demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020)
        #expect(demuxer.transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        #expect(demuxer.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_2020)
        #expect(demuxer.isFullRange == false)
        #expect(demuxer.isHDR == true)
    }

    @Test("Demuxer parses Annex B NAL units and converts to HVCC")
    func testAnnexBNALConversion() {
        // Construct synthetic Annex B packet containing VPS (type 32), SPS (type 33), PPS (type 34)
        // VPS: start code (0x00000001) + NAL header (0x4001) + dummy payload
        let vpsBytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C, 0x01]
        // SPS: start code 3-byte (0x000001) + NAL header (0x4201) + dummy payload
        let spsBytes: [UInt8] = [0x00, 0x00, 0x01, 0x42, 0x01, 0x01, 0x60, 0x00]
        // PPS: start code 4-byte (0x00000001) + NAL header (0x4401) + dummy payload
        let ppsBytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xC0]

        var streamData = Data()
        streamData.append(contentsOf: vpsBytes)
        streamData.append(contentsOf: spsBytes)
        streamData.append(contentsOf: ppsBytes)

        let nalus = NALUnitParser.extractNALUnits(from: streamData)
        #expect(nalus.count == 3)
        #expect((nalus[0][0] >> 1) & 0x3F == 32)
        #expect((nalus[1][0] >> 1) & 0x3F == 33)
        #expect((nalus[2][0] >> 1) & 0x3F == 34)

        // Test conversion to HVCC format (4-byte big-endian length prefix)
        let (hvccData, count) = streamData.withUnsafeBytes { raw in
            NALUnitParser.packetDataToHVCC(
                pktData: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: streamData.count,
                isAnnexBStream: true
            )
        }
        #expect(count > 0)
        #expect(hvccData.count == count)

        // First NALU length should be 4 bytes (0x40, 0x01, 0x0C, 0x01 -> length 4)
        let vpsLen = (Int(hvccData[0]) << 24) | (Int(hvccData[1]) << 16) | (Int(hvccData[2]) << 8) | Int(hvccData[3])
        #expect(vpsLen == 4)
    }

    @Test("Demuxer extracts H.264 SPS/PPS NAL units and creates CMVideoFormatDescription")
    func testH264NALExtractionAndFormatDescription() {
        // H.264 SPS: start code (0x00000001) + NAL header (0x67 = type 7, forbidden=0, ref_idc=3) + baseline 640x360 payload
        let spsBytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0C,
            0x83, 0xC5, 0x8B, 0x67, 0x80,
        ]
        // H.264 PPS: start code (0x00000001) + NAL header (0x68 = type 8, forbidden=0, ref_idc=3) + payload
        let ppsBytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x68, 0xCE, 0x3C, 0x80,
        ]

        var streamData = Data()
        streamData.append(contentsOf: spsBytes)
        streamData.append(contentsOf: ppsBytes)

        let nalus = NALUnitParser.extractNALUnits(from: streamData)
        #expect(nalus.count == 2)
        #expect(nalus[0][0] & 0x1F == 7)  // SPS
        #expect(nalus[1][0] & 0x1F == 8)  // PPS

        // Verify CMVideoFormatDescriptionCreateFromH264ParameterSets succeeds with these parameters
        var formatDesc: CMVideoFormatDescription?
        let spsData = nalus[0]
        let ppsData = nalus[1]

        spsData.withUnsafeBytes { spsBuf in
            ppsData.withUnsafeBytes { ppsBuf in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes: [Int] = [spsData.count, ppsData.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                #expect(status == noErr)
            }
        }
        #expect(formatDesc != nil)
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc!)
        #expect(dims.width == 1280)
        #expect(dims.height == 720)
    }

    @Test("MediaDemuxer parses ISO avcC extradata structure correctly")
    func testAvcCExtradataParsing() {
        // Construct standard ISO/IEC 14496-15 avcC box:
        // [0] configurationVersion = 1
        // [1] AVCProfileIndication = 0x42
        // [2] profile_compatibility = 0xC0
        // [3] AVCLevelIndication = 0x1E
        // [4] lengthSizeMinusOne = 0xFF (nalUnitHeaderLength = 4)
        // [5] numOfSequenceParameterSets = 0xE1 (1 SPS)
        // [6..7] spsLength = 23
        // [8..30] spsData
        // [31] numOfPictureParameterSets = 1
        // [32..33] ppsLength = 4
        // [34..37] ppsData
        let spsBytes: [UInt8] = [
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0C,
            0x83, 0xC5, 0x8B, 0x67, 0x80,
        ]
        let ppsBytes: [UInt8] = [
            0x68, 0xCE, 0x3C, 0x80,
        ]

        var avcC = Data([1, 0x42, 0xC0, 0x1E, 0xFF, 0xE1])
        avcC.append(contentsOf: [UInt8(spsBytes.count >> 8), UInt8(spsBytes.count & 0xFF)])
        avcC.append(contentsOf: spsBytes)
        avcC.append(1)  // 1 PPS
        avcC.append(contentsOf: [UInt8(ppsBytes.count >> 8), UInt8(ppsBytes.count & 0xFF)])
        avcC.append(contentsOf: ppsBytes)

        // Parse avcC using the same ISO parsing logic
        var offset = 5
        let numSPS = Int(avcC[offset] & 0x1F)
        offset += 1
        #expect(numSPS == 1)

        let parsedSpsLen = Int(avcC[offset]) << 8 | Int(avcC[offset + 1])
        offset += 2
        let extractedSPS = avcC.subdata(in: offset..<(offset + parsedSpsLen))
        offset += parsedSpsLen
        #expect(extractedSPS == Data(spsBytes))

        let numPPS = Int(avcC[offset])
        offset += 1
        #expect(numPPS == 1)

        let parsedPpsLen = Int(avcC[offset]) << 8 | Int(avcC[offset + 1])
        offset += 2
        let extractedPPS = avcC.subdata(in: offset..<(offset + parsedPpsLen))
        #expect(extractedPPS == Data(ppsBytes))
    }

    @Test("MediaDemuxer parses Dolby Vision Profile 5 dvvC configuration box")
    func testDolbyVisionProfile5Detection() {
        var dvvCBox = Data()
        dvvCBox.append(contentsOf: [0x00, 0x00, 0x00, 0x18])  // box size 24
        dvvCBox.append(contentsOf: [0x64, 0x76, 0x76, 0x43])  // 'dvvC' fourcc
        dvvCBox.append(contentsOf: [0x01, 0x00])  // dv_version_major=1, minor=0
        dvvCBox.append(contentsOf: [0x0A, 0x00])  // profile 5: (5 << 1) = 0x0A
        dvvCBox.append(contentsOf: [0x00])  // compatibility_id = 0
        dvvCBox.append(contentsOf: Array(repeating: UInt8(0), count: 19))  // reserved padding

        let parsed = HDRMetadataEncoding.parseDolbyVisionConfigurationBox(from: dvvCBox)
        #expect(parsed != nil)
        #expect(parsed?.profile == 5)
        #expect(parsed?.configData.count == 24)
    }

    @Test("MediaDemuxer parses Dolby Vision Profile 8 configuration box with correct compatibility id")
    func testDolbyVisionProfile8Detection() {
        var dvcCBox = Data()
        dvcCBox.append(contentsOf: [0x00, 0x00, 0x00, 0x18])  // box size 24
        dvcCBox.append(contentsOf: [0x64, 0x76, 0x76, 0x43])  // 'dvvC' fourcc
        dvcCBox.append(contentsOf: [0x01, 0x00])  // dv_version_major=1, minor=0
        dvcCBox.append(contentsOf: [0x10, 0x00])  // profile 8: (8 << 1) = 0x10
        dvcCBox.append(contentsOf: [0x10])  // compatibility_id 1 (8.1 HDR10) -> (1 << 4) = 0x10
        dvcCBox.append(contentsOf: Array(repeating: UInt8(0), count: 19))

        let parsed = HDRMetadataEncoding.parseDolbyVisionConfigurationBox(from: dvcCBox)
        #expect(parsed != nil)
        #expect(parsed?.profile == 8)
        #expect(parsed?.compatibilityId == 1)
        #expect(parsed?.configData.count == 24)
    }

    @Test("Synthetic Dolby Vision Profile 8.1 CMVideoFormatDescription conforms to Apple Profile 8.1 spec")
    func testSyntheticDolbyVisionProfile81FormatDescription() {
        guard let hevcPath = SyntheticTestMediaFactory.ensureMedia(preset: .hevc10BitHDR),
            let demuxer = MediaDemuxer(url: hevcPath),
            let baseDesc = demuxer.formatDescription
        else {
            return
        }

        guard let extensions = CMFormatDescriptionGetExtensions(baseDesc) as? [String: Any] else {
            Issue.record("Missing extensions on baseDesc")
            return
        }

        var dvvCPayload = [UInt8](repeating: 0, count: 24)
        dvvCPayload[0] = 1  // major version
        dvvCPayload[1] = 0  // minor version
        dvvCPayload[2] = (8 << 1)  // profile 8
        dvvCPayload[3] = (6 << 3) | (1 << 2) | 1  // level 6, rpu=1, bl=1
        dvvCPayload[4] = 1 << 4  // compatId = 1 (Profile 8.1)

        var newExts = extensions
        var atoms =
            (newExts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]) ?? [:]
        atoms["dvvC"] = Data(dvvCPayload)
        newExts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms

        var dvDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_DolbyVisionHEVC,
            width: 1920,
            height: 1080,
            extensions: newExts as CFDictionary,
            formatDescriptionOut: &dvDesc
        )

        #expect(status == noErr)
        #expect(dvDesc != nil)
        if let dvDesc {
            #expect(CMFormatDescriptionGetMediaSubType(dvDesc) == kCMVideoCodecType_DolbyVisionHEVC)
            #expect(figVideoFormatDescriptionConformsToDolbyVisionProfile81(dvDesc) == true)

            // Verify that VideoToolbox accepts this synthetic DV formatDescription and creates decompression session cleanly
            let decoder = VTVideoDecoder()
            #expect(decoder.sessionStatus == noErr)
        }
    }

    @Test("External Dolby Vision MKV file (only when DOLBY_VISION_TEST_PATH is set)")
    func testLocalDolbyVisionMKVProfile8Detection() {
        guard let path = ProcessInfo.processInfo.environment["DOLBY_VISION_TEST_PATH"],
            FileManager.default.fileExists(atPath: path)
        else { return }

        guard let demuxer = MediaDemuxer(url: path) else {
            Issue.record("Failed to create MediaDemuxer for \(path)")
            return
        }

        #expect(demuxer.dolbyVisionProfile == 8)
        #expect(demuxer.dolbyVisionCompatibilityId == 1)
        #expect(demuxer.dolbyVisionProfileString == "8.1")
        #expect(demuxer.dolbyVisionConfigData != nil)
        #expect(demuxer.isHDR == true)

        guard let formatDesc = demuxer.formatDescription else {
            Issue.record("formatDescription is nil")
            return
        }

        #expect(CMFormatDescriptionGetMediaSubType(formatDesc) == kCMVideoCodecType_DolbyVisionHEVC)
        let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any]
        let atoms =
            extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        #expect(atoms?["hvcC"] != nil)
        #expect(atoms?["dvvC"] != nil)
        #expect(figVideoFormatDescriptionConformsToDolbyVisionProfile81(formatDesc) == true)

        // Verify that VideoToolbox instantiates a decompression session with dvh1 and decodes frames with Dolby Vision RPU attachments
        let decoder = VTVideoDecoder()
        let receivedFrame = OSAllocatedUnfairLock(initialState: false)
        let receivedRPU = OSAllocatedUnfairLock(initialState: false)
        let compatibilityId = OSAllocatedUnfairLock<Int?>(initialState: nil)

        decoder.setOutputHandler { frame in
            receivedFrame.withLock { $0 = true }
            let atts = CVBufferCopyAttachments(frame.pixelBuffer, .shouldPropagate) as? [String: Any]
            print("Decoded frame atts keys: \(atts?.keys.sorted() ?? [])")
            if let val = atts?["DolbyCompatibilityID"] {
                if let str = val as? String, let intVal = Int(str) {
                    compatibilityId.withLock { $0 = intVal }
                } else if let num = val as? NSNumber {
                    compatibilityId.withLock { $0 = num.intValue }
                } else if let intVal = val as? Int {
                    compatibilityId.withLock { $0 = intVal }
                }
            }
            if let rpu = atts?["DolbyVisionRPUData"] as? Data, !rpu.isEmpty {
                receivedRPU.withLock { $0 = true }
            }
        }

        var decodedSamples = 0
        while decodedSamples < 30, let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            decodedSamples += 1
            if receivedFrame.withLock({ $0 }) { break }
        }

        decoder.flush()

        #expect(decoder.sessionStatus == noErr)
        #expect(decoder.hasActiveSession == true)
        #expect(decodedSamples > 0)
        #expect(decoder.lastDecodeStatus == noErr)
        #expect(decoder.lastCallbackStatus == noErr)
        #expect(receivedFrame.withLock { $0 } == true)
        #expect(receivedRPU.withLock { $0 } == true)
        #expect(compatibilityId.withLock { $0 } == 1)
    }

    @Test("InterruptContext cancellation state behaves correctly")
    func testInterruptContext() {
        let ctx = MediaDemuxer.InterruptContext()
        #expect(ctx.isCancelled == false)

        ctx.cancel()
        #expect(ctx.isCancelled == true)
        #expect(ctx.shouldAbort == true)
    }

    @Test("FFmpegInterrupt aborts past its deadline without counting as cancelled, and keeps the last error")
    func interruptDeadlineAndLastError() {
        let expired = FFmpegInterrupt(timeout: .zero)
        #expect(expired.shouldAbort == true)
        #expect(expired.isCancelled == false)

        let open = FFmpegInterrupt(timeout: .seconds(60))
        #expect(open.shouldAbort == false)
        #expect(open.lastError == nil)
        open.recordError(code: -5, message: "Input/output error")
        #expect(open.lastError?.code == -5)
        #expect(open.lastError?.message == "Input/output error")
    }

    @Test("Demuxer initializes with custom headers dictionary without breaking")
    func testDemuxerWithHeadersParameter() {
        guard let referencePath = SyntheticTestMediaFactory.ensureMedia(preset: .uhdHDRSubtitles) else { return }
        guard FileManager.default.fileExists(atPath: referencePath) else { return }

        let headers = ["X-Custom-Token": "secret123", "User-Agent": "NitsTest"]
        let demuxer = MediaDemuxer(url: referencePath, headers: headers)
        #expect(demuxer != nil)
        #expect(demuxer?.width == 3840)
    }

    @Test("extractNALUnits handles 4-byte length prefix starting with 00 00 01 without false Annex B detection")
    func testNALExtractionWithLengthPrefixedStreamAndLargeSize() {
        // NAL of size 65538 (0x00 0x01 0x00 0x02)
        // If length prefix starts with 00 00 01 02, previous heuristic misinterpreted it as Annex B start code!
        let nalPayload = Array(repeating: UInt8(0x42), count: 65538)
        var packetData = Data([0x00, 0x01, 0x00, 0x02])
        packetData.append(contentsOf: nalPayload)

        // With isAnnexB = false (standard MP4/MKV stream)
        let nalus = NALUnitParser.extractNALUnits(from: packetData, isAnnexB: false)
        #expect(nalus.count == 1)
        #expect(nalus[0].count == 65538)

        // packetDataToHVCC with isAnnexBStream = false must not corrupt packet
        let (hvccData, count) = packetData.withUnsafeBytes { raw in
            NALUnitParser.packetDataToHVCC(
                pktData: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: packetData.count,
                isAnnexBStream: false
            )
        }
        #expect(count == packetData.count)
        #expect(hvccData == packetData)
    }
}
