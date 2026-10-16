import CoreMedia
import Foundation

/// Timing of field-rate deinterlacing, which turns each interlaced frame into one progressive frame per field.
enum FieldTiming {
    /// Interlaced formats top out at 30 frames (60 fields) a second, so anything shorter than this is already a
    /// field: streams that timestamp each field separately (PAFF in MPEG-TS) report field durations and rates.
    static let shortestFrameDuration = 0.025

    /// The presentation interval of one field of interlaced content whose nominal frame duration is `seconds`.
    static func fieldDuration(ofFrameDuration seconds: Double) -> Double {
        seconds < shortestFrameDuration ? seconds : seconds / 2
    }

    /// How long each of the two progressive frames made from an interlaced frame lasting `duration` is shown: the
    /// first for one field, the second for the rest of the frame. `repeatedFields` is FFmpeg's `repeat_pict`
    /// (soft telecine shows a field a third time). `nil` without a usable duration.
    static func durations(ofFrame duration: CMTime, repeatedFields: Int) -> (first: CMTime, second: CMTime)? {
        guard duration.isNumeric, duration.value > 0 else { return nil }
        if duration.seconds < shortestFrameDuration {
            return (duration, duration)
        }
        let fieldCount = 2 + max(0, min(repeatedFields, 2))
        let field = CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: Int32(fieldCount))
        return (field, duration - field)
    }
}
