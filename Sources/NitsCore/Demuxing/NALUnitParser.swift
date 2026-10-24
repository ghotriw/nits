import Foundation

/// Annex B / length-prefixed (avcC, hvcC) NAL unit utilities for H.264 and HEVC bitstreams.
enum NALUnitParser {
    /// Parses NAL units from either Annex B byte stream (0x000001 or 0x00000001 start codes)
    /// or MP4/hvcC format (4-byte big endian length prefixed).
    static func extractNALUnits(from data: Data, isAnnexB: Bool? = nil) -> [Data] {
        guard data.count >= 4 else { return [] }

        let bytes = [UInt8](data)
        let count = bytes.count

        // If format is explicitly known, use it; otherwise inspect start code
        let annexB: Bool
        if let isAnnexB {
            annexB = isAnnexB
        } else {
            annexB =
                (bytes[0] == 0 && bytes[1] == 0 && (bytes[2] == 1 || (count > 3 && bytes[2] == 0 && bytes[3] == 1)))
        }

        if annexB {
            var nalus: [Data] = []
            var starts: [(offset: Int, prefixLen: Int)] = []

            var i = 0
            while i + 2 < count {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 {
                        starts.append((offset: i, prefixLen: 3))
                        i += 3
                        continue
                    } else if i + 3 < count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                        starts.append((offset: i, prefixLen: 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }

            for (idx, start) in starts.enumerated() {
                let nalStart = start.offset + start.prefixLen
                let nalEnd = (idx + 1 < starts.count) ? starts[idx + 1].offset : count
                if nalEnd > nalStart {
                    nalus.append(data.subdata(in: nalStart..<nalEnd))
                }
            }
            return nalus
        } else {
            // Standard MP4 length-prefixed format
            var nalus: [Data] = []
            var offset = 0
            while offset + 4 <= count {
                let naluLen =
                    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                    | Int(bytes[offset + 3])
                offset += 4
                guard naluLen > 0, offset + naluLen <= count else { break }
                nalus.append(data.subdata(in: offset..<(offset + naluLen)))
                offset += naluLen
            }
            return nalus
        }
    }

    /// Calls `body` with the type and bytes (header included) of each HEVC NAL unit of a packet, without copying,
    /// until it returns false.
    static func forEachHEVCNALUnit(
        bytes: UnsafePointer<UInt8>, count: Int, isAnnexB: Bool,
        _ body: (UInt8, UnsafeBufferPointer<UInt8>) -> Bool
    ) {
        guard count >= 5 else { return }
        if isAnnexB {
            var i = 0
            while i + 4 < count {
                let prefixLen: Int
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 {
                        prefixLen = 3
                    } else if bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                        prefixLen = 4
                    } else {
                        i += 1
                        continue
                    }
                } else {
                    i += 1
                    continue
                }

                let nalStart = i + prefixLen
                guard nalStart < count else { break }
                // The unit ends at the next start code or the end of the packet.
                var next = nalStart + 1
                while next + 2 < count {
                    if bytes[next] == 0 && bytes[next + 1] == 0
                        && (bytes[next + 2] == 1 || (next + 3 < count && bytes[next + 2] == 0 && bytes[next + 3] == 1))
                    {
                        break
                    }
                    next += 1
                }
                let nalEnd = (next + 2 < count) ? next : count
                let nalType = (bytes[nalStart] >> 1) & 0x3F
                guard body(nalType, UnsafeBufferPointer(start: bytes + nalStart, count: nalEnd - nalStart)) else {
                    return
                }
                i = nalEnd
            }
        } else {
            var offset = 0
            while offset + 4 <= count {
                let naluLen =
                    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                    | Int(bytes[offset + 3])
                offset += 4
                guard naluLen > 0, offset + naluLen <= count else { break }
                let nalType = (bytes[offset] >> 1) & 0x3F
                guard body(nalType, UnsafeBufferPointer(start: bytes + offset, count: naluLen)) else { return }
                offset += naluLen
            }
        }
    }

    /// Converts an input packet to HVCC format expected by VideoToolbox (4-byte length prefix).
    /// If packet is already in length-prefixed format, it returns the raw packet bytes directly.
    static func packetDataToHVCC(pktData: UnsafePointer<UInt8>?, count: Int, isAnnexBStream: Bool = false) -> (
        Data, Int
    ) {
        guard let pktData, count >= 4 else {
            return (Data(), 0)
        }

        // Only treat as Annex B if either the stream is known to be Annex B,
        // or the packet starts with Annex B and cannot be a 4-byte length prefix.
        let isAnnexB: Bool
        if isAnnexBStream {
            isAnnexB =
                (pktData[0] == 0 && pktData[1] == 0
                    && (pktData[2] == 1 || (count > 3 && pktData[2] == 0 && pktData[3] == 1)))
        } else {
            // For container streams (MP4/MKV), packets are length-prefixed (avcC/hvcC format).
            // A packet starting with 0x00 0x00 0x01 ... has a 4-byte length between 65536 and 131071.
            // Do NOT re-parse as Annex B unless the stream format is Annex B!
            isAnnexB = false
        }

        if !isAnnexB {
            let data = Data(bytes: pktData, count: count)
            return (data, count)
        }

        // Convert Annex B to 4-byte length prefix
        var starts: [(offset: Int, prefixLen: Int)] = []
        var i = 0
        while i + 2 < count {
            if pktData[i] == 0 && pktData[i + 1] == 0 {
                if pktData[i + 2] == 1 {
                    starts.append((offset: i, prefixLen: 3))
                    i += 3
                    continue
                } else if i + 3 < count && pktData[i + 2] == 0 && pktData[i + 3] == 1 {
                    starts.append((offset: i, prefixLen: 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        var hvccData = Data()
        hvccData.reserveCapacity(count + 32)

        for (idx, start) in starts.enumerated() {
            let nalStart = start.offset + start.prefixLen
            let nalEnd = (idx + 1 < starts.count) ? starts[idx + 1].offset : count
            let nalSize = nalEnd - nalStart
            guard nalSize > 0 else { continue }

            var bigEndianLength = UInt32(nalSize).bigEndian
            withUnsafeBytes(of: &bigEndianLength) { lenBytes in
                hvccData.append(contentsOf: lenBytes)
            }
            let nalPtr = pktData.advanced(by: nalStart)
            hvccData.append(nalPtr, count: nalSize)
        }

        let finalCount = hvccData.count
        return (hvccData, finalCount)
    }
}
