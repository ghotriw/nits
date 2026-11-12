import Foundation

/// Chooses the HLS variant to read next from the network throughput and the read-ahead (seconds of media read past
/// the packets taken). Pure: the demuxer feeds it samples and times (`MediaDemuxer+AdaptiveBitrate.swift`).
///
/// Throughput is an exponentially weighted average over two half-lives, the lower of the two counting (as dash.js and
/// GStreamer do: quick to fall, slow to rise). A sample weighs its media (`addSample`). It leaves out the requests'
/// latency, which is measured apart, as seconds per second of media (`latencyShare`): a variant is kept when reading a
/// second of it, its transfer at the throughput and its share of latency, takes at most `safety` of a second, and
/// stepped up to when at most `upSafety`, as hls.js keeps and steps up (0.95 and 0.7).
/// - **Down**: when the current variant doesn't fit and the read-ahead is below `highBuffer`, to the highest variant
///   that fits. The read-ahead is low after every start and seek too, while it fills: that alone is no reason.
/// - **Up** on a recent estimate: from `estimateUpBuffer` of read-ahead and `downSwitchInterval` after the last
///   switch, to the highest variant the estimate fits with `upSafety`, as ExoPlayer (10 s buffered, 0.7 of the
///   estimate) and hls.js (0.7) step up. The margin below `safety` keeps a variant stepped up to from being one that
///   doesn't fit at once. Waiting for a full read-ahead and `upSwitchInterval` too, a start on a cold CDN cache (Apple's
///   AV1 example at 184 ms of round trip: answers after 0.7 s, 300 ms of them a second of media) that came down a
///   step on its first estimate stepped up 17 s in, on the estimate it had 8 s in, and the switch, spliced at the read
///   position, showed 21 s later still.
/// - **Up** by a probe on a recent estimate that fits nothing higher with `upSafety`: with a real full read-ahead and
///   `upSwitchInterval` (and the backoff) after the last switch, to the next variant of more bandwidth and no fewer
///   pixels when `probeSafety` of the estimate fits it. A variant held at 0.7 to 0.85 of the link would otherwise never
///   climb.
///   A variant stepped up to is left within `failedProbeWindow` only when it doesn't fit `probeHoldSafety` (hysteresis).
/// - **Up** otherwise: only with a full read-ahead (`highBuffer`) and `upSwitchInterval` after the last switch, one
///   step up without a recent estimate. With the read-ahead full the thread reads
///   what the socket buffered while it idled and measures nothing, however fast the network, so it probes: a step
///   too high drains the read-ahead and comes down long before that runs out. A step up that comes down within
///   `failedProbeWindow` doubles the wait before the next (up to `maxProbeBackoff` times).
/// - **Back up after a download given up** (`noteAbandoned`): a give-up takes the variant that comes within the buffer,
///   the lowest when none does, to save one segment from a stall, not as a measure of the link. From `estimateUpBuffer` of
///   real read-ahead and `downSwitchInterval` (and the backoff) after it, on an estimate measured since (`halfLives.slow`
///   of media, not the one the give-up set) and within `failedProbeWindow` of it, the logic steps up to the highest
///   variant below the one given up that `probeSafety` of the estimate fits (no fewer pixels): a step up, held and backed
///   off as one. Else a link in the band between `upSafety` and `safety` of a variant (1.5 Mbit/s and 480 at
///   1.08) never stepped up to it but by the probe at a full read-ahead, and played the lowest for some 40 s.
struct AdaptiveBitrateLogic: Sendable {
    struct Config: Sendable {
        /// Read-ahead seconds from which the logic steps up, and below which it steps down.
        var highBuffer = 20.0
        /// Share of the throughput estimate a variant's bandwidth may take to be kept, or stepped down to: hls.js's
        /// `abrBandWidthFactor`. At 0.8, a cold CDN cache's start on Apple's AV1 example (184 ms of round trip, 0.33 s
        /// of answers a second of media) came down from 4K on its first estimate, 76 Mbit/s of the 150 to 180 it then
        /// measured: 4K's 38.5 Mbit/s took 0.84 of a second to read, and the read-ahead grew all the same.
        var safety = 0.95
        /// Seconds after a switch before stepping up with a full read-ahead (a probe).
        var upSwitchInterval = 10.0
        /// Read-ahead seconds from which a recent estimate steps up to the variant it fits with `upSafety`.
        var estimateUpBuffer = 10.0
        /// Share of the throughput estimate a variant stepped up to on an estimate may take.
        var upSafety = 0.7
        /// Share of the estimate the next variant may take for a probe at a full read-ahead, with a recent estimate that
        /// fits it with `upSafety` no higher. Apple's AV1 example: 18.9 Mbit/s takes 0.76 of a 25 Mbit/s link, 21.5 takes
        /// 0.86, which a variant stood on would not keep.
        var probeSafety = 0.85
        /// Share of the estimate a variant stepped up to may take within `failedProbeWindow` of the step before it is left.
        /// A 15 % dip of the estimate (23 to 20 Mbit/s on a steady link) took 18.9 Mbit/s down 8 s after the step at
        /// `safety`.
        var probeHoldSafety = 1.0
        /// Seconds a variant just stepped up to must keep not fitting `probeHoldSafety` before it is left: the estimate of
        /// one second (20.7 of 23 Mbit/s, 0.1 of latency) took 18.9 Mbit/s down 13 s after the step.
        var holdDebounce = 5.0
        /// Read-ahead seconds below which that wait is skipped.
        var urgentBuffer = 5.0
        /// Seconds after a switch before stepping down.
        var downSwitchInterval = 2.0
        /// Seconds an estimate stays recent enough to step up to the variant it fits.
        var estimateLifetime = 20.0
        /// Half-lives (samples' weight: seconds of media) of the two averages.
        var halfLives = (fast: 2.0, slow: 8.0)
        /// Seconds after a step up within which coming down makes it a failed probe.
        var failedProbeWindow = 60.0
        var maxProbeBackoff = 8.0
        /// Samples' weight before the estimate counts: a first short read says little.
        var minimumMeasurement = 1.0
        /// Half-life (seconds of media read) of the latency share.
        var latencyHalfLife = 30.0
        /// Seconds of media read before the latency share counts. A request counts once answered, ahead of its media
        /// (and an init section's has none): over the first seconds read, the few answered ahead weigh on next to no
        /// media, and later on less and less.
        var minimumLatencyMedia = 6.0

