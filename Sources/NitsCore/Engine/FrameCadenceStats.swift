import Foundation

/// Debug statistics on how evenly the display link puts frames on screen, reported to the log every few seconds.
///
/// When the link rate is not a whole multiple of the content rate (25 fps on 60 Hz: 2.4 ticks per frame), frames are
/// necessarily held for `floor` or `ceil` of that ratio in a fixed repeating pattern (3‑2‑2‑3‑2). Visible judder beyond
/// that pattern comes from frames held for other tick counts, skipped frames, picks that flip between two ticks
/// because the frame boundary falls right on a vsync, or GPU work that misses its vsync.
///
/// `slack` is how far past its pick threshold a frame was when it was picked (`clock at vsync + lead − pts`): steady
/// playback keeps it within one tick, and values near either edge mean clock jitter can move the frame a tick.
struct FrameCadenceStats: Sendable {
    /// Seconds of playback covered by each report.
    static let reportInterval: CFTimeInterval = 5
    /// A host-time gap (pause, stall) or PTS jump (seek) this large starts a new baseline instead of counting a hold.
    static let maxContinuousHostGap: CFTimeInterval = 0.25
    static let maxContinuousPTSGap: Double = 1
    /// Slack this close to either tick edge counts as a pick that clock jitter could move by a tick.
    static let nearTickEdgeSeconds: Double = 0.001
    /// Slack this close to either tick edge marks a frame whose boundary sits on a vsync: which side of it the frame
    /// lands on (on time, or a tick later) is tracked to count how often it changes.
    static let edgeSideWindowSeconds: Double = 0.0015

    private var lastTargetTimestamp: CFTimeInterval = 0
    private var lastPTS: Double = .nan
    /// Host seconds of continuous playback in the current window (pauses and seeks excluded).
    private var measured: CFTimeInterval = 0
    /// Frames since the last baseline. The baseline frame goes up as soon as playback starts or a seek lands, off
    /// the cadence, so neither its slack nor the hold that follows it is counted.
    private var framesSinceBaseline = 0
    /// Side of the vsync the last edge frame landed on (`true`: a tick later), nil after a baseline.
    private var lastEdgeSideLate: Bool?
    private var runMinSlack = Double.infinity
    private var runMaxSlack = -Double.infinity

    private(set) var frames = 0
    private(set) var holdTicks: [Int: Int] = [:]
    private(set) var offPatternHolds = 0
    private(set) var skippedFrames = 0
    private(set) var minSlack = Double.infinity
    private(set) var maxSlack = -Double.infinity
    /// Largest slack range within one continuous run: the clock's phase against vsync resets at every seek.
    private(set) var slackSpread: Double = 0
    private(set) var nearTickEdge = 0
    private(set) var edgeFrames = 0
    /// Edge frames that landed on the other side of the vsync than the edge frame before them.
    private(set) var edgeSideFlips = 0
    private var maxRenderCall: Double = 0
    private var gpuFrames = 0
    private(set) var lateGPUFrames = 0
    private(set) var failedGPUFrames = 0
    private var minGPUMargin = Double.infinity
    private var tickInterval: CFTimeInterval = 0
    private var frameDuration: Double = 0
    private var playbackRate: Double = 1

    /// Records a frame picked for the vsync at `targetTimestamp` and returns a report when a window is complete.
    /// - Parameters:
    ///   - tickInterval: The display link's vsync spacing (`CADisplayLink.duration`).
    ///   - slack: Content seconds by which the frame was past its pick threshold.
    ///   - renderCall: Seconds the render or enqueue call took on the display-link thread.
    mutating func recordFrame(
        targetTimestamp: CFTimeInterval, tickInterval: CFTimeInterval, pts: Double, slack: Double,
        frameDuration: Double, playbackRate: Double, renderCall: Double
    ) -> String? {
        guard tickInterval > 0, frameDuration > 0, playbackRate > 0, pts.isFinite else { return nil }

        let hostGap = targetTimestamp - lastTargetTimestamp
        let ptsGap = pts - lastPTS
        let sameRates =
            abs(tickInterval - self.tickInterval) < tickInterval * 0.05
            && abs(frameDuration - self.frameDuration) < frameDuration * 0.01
            && abs(playbackRate - self.playbackRate) < 0.001
        let continuous =
            sameRates && lastTargetTimestamp > 0 && hostGap > 0 && hostGap < Self.maxContinuousHostGap
            && ptsGap > 0 && ptsGap < Self.maxContinuousPTSGap
        lastTargetTimestamp = targetTimestamp
        lastPTS = pts

        guard continuous else {
            // A pause or seek only starts a new baseline (nothing is measured across it, and the clock's phase against
            // vsync changes with it); new link or content rates also close the window, so a report never mixes them.
            var report: String?
            if !sameRates {
                report = frames > 0 && measured >= 1 ? makeReport() : nil
                reset()
                self.tickInterval = tickInterval
                self.frameDuration = frameDuration
                self.playbackRate = playbackRate
            }
            framesSinceBaseline = 0
            lastEdgeSideLate = nil
            runMinSlack = .infinity
            runMaxSlack = -.infinity
            return report
        }

        frames += 1
        measured += hostGap
        framesSinceBaseline += 1
        let ticks = Int((hostGap / tickInterval).rounded())
        let skipped = Int((ptsGap / frameDuration).rounded()) - 1
        if skipped > 0 {
            skippedFrames += skipped
        }
        if framesSinceBaseline >= 2 {
            holdTicks[ticks, default: 0] += 1
        }
        if skipped <= 0 && framesSinceBaseline >= 2 {
            // Tolerance for content rates that are a whole multiple only up to floating-point error.
            let idealTicks = idealTicksPerFrame
            if ticks != Int((idealTicks + 1e-6).rounded(.down)) && ticks != Int((idealTicks - 1e-6).rounded(.up)) {
                offPatternHolds += 1
            }
        }

        runMinSlack = min(runMinSlack, slack)
        runMaxSlack = max(runMaxSlack, slack)
        slackSpread = max(slackSpread, runMaxSlack - runMinSlack)
        minSlack = min(minSlack, slack)
        maxSlack = max(maxSlack, slack)
        let tickInContent = tickInterval * playbackRate
        if slack < Self.nearTickEdgeSeconds || slack > tickInContent - Self.nearTickEdgeSeconds {
            nearTickEdge += 1
        }
        let onTime = slack < Self.edgeSideWindowSeconds
        let late = slack > tickInContent - Self.edgeSideWindowSeconds
        if onTime || late {
            edgeFrames += 1
            if let lastEdgeSideLate, lastEdgeSideLate != late { edgeSideFlips += 1 }
            lastEdgeSideLate = late
        }
        maxRenderCall = max(maxRenderCall, renderCall)

        guard measured >= Self.reportInterval else { return nil }
        let report = makeReport()
        reset()
        return report
    }

