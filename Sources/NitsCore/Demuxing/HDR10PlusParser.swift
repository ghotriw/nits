import CFFmpeg
import Foundation

/// Reads HDR10+ metadata: the ITU-T T.35 message of the HDR10+ provider (country 0xB5, provider 0x003C, oriented code
/// 0x0001, application 4), decoded by FFmpeg's `av_dynamic_hdr_plus_from_t35`. HEVC carries it in a prefix SEI NAL unit
/// (type 39, payload type 4), AV1 in a metadata OBU (`METADATA_TYPE_ITUT_T35`).
enum HDR10PlusParser {
    /// The HDR10+ metadata of an AV1 packet (a temporal unit of OBUs, low overhead bitstream format), nil without.
    static func parse(av1Packet bytes: UnsafePointer<UInt8>, count: Int) -> HDR10PlusFrameMetadata? {
        var offset = 0
        while offset < count {
            // obu_header(): forbidden bit, obu_type (4), extension flag, has_size_field, reserved bit.
            let header = bytes[offset]
            offset += header & 0x04 != 0 ? 2 : 1
            var size = count - offset
            if header & 0x02 != 0 {
                guard let obuSize = readLEB128(bytes, count: count, &offset) else { return nil }
                size = obuSize
            }
            guard offset <= count, size <= count - offset else { return nil }
            // A metadata OBU (type 5) of metadata_type 4: the T.35 message, then trailing bits.
            if (header >> 3) & 0x0F == 5 {
                var payload = offset
                if readLEB128(bytes, count: offset + size, &payload) == 4,
                    let metadata = parseT35(
                        Array(UnsafeBufferPointer(start: bytes + payload, count: offset + size - payload))[...])
                {
                    return metadata
                }
            }
            offset += size
        }
        return nil
    }

    /// An unsigned LEB128 value, as AV1 codes sizes, read up to `count`.
    private static func readLEB128(_ bytes: UnsafePointer<UInt8>, count: Int, _ offset: inout Int) -> Int? {
        var value = 0
        for index in 0..<8 {
            guard offset < count else { return nil }
            let byte = bytes[offset]
            offset += 1
            value |= Int(byte & 0x7F) << (7 * index)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    /// The scene luminance of the first processing window (the whole picture), nil without an HDR10+ message or with
    /// no peak in it.
    static func parse(seiNALU: Data) -> HDR10PlusFrameMetadata? {
        guard seiNALU.count > 2 else { return nil }
        // RBSP after the two-byte NAL unit header.
        let rbsp = DolbyVisionRPUParser.unescapeRPU(from: seiNALU.dropFirst(2))
        var offset = 0
        // sei_message()s, up to the trailing bits.
        while offset + 2 <= rbsp.count {
            guard let payloadType = readSEIValue(rbsp, &offset), let payloadSize = readSEIValue(rbsp, &offset),
                offset + payloadSize <= rbsp.count
            else { return nil }
            if payloadType == 4,
                let metadata = parseT35(rbsp[offset..<(offset + payloadSize)])
            {
                return metadata
            }
            offset += payloadSize
            if offset < rbsp.count, rbsp[offset] == 0x80 { break }
        }
        return nil
    }

    /// A payload type or size: 0xFF bytes add 255 each, the last byte the rest.
    private static func readSEIValue(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
        var value = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            value += Int(byte)
            if byte != 0xFF { return value }
        }
        return nil
    }

    private static func parseT35(_ payload: ArraySlice<UInt8>) -> HDR10PlusFrameMetadata? {
        let bytes = Array(payload)
        // itu_t_t35_country_code, terminal_provider_code, terminal_provider_oriented_code, application_identifier.
        guard bytes.count > 6, bytes[0] == 0xB5, bytes[1] == 0x00, bytes[2] == 0x3C, bytes[3] == 0x00,
            bytes[4] == 0x01, bytes[5] == 4
        else { return nil }

        var size = 0
        guard let plus = av_dynamic_hdr_plus_alloc(&size) else { return nil }
        defer { av_free(plus) }
        let status = bytes.withUnsafeBufferPointer {
            av_dynamic_hdr_plus_from_t35(plus, $0.baseAddress! + 6, $0.count - 6)
        }
        guard status >= 0, plus.pointee.num_windows >= 1 else { return nil }

        let window = plus.pointee.params.0
        // Linear values in [0, 1] of 10 000 nits.
        let maxscl = [window.maxscl.0, window.maxscl.1, window.maxscl.2].map { Float(av_q2d($0)) }.max() ?? 0
        guard maxscl > 0 else { return nil }
        return HDR10PlusFrameMetadata(
            maxNits: maxscl * 10000, averageNits: Float(av_q2d(window.average_maxrgb)) * 10000)
    }
}