        /// The read-ahead threshold at the same share of a read-ahead limit (20 s of 30 s).
        static func scaled(toReadAhead seconds: Double) -> Config {
            var config = Config()
            config.highBuffer = min(config.highBuffer, seconds * 2 / 3)
            config.estimateUpBuffer = min(config.estimateUpBuffer, seconds / 3)
            config.urgentBuffer = min(config.urgentBuffer, config.highBuffer / 4)
            return config
        }
    }

    struct Variant: Sendable, Equatable {
        let id: Int
        /// Bits a second.
        let bandwidth: Int
        /// Width × height; 0 when the playlist doesn't say.
        var pixels = 0
    }

    let config: Config
    private var averages = [(value: 0.0, weight: 0.0), (value: 0.0, weight: 0.0)]
    /// Decayed sums of the requests' latency and of the media read meanwhile, seconds.
    private var latency = (waited: 0.0, media: 0.0)
    private var lastSampleTime: Double?
    private var measuredWeight = 0.0
    private var lastSwitchTime = -Double.infinity
    private var lastStepUpTime = -Double.infinity
    private var lastStepDownTime = -Double.infinity
    private var probeBackoff = 1.0
    /// Since when the current variant didn't fit `probeHoldSafety`, while it does not.
    private var misfitSince: Double?
    /// A give-up the logic may step back up from (`noteAbandoned`), to a variant below `ceiling` (the bandwidth of the one
    /// given up): until a step up, a seek or a variant chosen by hand (`endDetour`), and for `failedProbeWindow` after
    /// `time` at most. `measured` is the weight of the samples taken since: the estimate is the link's after the give-up,
    /// not the one `noteAbandoned` set, once it reaches `halfLives.slow`.
    struct Detour: Sendable, Equatable {
        let ceiling: Int
        let time: Double
        var measured = 0.0
    }

