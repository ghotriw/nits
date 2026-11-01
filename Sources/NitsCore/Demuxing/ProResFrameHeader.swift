import Foundation

/// The few fields of an Apple ProRes frame header (SMPTE RDD 36) the demuxer reads from a packet.
enum ProResFrameHeader {
    /// Whether the frame codes two fields (`interlace_mode` 1 or 2), read from the header of a packet; `nil` when
    /// the packet isn't a ProRes frame. Containers without a `fiel` atom (NUT, bare streams) leave the stream's
    /// field order unknown, and FFmpeg flags interlaced pictures per frame only.
    ///
    /// Layout: frame size (4), `icpf` (4), then the header: size (2), version (2), creator (4), width (2),
    /// height (2), and a byte with the chroma format in bits 6–7 and the interlace mode in bits 2–3.
    static func isInterlaced(packet: UnsafeRawBufferPointer) -> Bool? {
        guard packet.count > 20, packet[4] == 0x69, packet[5] == 0x63, packet[6] == 0x70, packet[7] == 0x66
        else { return nil }
        let mode = (packet[20] >> 2) & 0x3
        return mode == 1 || mode == 2
    }
}
