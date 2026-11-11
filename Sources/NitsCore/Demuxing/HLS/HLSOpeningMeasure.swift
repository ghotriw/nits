import Foundation

/// The log lines that split an HLS stream's opening, and each run's, into their steps: the measurement suites
/// (`HLSOpeningMeasurement`) read them back from `LogStore`. One line for the opening, at its end (`opening`), and one
/// for each run of segments: a probe of the opening once it is analysed, a run read once its first packet is placed.
enum HLSOpeningMeasure {
    /// The opening of the input: playlists, probes, and the whole (`HLSInput.init`). Info.
    static let opening = "HLS opening:"
    /// A run of segments opened, with its steps (`HLSSegmentReader.OpenTiming`). Debug.
    static let run = "HLS run:"

    static func ms(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded()))ms"
    }
}
