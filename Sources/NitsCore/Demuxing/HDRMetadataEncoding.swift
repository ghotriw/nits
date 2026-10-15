import CFFmpeg
import Foundation

/// Packs FFmpeg's HDR stream side data into the byte layouts CoreVideo and VideoToolbox expect.
enum HDRMetadataEncoding {
    /// 24-byte mastering display colour volume (SEI 137 layout, as `kCVImageBufferMasteringDisplayColorVolumeKey`
    /// expects): primaries and white point in 0.00002 units, luminance in 0.0001 cd/m².
    static func masteringDisplayColourVolume(_ mdm: AVMasteringDisplayMetadata) -> Data {
        var mdBytes = [UInt8](repeating: 0, count: 24)
        let rx = UInt16(
            clamping: Int(mdm.display_primaries.0.0.num) * 50000
                / Int(max(1, mdm.display_primaries.0.0.den)))
        let ry = UInt16(
            clamping: Int(mdm.display_primaries.0.1.num) * 50000
                / Int(max(1, mdm.display_primaries.0.1.den)))
        let gx = UInt16(
            clamping: Int(mdm.display_primaries.1.0.num) * 50000
                / Int(max(1, mdm.display_primaries.1.0.den)))
        let gy = UInt16(
            clamping: Int(mdm.display_primaries.1.1.num) * 50000
                / Int(max(1, mdm.display_primaries.1.1.den)))
        let bx = UInt16(
            clamping: Int(mdm.display_primaries.2.0.num) * 50000
                / Int(max(1, mdm.display_primaries.2.0.den)))
        let by = UInt16(
            clamping: Int(mdm.display_primaries.2.1.num) * 50000
                / Int(max(1, mdm.display_primaries.2.1.den)))
        let wx = UInt16(
            clamping: Int(mdm.white_point.0.num) * 50000
                / Int(max(1, mdm.white_point.0.den)))
        let wy = UInt16(
            clamping: Int(mdm.white_point.1.num) * 50000
                / Int(max(1, mdm.white_point.1.den)))
        let maxL = UInt32(
            clamping: Int64(mdm.max_luminance.num) * 10000
                / Int64(max(1, mdm.max_luminance.den)))
        let minL = UInt32(
            clamping: Int64(mdm.min_luminance.num) * 10000
                / Int64(max(1, mdm.min_luminance.den)))
        mdBytes[0] = UInt8(rx >> 8)
        mdBytes[1] = UInt8(rx & 0xFF)
        mdBytes[2] = UInt8(ry >> 8)
        mdBytes[3] = UInt8(ry & 0xFF)
        mdBytes[4] = UInt8(gx >> 8)
        mdBytes[5] = UInt8(gx & 0xFF)
        mdBytes[6] = UInt8(gy >> 8)
        mdBytes[7] = UInt8(gy & 0xFF)
        mdBytes[8] = UInt8(bx >> 8)
        mdBytes[9] = UInt8(bx & 0xFF)
        mdBytes[10] = UInt8(by >> 8)
        mdBytes[11] = UInt8(by & 0xFF)
        mdBytes[12] = UInt8(wx >> 8)
        mdBytes[13] = UInt8(wx & 0xFF)
        mdBytes[14] = UInt8(wy >> 8)
        mdBytes[15] = UInt8(wy & 0xFF)
        mdBytes[16] = UInt8((maxL >> 24) & 0xFF)
        mdBytes[17] = UInt8((maxL >> 16) & 0xFF)
        mdBytes[18] = UInt8((maxL >> 8) & 0xFF)
        mdBytes[19] = UInt8(maxL & 0xFF)
        mdBytes[20] = UInt8((minL >> 24) & 0xFF)
        mdBytes[21] = UInt8((minL >> 16) & 0xFF)
        mdBytes[22] = UInt8((minL >> 8) & 0xFF)
        mdBytes[23] = UInt8(minL & 0xFF)
        return Data(mdBytes)
    }

    /// 4-byte content light level info (SEI 144 layout): MaxCLL then MaxFALL, big endian.
    static func contentLightLevelInfo(_ clm: AVContentLightMetadata) -> Data {
        var cllBytes = [UInt8](repeating: 0, count: 4)
        cllBytes[0] = UInt8((clm.MaxCLL >> 8) & 0xFF)
        cllBytes[1] = UInt8(clm.MaxCLL & 0xFF)
        cllBytes[2] = UInt8((clm.MaxFALL >> 8) & 0xFF)
        cllBytes[3] = UInt8(clm.MaxFALL & 0xFF)
        return Data(cllBytes)
    }

    /// Standard 24-byte Dolby Vision configuration box payload (dvcC / dvvC, ISO/IEC 14496-15) rebuilt from
    /// FFmpeg's decoder configuration record.
    static func dolbyVisionConfigurationBox(_ doviConf: AVDOVIDecoderConfigurationRecord) -> Data {
        var boxPayload = [UInt8](repeating: 0, count: 24)
        boxPayload[0] = doviConf.dv_version_major
        boxPayload[1] = doviConf.dv_version_minor
        let p = doviConf.dv_profile
        let l = doviConf.dv_level
        let rpu = doviConf.rpu_present_flag & 0x01
        let el = doviConf.el_present_flag & 0x01
        let bl = doviConf.bl_present_flag & 0x01
        let compatId = Int(doviConf.dv_bl_signal_compatibility_id & 0x0F)
        boxPayload[2] = ((p & 0x7F) << 1) | ((l >> 5) & 0x01)
        boxPayload[3] = ((l & 0x1F) << 3) | (rpu << 2) | (el << 1) | bl
        boxPayload[4] = UInt8(compatId << 4)
        return Data(boxPayload)
    }

    /// Parses an ISOBMFF dvcC/dvvC Dolby Vision configuration box from extradata.
    static func parseDolbyVisionConfigurationBox(from data: Data) -> (
        profile: Int, compatibilityId: Int, configData: Data
    )? {
        guard data.count >= 24 else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            for k in 0..<(count - 8) {
                let isDvcC = (bytes[k] == 0x64 && bytes[k + 1] == 0x76 && bytes[k + 2] == 0x63 && bytes[k + 3] == 0x43)
                let isDvvC = (bytes[k] == 0x64 && bytes[k + 1] == 0x76 && bytes[k + 2] == 0x76 && bytes[k + 3] == 0x43)
                if isDvcC || isDvvC {
                    let dvProfile = Int((bytes[k + 6] >> 1) & 0x7F)
                    let compatId = Int((bytes[k + 8] >> 4) & 0x0F)
                    let boxPayloadStart = k + 4
                    guard count - boxPayloadStart >= 24 else { return nil }
                    let configData = Data(bytes[boxPayloadStart..<(boxPayloadStart + 24)])
                    return (profile: dvProfile, compatibilityId: compatId, configData: configData)
                }
            }
            return nil
        }
    }
}
