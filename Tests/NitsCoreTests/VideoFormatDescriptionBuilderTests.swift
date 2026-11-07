import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("Video format description")
struct VideoFormatDescriptionBuilderTests {
    /// An MP4 can write the lengths of its NAL units in 1 to 4 bytes (`lengthSizeMinusOne` of the `avcC`). The
    /// description tells VideoToolbox how to read them: said 4 for packets of 2, the decoder produced nothing and the
    /// picture stayed empty.
    @Test("The size of the unit lengths is the one the avcC declares", arguments: [1, 2, 4])
    func unitLengthSize(_ size: Int) throws {
        let path = try #require(SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264))
        let demuxer = try #require(MediaDemuxer(url: path))
        let sets = try #require(demuxer.lastSeenParameterSets)

        let parameters = try #require(avcodec_parameters_alloc())
        var freed: UnsafeMutablePointer<AVCodecParameters>? = parameters
        defer { avcodec_parameters_free(&freed) }
        // configurationVersion, profile, compatibility, level, then six reserved bits and lengthSizeMinusOne.
        let avcC: [UInt8] = [0x01, 0x64, 0x00, 0x1F, UInt8(0xFC | (size - 1)), 0xE0]
        let extradata = try #require(av_mallocz(avcC.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            .assumingMemoryBound(to: UInt8.self)
        extradata.update(from: avcC, count: avcC.count)
        parameters.pointee.extradata = extradata
        parameters.pointee.extradata_size = Int32(avcC.count)

        let description = try #require(
            demuxer.makeVideoFormatDescription(parameterSets: sets, codecParameters: UnsafePointer(parameters)))
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
        #expect(status == noErr)
        #expect(Int(headerLength) == size)
    }
}

@Suite("HEVC units behind short lengths")
struct HEVCUnitLengthTests {
    @Test("A packet's units are found behind lengths of 1, 2 and 4 bytes", arguments: [1, 2, 4])
    func findsUnits(_ size: Int) {
        // Headers of a prefix SEI (type 39) and an RPU (type 62), each with a two-byte payload.
        let units: [[UInt8]] = [[39 << 1, 0x01, 0xAA, 0xBB], [62 << 1, 0x01, 0xCC, 0xDD]]
        let packet = units.flatMap { unit in
            Array(withUnsafeBytes(of: UInt32(unit.count).bigEndian, Array.init).suffix(size)) + unit
        }
        var found: [(UInt8, [UInt8])] = []
        packet.withUnsafeBufferPointer { buffer in
            NALUnitParser.forEachHEVCNALUnit(
                bytes: buffer.baseAddress!, count: buffer.count, isAnnexB: false, lengthSize: size
            ) { type, unit in
                found.append((type, Array(unit)))
                return true
            }
        }
        #expect(found.map(\.0) == [39, 62])
        #expect(found.map(\.1) == units)
    }
}

@Suite("Units of a packet behind short lengths")
struct ExtractNALUnitsLengthTests {
    @Test("extractNALUnits splits a packet by the declared size of the lengths", arguments: [1, 2, 4])
    func splits(_ size: Int) {
        let units: [[UInt8]] = [[0x40, 0x01, 0x0C], [0x42, 0x01, 0x01, 0x02], [0x44, 0x01]]
        let packet = units.flatMap { unit in
            Array(withUnsafeBytes(of: UInt32(unit.count).bigEndian, Array.init).suffix(size)) + unit
        }
        let found = NALUnitParser.extractNALUnits(from: Data(packet), isAnnexB: false, lengthSize: size)
        #expect(found.map { [UInt8]($0) } == units)
    }
}

@Suite("Size of the unit lengths")
struct UnitLengthSizeTests {
    private func lengthSize(extradata record: [UInt8], codec: VideoCodec) throws -> Int {
        let parameters = try #require(avcodec_parameters_alloc())
        var freed: UnsafeMutablePointer<AVCodecParameters>? = parameters
        defer { avcodec_parameters_free(&freed) }
        let extradata = try #require(av_mallocz(record.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            .assumingMemoryBound(to: UInt8.self)
        extradata.update(from: record, count: record.count)
        parameters.pointee.extradata = extradata
        parameters.pointee.extradata_size = Int32(record.count)
        return NALUnitParser.lengthSize(of: parameters, codec: codec)
    }

    @Test("An hvcC declares it in the last two bits of its 22nd byte", arguments: [1, 2, 4])
    func hvcC(_ size: Int) throws {
        var record = [UInt8](repeating: 0, count: 23)
        record[0] = 1
        record[21] = UInt8(0x03 << 2 | (size - 1))  // numTemporalLayers, temporalIdNested, lengthSizeMinusOne
        #expect(try lengthSize(extradata: record, codec: .hevc) == size)
        #expect(try lengthSize(extradata: Array(record.prefix(22)), codec: .hevc) == 4, "A record cut short")
    }

    @Test("Extradata that is not a record, and packets in Annex B, are 4")
    func annexB() throws {
        #expect(try lengthSize(extradata: [0, 0, 0, 1, 0x67, 0x42], codec: .h264) == 4)

        let path = try #require(SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264))
        let demuxer = try #require(MediaDemuxer(url: path))
        let parameters = try #require(avcodec_parameters_alloc())
        var freed: UnsafeMutablePointer<AVCodecParameters>? = parameters
        defer { avcodec_parameters_free(&freed) }
        let avcC: [UInt8] = [0x01, 0x64, 0x00, 0x1F, 0xFD, 0xE0]  // 2-byte lengths
        let extradata = try #require(av_mallocz(avcC.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            .assumingMemoryBound(to: UInt8.self)
        extradata.update(from: avcC, count: avcC.count)
        parameters.pointee.extradata = extradata
        parameters.pointee.extradata_size = Int32(avcC.count)
        #expect(demuxer.unitLengthSize(of: parameters) == 2)
        demuxer.isAnnexBStream = true
        #expect(demuxer.unitLengthSize(of: parameters) == 4, "Annex B packets are rewritten with 4-byte lengths")
    }
}
