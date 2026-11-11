import Foundation

/// Whether the segment being downloaded should be given up for one of a lower variant: it will not arrive before the
/// buffer runs out, and a lower one would. After hls.js's `_abandonRulesCheck`, which this follows (the same terms, each
/// of its checks): the rule behind both a start on a variant too heavy for the link and a drop of the link with a full
/// buffer, which `choose` (a decision between segments) comes to late.
extension AdaptiveBitrateLogic {
    /// What the rule knows of the download under way.
    struct Download: Sendable, Equatable {
        /// The variant being read.
        var variant: Int
        /// Media seconds of the segment.
        var duration: Double
        /// Body bytes received, and the body's length when the server told it.
        var bytes: Int
        var length: Int64?
        /// Seconds since the request was made, until the first answer, and the transfer's running time after it.
        var elapsed: Double
        var firstAnswer: Double?
        var transferring: Double
        /// The bytes of `bytes` that came in `transferring`: the rate is theirs (those of an opening are no measure).
        var measuredBytes: Int
        /// The reader is behind (the download is suspended): its speed says nothing of the link.
        var isSuspended = false
    }

    /// The decision, with the terms it was made from (for the log).
    struct Abandonment: Sendable, Equatable {
        /// The variant to ask the same segment of.
        let target: Int
        /// Seconds the download under way still needs, the buffer's, and the lower segment's.
        let remaining: Double
        let buffer: Double
        let lower: Double
        /// Bits a second the download has brought since its first answer.
        let loadRate: Double?
    }

    /// Never when the download is within a half of the segment's duration (and a round trip: the answer's own wait),
    /// done, suspended or of the lowest variant. `buffer` is the seconds of media left to play before the buffer runs
    /// out; `roundTrip` the answer's wait to expect of a new request (seconds, the download's own when it has none).
    /// `playlistLoad`: seconds a lower variant's playlist takes to load first, when it is not loaded or is live (a live
    /// one is reloaded at a switch); hls.js counts it so.
    func abandonment(
        of download: Download, among variants: [Variant], buffer: Double, roundTrip: Double, playlistLoad: Double = 0
    ) -> Abandonment? {
        if case .abandon(let decision) = evaluation(
            of: download, among: variants, buffer: buffer, roundTrip: roundTrip, playlistLoad: playlistLoad)
        {
            return decision
        }
        return nil
    }

    /// Why a download is kept, for the diagnosis of a check that never gives one up (`NITS_ABR_TRACE`).
    enum Refusal: String, Sendable, Equatable {
        case unknownVariantOrLowest = "variant unknown or the lowest"
        case suspended = "download suspended (reader behind)"
        case finished = "download through"
        case tooEarly = "not past half the duration"
        case noRate = "no rate to decide with"
        case fitsBuffer = "rest fits the buffer"
        case noGain = "no lower segment sooner by the margin"
    }

    enum Evaluation: Sendable, Equatable {
        case abandon(Abandonment)
        case keep(Refusal)
    }

    func evaluation(
        of download: Download, among variants: [Variant], buffer: Double, roundTrip: Double, playlistLoad: Double = 0
    ) -> Evaluation {
        let ladder = variants.sorted { $0.bandwidth < $1.bandwidth }
        guard let position = ladder.firstIndex(where: { $0.id == download.variant }), position > 0,
            download.duration > 0
        else { return .keep(.unknownVariantOrLowest) }
        if download.isSuspended { return .keep(.suspended) }
        if let length = download.length, Int64(download.bytes) >= length { return .keep(.finished) }
        // To keep the decision steady, the segment is watched only past half of its duration.
        guard download.elapsed > max(roundTrip, download.duration / 2) else { return .keep(.tooEarly) }
        let current = ladder[position]
        // The size the server told, else what the variant's bandwidth makes of a segment (hls.js has only that). The
        // bandwidth is a peak: a segment is often far smaller, and the length says so (a 10 Mbit/s rung's 8 s segment of
        // 5.2 MB against 10 MB made the rest of it twice as long).
        let expected: Double
        if let length = download.length, length > 0 {
            expected = max(Double(download.bytes), Double(length))
        } else {
            expected = max(Double(download.bytes), download.duration * Double(current.bandwidth) / 8)
        }
        // The rate of what came since the first answer; the estimate when nothing has.
        var streaming = download.firstAnswer.map {
            download.transferring > 0 ? download.transferring : download.elapsed - $0
        }
        var loadRate: Double?
        if download.firstAnswer != nil, download.measuredBytes > 0 {
            // A transfer of under a second says little: no faster than the estimate would carry it.
            if let seconds = streaming, seconds < 1, let estimate {
                streaming = min(download.elapsed, Double(download.measuredBytes) * 8 / estimate)
            }
            if let seconds = streaming, seconds > 0 { loadRate = Double(download.measuredBytes) / seconds * 8 }
        }
        guard let rate = loadRate ?? estimate, rate > 0 else { return .keep(.noRate) }
        let remaining =
            loadRate != nil ? (expected - Double(download.bytes)) * 8 / rate : expected * 8 / rate + roundTrip
        // Only when the rest of the segment takes longer than what is left to play.
        guard remaining > buffer else { return .keep(.fitsBuffer) }
        // A lower segment must come sooner than finishing by a margin, or giving up buys nothing and costs the bytes
        // loaded (hls.js has none: 930 KB thrown away for 0.5 s, and the stall not avoided).
        let margin = max(Self.abandonMargin, download.duration * Self.abandonMarginShare)
        let times = ladder[..<position].map {
            roundTrip + playlistLoad + download.duration * Double($0.bandwidth) / rate
        }
        // The highest lower variant that arrives within the buffer (or a segment's duration and the round trip); when none
        // does, the lowest, as hls.js does. With nothing buffered each second the lower segment loads is a second of
        // stall, so a higher rung that merely beats the download under way stalls longer (2.9 Mbit/s, 8 s segments: the
        // 2.7 Mbit/s rung 7.8 s against the lowest's 1.8 s) and, over the link, goes down again at the next segment.
        // Either must also come sooner than finishing by the margin.
        let deadline = min(buffer, download.duration + roundTrip)
        let sooner = remaining - margin
        let reachable = (0..<position).last { times[$0] < min(deadline, sooner) } ?? (times[0] < sooner ? 0 : nil)
        guard let index = reachable, times[index] <= download.duration * 10 else { return .keep(.noGain) }
        let target = ladder[index]
        let lower = times[index]
        return .abandon(
            Abandonment(target: target.id, remaining: remaining, buffer: buffer, lower: lower, loadRate: loadRate))
    }
}

extension AdaptiveBitrateLogic {
    /// Seconds, or this share of the segment's duration, by which the lower segment must come sooner than the rest of
    /// the download under way (the larger of the two).
    static let abandonMargin = 1.0
    static let abandonMarginShare = 0.15
}
