import Foundation
import Testing

@testable import NitsCore
@testable import NitsStreaming

/// Measurement (skipped unless asked for, see README.md): what a reload of a long live window costs, a day of 5 s
/// segments (YouTube's live history as a live playlist, `.agents/dash-client/PLAN.md` D7): a source building the
/// playlist's segments (with an address each, or one shared), and `HLSTimeline.reload` merging it. Each lane (picture,
/// sound) does both every segment's length.
@Suite("Live window cost measurement")
struct LiveWindowCostMeasurement {
    static let base = "https://live.nits.invalid/137?sq="
    static let shared = URL(string: "https://live.nits.invalid/137")!

    /// The window `first..<first + count`, every segment 5 s; `addressed`: each with an address of its own.
    static func playlist(first: Int, count: Int, addressed: Bool) -> HLSMediaPlaylist {
        var playlist = HLSMediaPlaylist(targetDuration: 5)
        playlist.mediaSequence = first
        playlist.segments.reserveCapacity(count)
        for number in first..<(first + count) {
            let url = addressed ? URL(string: base + String(number))! : shared
            playlist.segments.append(
                HLSSegment(url: url, duration: 5, sequence: number, discontinuitySequence: 0))
        }
        return playlist
    }

    static func ms(_ duration: Duration) -> String {
        String(
            format: "%.2f",
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }

    @Test(
        "A reload of a day of segments",
        .enabled(if: ProcessInfo.processInfo.environment["NITS_MEASURE_LIVE_WINDOW"] != nil))
    func reload() {
        let count = Int(ProcessInfo.processInfo.environment["NITS_MEASURE_LIVE_WINDOW_SEGMENTS"] ?? "") ?? 17_280
        let rounds = 20
        let clock = ContinuousClock()
        for addressed in [true, false] {
            var timeline = HLSTimeline(Self.playlist(first: 1000, count: count, addressed: addressed))
            var build = Duration.zero
            var merge = Duration.zero
            var worst = Duration.zero
            for round in 1...rounds {
                // The window slides by one: one segment expires, one is added.
                var playlist: HLSMediaPlaylist!
                build += clock.measure {
                    playlist = Self.playlist(first: 1000 + round, count: count, addressed: addressed)
                }
                var change: HLSTimeline.ReloadChange!
                let took = clock.measure { change = timeline.reload(playlist) }
                merge += took
                worst = max(worst, took)
                #expect(change == .updated(added: 1, expired: 1))
            }
            print(
                "MEASURE liveWindow segments=\(count) addresses=\(addressed ? "each" : "shared") "
                    + "build=\(Self.ms(build / rounds))ms merge=\(Self.ms(merge / rounds))ms "
                    + "mergeWorst=\(Self.ms(worst))ms (per reload, per lane)")
        }
    }
}
