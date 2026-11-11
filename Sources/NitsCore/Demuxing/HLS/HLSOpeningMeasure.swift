import Foundation

/// The log lines that split an HLS stream's opening, and each run's, into their steps: the measurement suites
/// (`HLSOpeningMeasurement`) read them back from `LogStore`. One line for the opening, at its end (`opening`), and one
/// for each run of segments: a probe of the opening once it is analysed, a run read once its first packet is placed.
enum HLSOpeningMeasure {
    /// The opening of the input: playlists, probes, and the whole (`HLSInput.init`). Info.
    static let opening = "HLS opening:"
    /// A run of segments opened, with its steps (`HLSSegmentReader.OpenTiming`). Debug.
    static let run = "HLS run:"
    /// What the opening's probes brought, at the points its rate could be read at
    /// (`HTTPSessionInput.OpeningLimit.rateReport`), and whether the top rung alone was probed. Info.
    static let rate = "HLS opening rate:"

    /// Temporary, for the measurement of candidate 2's first step (`.agents/hls-client/PLAN.md`): with
    /// `NITS_HLS_PROBE_TOP_ONLY=1` the opening probes the top rung and its renditions only and plays nothing else.
    static let probesTopOnly = ProcessInfo.processInfo.environment["NITS_HLS_PROBE_TOP_ONLY"] == "1"

    static func ms(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded()))ms"
    }
}
