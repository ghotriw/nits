import CFFmpeg
import Foundation
import Testing

@testable import NitsCore

@Suite("HDR10+ metadata")
struct HDR10PlusTests {
    /// The ITU-T T.35 message of HDR10+ for a scene peaking at `maxscl` (linear, of 10 000 nits, R G B) with
    /// `averageMaxRGB`, serialized by FFmpeg.
    static func t35Message(maxscl: (Int32, Int32, Int32), averageMaxRGB: Int32) throws -> [UInt8] {
        var allocated = 0
        let plus = try #require(av_dynamic_hdr_plus_alloc(&allocated))
        defer { av_free(plus) }
        plus.pointee.application_version = 1
        plus.pointee.num_windows = 1
        plus.pointee.targeted_system_display_maximum_luminance = AVRational(num: 500, den: 1)
        plus.pointee.params.0.maxscl = (
            AVRational(num: maxscl.0, den: 100000), AVRational(num: maxscl.1, den: 100000),
            AVRational(num: maxscl.2, den: 100000)
        )
        plus.pointee.params.0.average_maxrgb = AVRational(num: averageMaxRGB, den: 100000)
        plus.pointee.params.0.fraction_bright_pixels = AVRational(num: 0, den: 1000)
        var data: UnsafeMutablePointer<UInt8>?
        var size = 0
        #expect(av_dynamic_hdr_plus_to_t35(plus, &data, &size) >= 0)
        let serialized = try #require(data)
        defer { av_free(serialized) }

        // Country code, provider code, provider oriented code, application identifier, then FFmpeg's bytes.
        return [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04] + Array(UnsafeBufferPointer(start: serialized, count: size))
    }

    /// An HEVC prefix SEI NAL unit (type 39) carrying the HDR10+ message, after a mastering display SEI message as
    /// encoders write them.
    static func seiNALU(maxscl: (Int32, Int32, Int32), averageMaxRGB: Int32) throws -> [UInt8] {
        let t35 = try t35Message(maxscl: maxscl, averageMaxRGB: averageMaxRGB)
        var rbsp: [UInt8] = [137, 24] + [UInt8](repeating: 0, count: 24)  // mastering_display_colour_volume
        rbsp += [4] + sizeBytes(t35.count) + t35 + [0x80]
        // NAL unit header (type 39), then the RBSP with emulation prevention.
        var nalu: [UInt8] = [39 << 1, 1]
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte <= 3 {
                nalu.append(3)
                zeros = 0
            }
            nalu.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return nalu
    }