    private(set) var detour: Detour?

    init(config: Config = Config()) {
        self.config = config
    }

    /// A seek, or a variant chosen by hand: the give-up is no reason to step up any more.
    mutating func endDetour() {
        detour = nil
    }

    /// Bits a second, once `minimumMeasurement` was measured.
    var estimate: Double? {
        guard averages[0].weight > 0, measuredWeight >= config.minimumMeasurement else { return nil }
        // Weighted by the share of the averages that samples filled, so the first ones aren't pulled to zero.
        return averages.map { $0.value / $0.weight }.min()
    }

    /// Seconds spent waiting on the requests' answers per second of media read, once `minimumLatencyMedia` was read:
    /// about the same for every variant, as each reads a request per segment of the same length (and one per audio
    /// rendition's).
    var latencyShare: Double? {
        latency.media >= config.minimumLatencyMedia ? latency.waited / latency.media : nil
    }

    /// `waited` seconds for the requests' answers while `media` seconds were read.
    mutating func addLatency(_ waited: Double, media: Double) {
        guard media > 0 || waited > 0 else { return }
        let keep = pow(0.5, media / config.latencyHalfLife)
        latency = (keep * latency.waited + waited, keep * latency.media + media)
    }

    /// `bytes` transferred in `seconds` at `time`, and `media` seconds of them: a request's transfer
    /// (`HTTPSessionTransport`). `bytes` are what the link carried in those seconds, the bytes of other requests running
    /// meanwhile included (`NetworkTransferMeter.Transfer.linkBytes`); `media` is the request's own bytes at the
    /// variant's bandwidth.
    ///
    /// The sample weighs its media alone, slow or not (its seconds without media). Weighed by its seconds when slower
    /// than in real time, one slow for its size (half a megabyte of audio on a connection TCP starts slowly, 5.7 Mbit/s
    /// of 90 at 184 ms of round trip) weighed more than a 4K segment's whole, and brought playback down to 864 wide two
    /// seconds in. Weighed by its seconds alone, a sample read fast weighed little for its media, and an estimate
    /// measured low (a slow start) held for minutes after the network got faster.
    mutating func addSample(bytes: Int, seconds: Double, media: Double, at time: Double) {
        guard bytes > 0, seconds > 0 else { return }
        let sample = Double(bytes) * 8 / seconds
        let weight = media > 0 ? media : seconds
        for (index, halfLife) in [config.halfLives.fast, config.halfLives.slow].enumerated() {
            let keep = pow(0.5, weight / halfLife)
            averages[index].value = keep * averages[index].value + (1 - keep) * sample
            averages[index].weight = keep * averages[index].weight + (1 - keep)
        }
        lastSampleTime = time
        measuredWeight += weight
        detour?.measured += weight
    }

