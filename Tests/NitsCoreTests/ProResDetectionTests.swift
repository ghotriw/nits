import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// Not host-dependent: header parsing is pure, and an interlaced stream never opens a VideoToolbox session.
@Suite("Apple ProRes detection")
struct ProResDetectionTests {
    @Test("Interlaced ProRes without a field order in the container goes to FFmpeg, which deinterlaces it")
    func interlacedWithoutFieldOrder() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .proresInterlacedNUT) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))

        #expect(demuxer.codec == .proRes(fourCC: kCMVideoCodecType_AppleProRes422HQ))
        #expect(demuxer.isInterlaced)
        #expect(VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer) is FFmpegVideoDecoder)
    }

    @Test("The frame header says whether a ProRes frame is interlaced")
    func frameHeaderInterlaceMode() {
        func packet(mode: UInt8) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 32)
            bytes.replaceSubrange(4..<8, with: Array("icpf".utf8))
            bytes[20] = 0b1000_0000 | (mode << 2)
            return bytes
        }
        for (mode, expected) in [(0, false), (1, true), (2, true)] as [(UInt8, Bool)] {
            #expect(packet(mode: mode).withUnsafeBytes { ProResFrameHeader.isInterlaced(packet: $0) } == expected)
        }
        #expect([UInt8](repeating: 0, count: 32).withUnsafeBytes { ProResFrameHeader.isInterlaced(packet: $0) } == nil)
    }

}
