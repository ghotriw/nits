import Foundation

/// Chooses the HLS variant to read next from the network throughput and the read-ahead (seconds of media read past
/// the packets taken). Pure: the demuxer feeds it samples and times (`MediaDemuxer+AdaptiveBitrate.swift`).
///
/// Throughput is an exponentially weighted average over two half-lives, the lower of the two counting (as dash.js and
/// GStreamer do: quick to fall, slow to rise). It leaves out the requests' latency, which is measured apart, as seconds
/// per second of media (`latencyShare`): a variant fits when reading a second of it, its transfer at the throughput
/// and its share of latency, takes at most `safety` of a second.
/// - **Down**: when the current variant doesn't fit and the read-ahead is below `highBuffer`, to the highest variant
///   that fits. The read-ahead is low after every start and seek too, while it fills: that alone is no reason.
/// - **Up**: only with a full read-ahead (`highBuffer`) and `upSwitchInterval` after the last switch: to the highest
///   variant a recent estimate fits, or one step up when it fits none higher or there is none. With the read-ahead
///   full the thread reads what the socket buffered while it idled and measures nothing, however fast the network, so
///   it probes: a step too high drains the read-ahead and comes down long before that runs out. A probe that comes
///   down within `failedProbeWindow` doubles the wait before the next (up to `maxProbeBackoff` times).
struct AdaptiveBitrateLogic: Sendable {
    struct Config: Sendable {
        /// Read-ahead seconds from which the logic steps up, and below which it steps down.
        var highBuffer = 20.0
        /// Share of the throughput estimate a variant's bandwidth may take.
        var safety = 0.8
        /// Seconds after a switch before stepping up.
        var upSwitchInterval = 10.0
        /// Seconds after a switch before stepping down.
        var downSwitchInterval = 2.0
        /// Seconds an estimate stays recent enough to step up to the variant it fits.
        var estimateLifetime = 20.0
        /// Half-lives (seconds of measured transfer) of the two averages.
        var halfLives = (fast: 2.0, slow: 8.0)
        /// Seconds after a step up within which coming down makes it a failed probe.
        var failedProbeWindow = 60.0
        var maxProbeBackoff = 8.0
        /// Seconds of measured transfer before the estimate counts: a first short read says little.
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
    private var measuredSeconds = 0.0
    private var lastSwitchTime = -Double.infinity
    private var lastStepUpTime = -Double.infinity
    private var lastStepDownTime = -Double.infinity
    private var probeBackoff = 1.0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Bits a second, once `minimumMeasurement` was measured.
    var estimate: Double? {
        guard averages[0].weight > 0, measuredSeconds >= config.minimumMeasurement else { return nil }
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

    /// `bytes` transferred in `seconds` while waiting on the network, at `time`.
    mutating func addSample(bytes: Int, seconds: Double, at time: Double) {
        guard bytes > 0, seconds > 0 else { return }
        let sample = Double(bytes) * 8 / seconds
        for (index, halfLife) in [config.halfLives.fast, config.halfLives.slow].enumerated() {
            let keep = pow(0.5, seconds / halfLife)
            averages[index].value = keep * averages[index].value + (1 - keep) * sample
            averages[index].weight = keep * averages[index].weight + (1 - keep)
        }
        lastSampleTime = time
        measuredSeconds += seconds
    }

    /// The variant to switch to, or nil to stay. `variants` are the switchable ones; `current` is read now.
    /// `atLiveEdge`: the read-ahead counts as full for waiting at a live stream's edge, holding a few segments only.
    mutating func choose(
        current: Int, among variants: [Variant], readAhead: Double, atLiveEdge: Bool = false, at time: Double
    ) -> Int? {
        let ladder = variants.sorted { $0.bandwidth < $1.bandwidth }
        guard ladder.count > 1, let position = ladder.firstIndex(where: { $0.id == current }) else { return nil }
        let sinceSwitch = time - lastSwitchTime
        let isRecent = lastSampleTime.map { time - $0 <= config.estimateLifetime } ?? false
        // A second of a variant reads in its bandwidth over the estimate, plus the latency share. A share of `safety`
        // leaves no time for any transfer: only the lowest variant comes nearest, with or without an estimate.
        let latencyShare = latencyShare ?? 0
        let isLatencyBound = latencyShare >= config.safety
        let fitting =
            isLatencyBound
            ? 0
            : estimate.map { estimate in
                ladder.lastIndex { Double($0.bandwidth) <= estimate * (config.safety - latencyShare) } ?? 0
            }
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
        } else if readAhead >= config.highBuffer, sinceSwitch >= config.upSwitchInterval * probeBackoff {
            if let fitting, isRecent, fitting > position {
                target = fitting
            } else if position + 1 < ladder.count, !(isRecent && atLiveEdge), !isLatencyBound {
                // A recent estimate that fits nothing higher probes too: the averages follow seconds of transfer,
                // which a low variant's small segments take few of, so one measured low (a slow start) stays for
                // minutes. A full read-ahead says the network carries more than the variant read; at a live edge it
                // says nothing of the kind, and a step too high would drain the few segments read.
                target = position + 1
            }
            if target > position { lastStepUpTime = time }
        }
        guard target != position else { return nil }
        lastSwitchTime = time
        return ladder[target].id
    }
}