    private static func sizeBytes(_ size: Int) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: size / 255) + [UInt8(size % 255)]
    }

    @Test("The parser reads the scene peak and average of an HDR10+ SEI in a packet")
    func parsesSEI() throws {
        let nalu = try Self.seiNALU(maxscl: (4052, 1650, 808), averageMaxRGB: 374)
        // An Annex B packet: the SEI, then a slice.
        let packet: [UInt8] = [0, 0, 0, 1] + nalu + [0, 0, 0, 1, 1 << 1, 1, 0xAF, 0x10, 0x20]
        var units: [(type: UInt8, data: Data)] = []
        packet.withUnsafeBufferPointer {
            NALUnitParser.forEachHEVCNALUnit(bytes: $0.baseAddress!, count: $0.count, isAnnexB: true) { type, nalu in
                units.append((type, Data(nalu)))
                return true
            }
        }
        #expect(units.map(\.type) == [39, 1])
        let metadata = try #require(HDR10PlusParser.parse(seiNALU: units[0].data))
        #expect(abs(metadata.maxNits - 405.2) < 0.1)
        #expect(abs(metadata.averageNits - 37.4) < 0.1)
    }

    @Test("The parser reads HDR10+ from the metadata OBU of an AV1 temporal unit")
    func parsesAV1MetadataOBU() throws {
        let t35 = try Self.t35Message(maxscl: (4052, 1650, 808), averageMaxRGB: 374)
        // metadata_type 4 (ITU-T T.35), the message, trailing bits; its size as LEB128.
        let payload: [UInt8] = [4] + t35 + [0x80]
        let size: [UInt8] =
            payload.count < 128
            ? [UInt8(payload.count)] : [UInt8(payload.count & 0x7F | 0x80), UInt8(payload.count >> 7)]
        // Temporal delimiter (type 2), the metadata OBU (type 5), a frame OBU (type 6), each with a size field.
        let packet: [UInt8] = [2 << 3 | 0x02, 0] + [5 << 3 | 0x02] + size + payload + [6 << 3 | 0x02, 2, 0x10, 0x20]
        let metadata = try #require(
            packet.withUnsafeBufferPointer { HDR10PlusParser.parse(av1Packet: $0.baseAddress!, count: $0.count) })
        #expect(abs(metadata.maxNits - 405.2) < 0.1)
        #expect(abs(metadata.averageNits - 37.4) < 0.1)

        // Without the metadata OBU: none.
        let frameOnly: [UInt8] = [2 << 3 | 0x02, 0, 6 << 3 | 0x02, 2, 0x10, 0x20]
        #expect(
            frameOnly.withUnsafeBufferPointer { HDR10PlusParser.parse(av1Packet: $0.baseAddress!, count: $0.count) }
                == nil)
    }

    @Test("An SEI without an HDR10+ message gives none")
    func ignoresOtherSEI() {
        let mastering: [UInt8] = [39 << 1, 1, 137, 24] + [UInt8](repeating: 1, count: 24) + [0x80]
        #expect(HDR10PlusParser.parse(seiNALU: Data(mastering)) == nil)
    }

    @Test("HDR10+ moves the curve's peak and the reference white with the scene, as is, and the mode shows it")
    @MainActor
    func toneMapsWithSceneLuminance() {
        let toneMapping = ToneMapController(renderer: nil, monitor: PlayerPerformanceMonitor())
        toneMapping.adapt(toPeakNits: 1375, fallNits: 188, hasStaticPeak: true)
        func frame(maxNits: Float) -> FrameHDRMetadata {
            FrameHDRMetadata(hdr10Plus: HDR10PlusFrameMetadata(maxNits: maxNits, averageNits: 10))
        }

        // A bright scene keeps the static white; a night scene fitting under 100 nits takes white 100 at once.
        let mode = toneMapping.applyFrame(hdrMetadata: frame(maxNits: 405))
        #expect(mode == ToneMapController.Mode(usesHDR10Plus: true))
        #expect(toneMapping.frameState.withLock { ($0.smoothedPeakNits, $0.targetNits) } == (405, 203))
        _ = toneMapping.applyFrame(hdrMetadata: frame(maxNits: 90))
        #expect(toneMapping.frameState.withLock { ($0.smoothedPeakNits, $0.targetNits) } == (90, 100))

        // A change of a quarter or less is per-frame metadata within the scene: smoothed, not taken as is.
        _ = toneMapping.applyFrame(hdrMetadata: frame(maxNits: 100))
        #expect(abs(toneMapping.frameState.withLock { $0.smoothedPeakNits } - 91.5) < 0.01)
        _ = toneMapping.applyFrame(hdrMetadata: frame(maxNits: 90))

        // A frame without metadata holds the scene's values.
        #expect(toneMapping.applyFrame(hdrMetadata: nil) == ToneMapController.Mode(usesHDR10Plus: true))
        #expect(abs(toneMapping.frameState.withLock { $0.targetNits } - 100) < 0.01)
    }

    @Test("The white the UI shows follows the scene's, not the static one")
    @MainActor
    func appliedTargetNitsFollowsScene() async {
        let toneMapping = ToneMapController(renderer: nil, monitor: PlayerPerformanceMonitor())
        toneMapping.adapt(toPeakNits: 1375, fallNits: 188, hasStaticPeak: true)
        _ = toneMapping.applyFrame(
            hdrMetadata: FrameHDRMetadata(hdr10Plus: HDR10PlusFrameMetadata(maxNits: 90, averageNits: 2)))
        // Set on the main actor after the display link's frame.
        for _ in 0..<100 where toneMapping.appliedTargetNits != 100 { await Task.yield() }
        #expect(toneMapping.appliedTargetNits == 100)
        #expect(toneMapping.targetNits == 203)
    }

    @Test("A Dolby Vision RPU without L1 leaves the scene to HDR10+, and the mode says so")
    @MainActor
    func dolbyVisionWithoutL1UsesHDR10Plus() {
        let toneMapping = ToneMapController(renderer: nil, monitor: PlayerPerformanceMonitor())
        toneMapping.adapt(toPeakNits: 1000, fallNits: 0, hasStaticPeak: true)
        let mode = toneMapping.applyFrame(
            hdrMetadata: FrameHDRMetadata(
                dolbyVision: DolbyVisionFrameMetadata(sceneRefresh: false, l1: nil, l2Trims: []),
                hdr10Plus: HDR10PlusFrameMetadata(maxNits: 400, averageNits: 10)))
        #expect(mode == ToneMapController.Mode(usesHDR10Plus: true))
        #expect(mode.name == "Metal SDR (HDR10+)")
        #expect(toneMapping.frameState.withLock { $0.smoothedPeakNits } == 400)
    }
}