    /// A download was given up for a lower variant's (`MediaDemuxer.requestAbandon`): a step down as far as `choose` is
    /// concerned, which holds off a step back up for `downSwitchInterval`, and doubles the wait before the next when it undoes
    /// a step up that has not stood for `failedProbeWindow`.
    ///
    /// As hls.js's `_abandonRulesCheck` does, the estimate learns of it: what the download brought since its first answer
    /// is a sample (weighed by its seconds: it is the slow link's), and an estimate on which the target fits `upSafety`
    /// (hls.js's `abrBandWidthUpFactor`; its test, not whether a variant above the target would) is set to what keeps the
    /// target and no more (`resetEstimator(nextLoadLevelBitrate)`). Nothing is set with no estimate (nothing measured), nor
    /// while the latency alone takes `safety` (`choose` goes by that then). Else the estimate of the fast link before the drop, which a few seconds of
    /// a slow one hardly move, took the stream back up to the variant given up (measured: 1920p chosen again 2 to 20 s
    /// after its download was given up on a 2 Mbit/s link, and its next segment ran the buffer from 40 s down to 9.5 s).
    mutating func noteAbandoned(
        at time: Double, download: Download? = nil, targetBandwidth: Int? = nil, abandonedBandwidth: Int? = nil
    ) {
        if let download, download.measuredBytes > 0, download.transferring > 0 {
            addSample(bytes: download.measuredBytes, seconds: download.transferring, media: 0, at: time)
        }
        // Replaces an earlier one: the variant given up last is the ceiling. None known, none.
        detour = abandonedBandwidth.map { Detour(ceiling: $0, time: time) }
        // The target fits `safety` with the latency's share, as `choose` reckons, and nothing higher fits `upSafety`.
        let share = config.safety - (latencyShare ?? 0)
        if let targetBandwidth, targetBandwidth > 0, share > 0,
            estimate.map({ $0 * config.upSafety > Double(targetBandwidth) }) ?? false
        {
            setEstimate(Double(targetBandwidth) / share, at: time)
        }
        lastSwitchTime = time
        lastStepDownTime = time
        if time - lastStepUpTime <= config.failedProbeWindow {
            probeBackoff = min(probeBackoff * 2, config.maxProbeBackoff)
        }
        misfitSince = nil
    }

    /// Both averages to `value` bits a second, as if measured now; the samples after it move them as any.
    private mutating func setEstimate(_ value: Double, at time: Double) {
        averages = [(value, 1), (value, 1)]
        measuredWeight = max(measuredWeight, config.minimumMeasurement)
        lastSampleTime = time
    }

