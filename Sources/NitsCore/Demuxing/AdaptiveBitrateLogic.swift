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
/// - **Up** otherwise: only with a full read-ahead (`highBuffer`) and `upSwitchInterval` after the last switch, one
///   step up without a recent estimate. With the read-ahead full the thread reads
///   what the socket buffered while it idled and measures nothing, however fast the network, so it probes: a step
///   too high drains the read-ahead and comes down long before that runs out. A step up that comes down within
///   `failedProbeWindow` doubles the wait before the next (up to `maxProbeBackoff` times).
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
            return config
        }
    }

    struct Variant: Sendable, Equatable {
        let id: Int
        /// Bits a second.
        let bandwidth: Int
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

    init(config: Config = Config()) {
        self.config = config
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

    /// `bytes` transferred in `seconds`, `media` seconds of it, at `time`: a request's transfer
    /// (`HTTPSessionTransport`), whose media is what its bytes are at the variant's bandwidth.
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
    }

    /// The variant to switch to, or nil to stay. `variants` are the switchable ones; `current` is read now.
    mutating func choose(current: Int, among variants: [Variant], readAhead: Double, at time: Double) -> Int? {
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

        var target = position
        if let fitting, fitting < position {
            if readAhead < config.highBuffer, sinceSwitch >= config.downSwitchInterval {
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
                if let fittingUp {
                    target = max(fittingUp, position)
                } else if position + 1 < ladder.count, !isLatencyBound {
                    target = position + 1
                }
            }
            if target > position { lastStepUpTime = time }
        }
        guard target != position else { return nil }
        lastSwitchTime = time
        return ladder[target].id
    }
}
