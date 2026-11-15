import Foundation

/// `X-TIMESTAMP-MAP` of a WebVTT segment (RFC 8216 3.5): the cue time `local` (the file's own) is the MPEG-TS time
/// `mpegts` (90 kHz ticks) of the media it goes with, so a cue at `t` is at `t + mpegts / 90000 - local` on that media's
/// clock. Without the header, as RFC 8216 says, both are zero.
package struct HLSTimestampMap: Sendable, Equatable {
    var mpegts: Int64 = 0
    var local: Double = 0

    /// Seconds to add to a cue's time to put it on the media's clock.
    var shift: Double { Double(mpegts) / 90_000 - local }

    /// The map in the header of a WebVTT file (up to its first blank line); nil when it has none or can't be read.
    package static func parse(webVTT data: Data) -> HLSTimestampMap? {
        // The header is a few lines; a file is read as far as the first cue.
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        let lines = head.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            guard trimmed.hasPrefix("X-TIMESTAMP-MAP=") else { continue }
            return parse(value: trimmed.dropFirst("X-TIMESTAMP-MAP=".count))
        }
        return nil
    }

    package static func parse(value: Substring) -> HLSTimestampMap? {
        var map = HLSTimestampMap()
        var sawMPEGTS = false
        var sawLocal = false
        for part in value.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            switch pair[0].trimmingCharacters(in: .whitespaces) {
            case "MPEGTS":
                guard let ticks = Int64(pair[1].trimmingCharacters(in: .whitespaces)), ticks >= 0,
                    ticks < Int64(1) << 40
                else { return nil }
                map.mpegts = ticks
                sawMPEGTS = true
            case "LOCAL":
                guard let seconds = timestamp(pair[1].trimmingCharacters(in: .whitespaces)) else { return nil }
                map.local = seconds
                sawLocal = true
            default:
                continue
            }
        }
        return sawMPEGTS && sawLocal ? map : nil
    }

    /// `[hh:]mm:ss.mmm`.
    private static func timestamp(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let seconds = Double(parts[parts.count - 1]), let minutes = Double(parts[parts.count - 2]),
            seconds >= 0, minutes >= 0, seconds.isFinite, minutes.isFinite, minutes < 1e9
        else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours, hours >= 0, hours < 1e6 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
