import Foundation
import NitsCore

extension MediaDemuxer.AudioTrack {
    /// The sample rate in kHz, whole ones without a fraction: "48 kHz", "44.1 kHz".
    var sampleRateText: String {
        let kHz = Double(sampleRate) / 1000.0
        let number =
            kHz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)
        return "\(number) kHz"
    }

    /// Codec, sample rate and channels in one line: "AAC • 48 kHz • 2 ch".
    var formatSummary: String {
        "\(codecName.uppercased()) • \(sampleRateText) • \(channels) ch"
    }
}