    /// The variant to switch to, or nil to stay. `variants` are the switchable ones; `current` is read now.
    /// `isReadAheadReal` is false when `readAhead` was raised to stand for a full one (a live stream at its edge, where
    /// only seconds are buffered): the estimate-based probe, which a drained buffer would not survive, waits.
    mutating func choose(
        current: Int, among variants: [Variant], readAhead: Double, isReadAheadReal: Bool = true, at time: Double
    ) -> Int? {
        let ladder = variants.sorted { $0.bandwidth < $1.bandwidth }
        guard ladder.count > 1, let position = ladder.firstIndex(where: { $0.id == current }) else { return nil }
        let sinceSwitch = time - lastSwitchTime
        let isRecent = lastSampleTime.map { time - $0 <= config.estimateLifetime } ?? false
        // A second of a variant reads in its bandwidth over the estimate, plus the latency share. A share of `safety`
        // leaves no time for any transfer: only the lowest variant comes nearest, with or without an estimate.
        let latencyShare = latencyShare ?? 0
        let isLatencyBound = latencyShare >= config.safety
        let estimate = estimate
        let fits = { (share: Double) in
            isLatencyBound
                ? 0
                : estimate.map { estimate in
                    ladder.lastIndex { Double($0.bandwidth) <= estimate * (share - latencyShare) } ?? 0
                }
        }
        let fitting = fits(config.safety)
        let fittingUp = isRecent ? fits(config.upSafety) : nil
        // A step up that held this long without coming down was no failed probe: the waits start over.
        if lastStepUpTime > lastStepDownTime, time - lastStepUpTime > config.failedProbeWindow { probeBackoff = 1 }
        // A variant just stepped up to is left only when it doesn't fit `probeHoldSafety` (its peak bandwidth within the
        // estimate): a step up was made at `upSafety` or `probeSafety`, and a dip of the estimate by the difference to
        // `safety` is noise, not a failed probe. What it comes down to is what fits `safety`.
        let isNewStepUp = lastStepUpTime > lastStepDownTime && time - lastStepUpTime <= config.failedProbeWindow
        let leaving = isNewStepUp ? fits(config.probeHoldSafety) : fitting
        if let leaving, leaving < position { misfitSince = misfitSince ?? time } else { misfitSince = nil }
        // ...and, while its bandwidth is within the estimate, only when that holds for `holdDebounce` (a second's dip with
        // the latency share is noise), unless the read-ahead is nearly out.
        let cannotCarry = estimate.map { Double(ladder[position].bandwidth) > $0 } ?? true
        let isSettled =
            !isNewStepUp || cannotCarry || readAhead < config.urgentBuffer
            || misfitSince.map { time - $0 >= config.holdDebounce } == true

        var target = position
        if let fitting, fitting < position {
            // Held through a dip (`leaving` fits) it neither comes down nor, with the current variant over `safety`, goes up.
            if let leaving, leaving < position, readAhead < config.highBuffer,
                sinceSwitch >= config.downSwitchInterval, isSettled
            {
                target = fitting
                lastStepDownTime = time
                if time - lastStepUpTime <= config.failedProbeWindow {
                    probeBackoff = min(probeBackoff * 2, config.maxProbeBackoff)
                }
            }
        } else {
            if let fittingUp, fittingUp > position, readAhead >= config.estimateUpBuffer,
                sinceSwitch >= config.downSwitchInterval * probeBackoff
            {
                target = fittingUp
            } else if readAhead >= config.highBuffer, sinceSwitch >= config.upSwitchInterval * probeBackoff {
                if let fittingUp, let estimate {
                    target = max(fittingUp, position)
                    // The next variant is out of `upSafety`'s reach but within `probeSafety`'s: try it, as the estimate
                    // alone never lets a stream stand on 0.7 to 0.85 of the link climb to it. A variant of fewer
                    // pixels isn't a step up whatever its bandwidth; one whose size is unknown is taken for no fewer.
                    if target == position, isReadAheadReal {
                        let budget = estimate * (config.probeSafety - latencyShare)
                        if let next = ladder.indices.dropFirst(position + 1).first(where: {
                            Self.isStepUp(ladder[$0], from: ladder[position])
                        }), Double(ladder[next].bandwidth) <= budget, !isLatencyBound {
                            target = next
                        }
                    }
                } else if position + 1 < ladder.count, !isLatencyBound {
                    target = position + 1
                }
            }
            // Back up after a give-up: below the variant given up, within `probeSafety` of an estimate of the link since,
            // on a real read-ahead.
            if detour.map({ time - $0.time > config.failedProbeWindow }) == true { detour = nil }
            if target == position, let detour, detour.measured >= config.halfLives.slow, isRecent, isReadAheadReal,
                !isLatencyBound, let estimate, readAhead >= config.estimateUpBuffer,
                sinceSwitch >= config.downSwitchInterval * probeBackoff
            {
                let budget = estimate * (config.probeSafety - latencyShare)
                if let best = ladder.indices.last(where: {
                    ladder[$0].bandwidth < detour.ceiling && Double(ladder[$0].bandwidth) <= budget
                        && Self.isStepUp(ladder[$0], from: ladder[position])
                }) {
                    target = best
                }
            }
            if target > position {
                lastStepUpTime = time
                detour = nil
            }
        }
        guard target != position else { return nil }
        lastSwitchTime = time
        misfitSince = nil
        return ladder[target].id
    }

    /// Whether `candidate` is a step up from `current` for a probe: more bandwidth, and no fewer pixels (a variant whose
    /// size is unknown is taken for no fewer).
    private static func isStepUp(_ candidate: Variant, from current: Variant) -> Bool {
        candidate.bandwidth > current.bandwidth
            && (candidate.pixels == 0 || current.pixels == 0 || candidate.pixels >= current.pixels)
    }
}