    /// Records when the GPU finished a frame rendered for the vsync at `targetTimestamp` (`gpuEndTime`, 0 when the
    /// command buffer failed). A frame finished after its vsync cannot make it and shows a tick late. The drawable's
    /// `presentedTime` would be more direct, but macOS reports 0 for every frame of a windowed `CAMetalLayer`.
    mutating func recordGPUCompletion(targetTimestamp: CFTimeInterval, gpuEndTime: CFTimeInterval) {
        gpuFrames += 1
        guard gpuEndTime > 0 else {
            failedGPUFrames += 1
            return
        }
        let margin = targetTimestamp - gpuEndTime
        minGPUMargin = min(minGPUMargin, margin)
        if margin < 0 { lateGPUFrames += 1 }
    }

    private var idealTicksPerFrame: Double { frameDuration / (tickInterval * playbackRate) }

    private mutating func reset() {
        measured = 0
        slackSpread = 0
        frames = 0
        holdTicks = [:]
        offPatternHolds = 0
        skippedFrames = 0
        minSlack = .infinity
        maxSlack = -.infinity
        nearTickEdge = 0
        edgeFrames = 0
        edgeSideFlips = 0
        maxRenderCall = 0
        gpuFrames = 0
        lateGPUFrames = 0
        failedGPUFrames = 0
        minGPUMargin = .infinity
        runMinSlack = .infinity
        runMaxSlack = -.infinity
    }

    private func makeReport() -> String {
        func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
        let ideal = idealTicksPerFrame
        let low = Int(ideal.rounded(.down))
        let ceilShare = ideal - Double(low)
        let idealPattern =
            ceilShare < 0.01 || ceilShare > 0.99
            ? "\(Int(ideal.rounded()))×100%"
            : "\(low)×\(Int(((1 - ceilShare) * 100).rounded()))% \(low + 1)×\(Int((ceilShare * 100).rounded()))%"
        let holds = holdTicks.keys.sorted().map { "\($0)×\(holdTicks[$0] ?? 0)" }.joined(separator: " ")
        let spreadTicks = slackSpread / (tickInterval * playbackRate)
        let gpuSummary =
            gpuFrames == 0
            ? "GPU not tracked"
            : "GPU done after vsync \(lateGPUFrames)/\(gpuFrames), failed \(failedGPUFrames), min margin \(ms(minGPUMargin)) ms"
        return
            "Cadence \(String(format: "%.1f", measured))s: \(frames) frames, "
            + "\(String(format: "%.3f", 1 / frameDuration)) fps at \(String(format: "%.2f", playbackRate))× on "
            + "\(String(format: "%.1f", 1 / tickInterval)) Hz (ideal \(String(format: "%.2f", ideal)) ticks: \(idealPattern)); "
            + "held \(holds.isEmpty ? "-" : holds), off-pattern \(offPatternHolds), skipped \(skippedFrames); "
            + "slack \(ms(minSlack))…\(ms(maxSlack)) ms (spread \(String(format: "%.2f", spreadTicks)) ticks, ideal <1), "
            + "near tick edge \(nearTickEdge), edge frames \(edgeFrames) with \(edgeSideFlips) side flips; render call max \(ms(maxRenderCall)) ms; \(gpuSummary)"
    }
}
