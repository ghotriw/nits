import Foundation

/// A live stream's place in what its playlist still lists: the window a viewer can seek in, how far behind the live edge
/// the picture is, and where "go live" lands. Owned by `PlayerEngine`, which feeds it the window the demuxer tells at
/// every tick and resets it with the media; a stream that is not live has no window and every query passes through.
///
/// The window is the playlist's as last loaded, and its ends keep moving after: a demuxer that has read 30 seconds ahead
/// loads it no more until playback catches up. So it is extrapolated, apart for each end:
///
/// - **The end is the live edge, which moves with the clock** while the playlist it is read from grows in steps of a
///   segment, loaded when the demuxer happens to. Extrapolating from the last load makes the edge jump back and forth by
///   a segment (5 s of YouTube's) at every load, and the distance behind it, which is constant while playing, jump with
///   it. A playlist lists only segments already published, so each load tells a lower bound of the edge, `end - clock`;
///   the greatest of the last minute is the edge's offset from the clock, and the edge is the clock plus it: steady, and
///   never behind what was listed. A minute, not for good: after a stall of the source (the playlist not growing for a
///   while) the edge would stay ahead of the real one by the stall, and the badge grey for good. During a stall the
///   distance behind the edge does grow, with the clock: a source that stopped cannot be told from a read-ahead that is
///   full (paused near the edge, it reads no more either), and a distance that stands would then be the wrong one. The
///   samples are not expired by the clock but by newer ones: a pause that reads nothing leaves them as they are.
/// - **The start** stays where it is told while the playlist grows from the beginning of the stream, and moves with the
///   clock once it slides (a start that changed between two loads): a stream's DVR window is capped (an hour at YouTube).
@MainActor
@Observable
public final class LiveStream {
    /// Within this many seconds of the live edge counts as being at it: an HLS player starts a few segments behind the
    /// edge (FFmpeg three, 6 s of 2 s segments), so exactly at the edge is never where playback is.
    nonisolated public static let edgeTolerance = 10.0
    /// How far behind the edge "go live" and the start of a live stream land when the window tells no hold-back of its
    /// own. The streaming client's windows always tell one (the source's, else three target durations): this is for
    /// windows made otherwise.
    nonisolated public static let edgeMargin = 6.0
    /// How far into the window a seek to its start lands: the oldest segments expire from the server while they are
    /// fetched, and the window's start, which moves on with time, would be behind the target by the time it is read.
    nonisolated public static let startMargin = 10.0
    /// A start that moves by less between two loads is a rounding of timestamps (FFmpeg refining the first one, a variant
    /// switch), not the playlist sliding.
    nonisolated static let slideThreshold = 1.0

    /// Whether the media loaded is live. Stays set once the playlist ends (`isEnded`): the stream is then a recording of
    /// what was live, with the last window as its extent, which neither grows nor slides.
    public private(set) var isLive = false
    /// The window as last told. Changes only when the demuxer reports another one.
    public private(set) var reportedWindow: LiveWindow?
    private var reportedAt = ContinuousClock.now
    /// The origin of the clock the edge is measured on.
    private let clockOrigin = ContinuousClock.now
    /// The live edge minus the clock, in seconds: the greatest `end - clock` the loads of the last minute told (see above).
    private var edgeOffset: Double?
    private var edgeSamples: [(clock: Double, offset: Double)] = []
    private static let edgeMemory = 60.0
    /// The start moves with the clock: it changed between two loads.
    private var isSliding = false
    /// The speed the picture played at before the edge slowed it to real time (`adjustedRate`): the one it plays at
    /// behind the edge, saved with the stream and carried to the next media in place of real time.
    private(set) var rateBeforeEdge: Double?
    /// A seek landed behind the edge: the next tick plays at `rateBeforeEdge` again.
    private var returnsToRateBeforeEdge = false

    public init() {}

    private func clock(_ instant: ContinuousClock.Instant) -> Double {
        (instant - clockOrigin) / .seconds(1)
    }

    /// How far behind the edge "go live", the start and a seek land: the stream's own hold-back when it tells one (the
    /// greatest told: a variant whose target duration is longer must not move the edge and the badge back and forth),
    /// else `edgeMargin`.
    private var margin: Double { largestHoldBack ?? Self.edgeMargin }
    private var largestHoldBack: Double?

    /// The playlist ended: the window is the last one, and standing.
    public var isEnded: Bool { reportedWindow?.hasEnded == true }

    /// The window now. `nil` when not live.
    public func window(at now: ContinuousClock.Instant = .now) -> LiveWindow? {
        guard let reportedWindow, let edgeOffset else { return nil }
        if reportedWindow.hasEnded { return reportedWindow }
        let end = max(reportedWindow.end, clock(now) + edgeOffset)
        let start = isSliding ? reportedWindow.start + clock(now) - clock(reportedAt) : reportedWindow.start
        return LiveWindow(
            // The hold-back as kept (`margin`): the greatest told, not the latest.
            start: min(start, end), end: end, hasSlid: reportedWindow.hasSlid, holdBack: largestHoldBack,
            segmentDuration: reportedWindow.segmentDuration, edgeLag: reportedWindow.edgeLag)
    }

    /// A new media was loaded.
    func begin(isLive: Bool, window: LiveWindow?, at now: ContinuousClock.Instant = .now) {
        reset()
        self.isLive = isLive
        update(window: window, at: now)
    }

    /// The demuxer's latest window. Takes it in only when it changed: the same window read again is the one told
    /// earlier, which time has moved on since.
    func update(window: LiveWindow?, at now: ContinuousClock.Instant = .now) {
        guard isLive, let window, window != reportedWindow, reportedWindow?.hasEnded != true else { return }
        // Sliding from the first load if the playlist had slid already (its first segment is not the stream's first),
        // else once a load moves the start.
        if window.hasSlid || (reportedWindow.map { window.start > $0.start + Self.slideThreshold } ?? false) {
            isSliding = true
        }
        let time = clock(now)
        edgeSamples.append((time, window.end - time))
        edgeSamples.removeAll { $0.clock < time - Self.edgeMemory }
        edgeOffset = edgeSamples.map(\.offset).max()
        if let holdBack = window.holdBack { largestHoldBack = max(largestHoldBack ?? holdBack, holdBack) }
        reportedWindow = window
        reportedAt = now
    }

    func reset() {
        isLive = false
        reportedWindow = nil
        edgeOffset = nil
        edgeSamples = []
        largestHoldBack = nil
        isSliding = false
        rateBeforeEdge = nil
        returnsToRateBeforeEdge = false
        lastWindowRecoveryAt = nil
        readRecoveries = 0
        lastReadRecoveryAt = nil
    }

    /// Seconds the picture at `time` is behind the live edge; 0 when not live.
    public func secondsBehindEdge(at time: Double, now: ContinuousClock.Instant = .now) -> Double {
        guard let window = window(at: now) else { return 0 }
        return max(0, window.end - time)
    }

    /// Whether `time` is at the live edge, for the badge to be red. A stream that is not live, or has ended, is not.
    public func isAtEdge(_ time: Double, now: ContinuousClock.Instant = .now) -> Bool {
        guard !isEnded, let window = window(at: now) else { return false }
        return window.end - time <= max(Self.edgeTolerance, margin + Self.edgeSlack + edgeLead)
    }

    /// How far past the hold-back still counts as at the edge: a stall or two of the picture there.
    nonisolated static let edgeSlack = edgeTolerance - edgeMargin

    /// How far the edge reckoned (the freshest listing's of the last minute, `window`) may come to be ahead of the one
    /// the start or "go live" was measured from: as far as a listing may trail what is published, which the window
    /// tells (`LiveWindow.edgeLag`: a reload of the playlist, or a poll of a live history's head and more). YouTube's
    /// history: started 15 s behind, the picture was 23 s behind the edge reckoned half a minute on, playing all the
    /// while, and the badge grey.
    private var edgeLead: Double { reportedWindow?.edgeLag ?? 0 }

    /// The speed a picture at `time` played at `rate` is to play at now, `nil` to keep it. Faster than real time, at the
    /// edge, it would play the segments as fast as the stream makes them and stand buffering for the next, again and
    /// again: it plays in real time there, and at the speed it had again once the user leaves the edge behind, a seek
    /// back or a pause (`seeked(to:)`, `resumed(at:)`). Not after a stall, which leaves the picture behind the edge
    /// too: the speed coming back there would take it to the edge it stalled at, and back to real time, again and
    /// again. Slower is fine, it only falls behind.
    func adjustedRate(_ rate: Double, at time: Double, now: ContinuousClock.Instant = .now) -> Double? {
        if let held = holdAtEdge(rate, at: time, now: now) { return held }
        guard returnsToRateBeforeEdge, let before = rateBeforeEdge else { return nil }
        rateBeforeEdge = nil
        returnsToRateBeforeEdge = false
        return before
    }

    /// A seek to `target`: behind the edge, the speed from before it comes back (`adjustedRate`); at it, it doesn't.
    func seeked(to target: Double, now: ContinuousClock.Instant = .now) {
        returnsToRateBeforeEdge = rateBeforeEdge != nil && !isAtEdge(target, now: now)
    }

    /// Playing again at `time` after a pause: like a seek, the user's leaving the edge behind (`seeked(to:)`).
    func resumed(at time: Double, now: ContinuousClock.Instant = .now) {
        seeked(to: time, now: now)
    }

    /// The seek was the engine's own (the window moved past the picture, the reading stopped), not one back: the speed
    /// stays real time, or the picture would rush back to the edge it stalled at.
    func recovered() {
        returnsToRateBeforeEdge = false
    }

    /// The speed to play at when the user chose `rate` with the picture at `time`. Faster than real time at the edge is
    /// held for behind it (`rateBeforeEdge`), as the edge would slow it at once; any other speed is played, and is the
    /// one behind the edge too.
    func chosenRate(_ rate: Double, at time: Double, now: ContinuousClock.Instant = .now) -> Double {
        returnsToRateBeforeEdge = false
        if let held = holdAtEdge(rate, at: time, now: now) { return held }
        rateBeforeEdge = nil
        return rate
    }

    /// Real time for faster than it at the edge, holding `rate` for behind it; `nil` elsewhere, or for real time and
    /// slower.
    private func holdAtEdge(_ rate: Double, at time: Double, now: ContinuousClock.Instant) -> Double? {
        guard rate > 1, isAtEdge(time, now: now) else { return nil }
        rateBeforeEdge = rate
        return 1
    }

    /// Where "go live" seeks to; `nil` when not live, or ended: there is no edge.
    public func edgeTarget(now: ContinuousClock.Instant = .now) -> Double? {
        guard !isEnded, let window = window(at: now) else { return nil }
        return max(window.start, window.end - margin)
    }

    /// Where a live stream's history opens when it was left at `streamTime` (the stream's own time, which the engine's is
    /// that minus `origin`): there, if the window still holds it. Not at the edge (a stream left there is watched live
    /// again, whatever the time that has passed since), nor before the window's start, which moves on with the clock (a
    /// margin after it: the oldest segments expire as they are fetched), nor at or past where the stream starts from, the
    /// edge: those start at the edge. `nil`: at the edge.
    func resumeTarget(
        streamTime: Double, wasAtEdge: Bool, origin: Double, now: ContinuousClock.Instant = .now
    ) -> Double? {
        guard !wasAtEdge, let window = window(at: now), let edge = edgeTarget(now: now) else { return nil }
        let target = streamTime - origin
        return target >= window.start + Self.startMargin && target < edge ? target : nil
    }

    /// The longest a segment is, and so the farthest apart two keyframes are (a segment begins with one): the window's
    /// target duration, else the hold-back (which is a segment at least).
    private var segmentDuration: Double { reportedWindow?.segmentDuration ?? margin }

    /// Whether a keyframe seek to `seconds` may land on the keyframe after it. Not within a segment of where "go live"
    /// lands: that keyframe is up to a segment on, into the margin, and the picture would play into segments not listed
    /// yet (a skip forward from 6 s behind YouTube's edge landed 1.4 s behind it, and stood buffering at the end of every
    /// segment). It lands on the keyframe before. A stream that ended has no edge to keep away from.
    func allowsLandingAfter(_ seconds: Double, now: ContinuousClock.Instant = .now) -> Bool {
        guard let edge = edgeTarget(now: now) else { return true }
        return seconds <= edge - segmentDuration
    }

    /// Whether a step forward from `time` to `target` (clamped) has nowhere to go but behind `time` or onto it again: an
    /// exact one, when the edge cut it to `time` or before; a keyframe one that lands on the keyframe before its target
    /// (`allowsLandingAfter`), when `time` is within a segment of the target (there is a keyframe in every segment, so
    /// further back it is one past `time`).
    func holdsStepForward(
        from time: Double, to target: Double, exact: Bool, now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard isLive, !isEnded else { return false }
        if exact { return target <= time }
        return !allowsLandingAfter(target, now: now) && time >= target - segmentDuration
    }

    /// `seconds` within the window: of a stream that ended, all of it; of one that goes on, from a margin after its
    /// start to a margin before its edge. Not before 0 when there is none (yet).
    func clamp(_ seconds: Double, now: ContinuousClock.Instant = .now) -> Double {
        guard let window = window(at: now) else { return max(0, seconds) }
        if window.hasEnded { return min(max(seconds, window.start), window.end) }
        // The margin from the start is for a playlist that slides, whose oldest segments expire; one that grows from the
        // stream's beginning keeps them.
        let lower = min(
            window.start + (isSliding ? Self.startMargin : 0), max(window.start, window.end - margin))
        return min(max(seconds, lower), max(window.start, window.end - margin))
    }

    /// An end of the window `clamp` keeps seeks in.
    enum Bound: Equatable {
        case start
        case end
    }

    /// The end of the window a seek to `seconds` is cut to by `clamp`, or `nil` when it lands within. A seek `ChaseTarget`
    /// remembers it: the repeats of a key held at an end are all cut to it, land on the same picture, and the ones that come
    /// while a seek goes need not start it over. Which end it was cut to, not how near the end the target is: the edge moves
    /// with the clock while a seek goes, and a seek that was not cut (a step to just short of the edge) is not one to the edge.
    func bound(of seconds: Double, now: ContinuousClock.Instant = .now) -> Bound? {
        guard let window = window(at: now) else { return nil }
        let upper = window.hasEnded ? window.end : max(window.start, window.end - margin)
        let lower = window.hasEnded ? window.start : min(window.start + (isSliding ? Self.startMargin : 0), upper)
        if seconds >= upper { return .end }
        if seconds <= lower { return .start }
        return nil
    }

    // MARK: Recovery

    /// The picture's place has expired from the window further than this: a seek that lands a keyframe before its
    /// target (the segment's start) is not yet behind it.
    nonisolated static let expirySlack = 2.0
    /// Brings back into the window at most this often: the window moves on while the seek prerolls, and a short one
    /// (a few segments) would send every seek behind its start again.
    nonisolated static let windowRecoveryInterval = 15.0
    /// Reading recovery: the first attempt at once when the stop is seen, the next this long after it, then twice as long
    /// each, up to the maximum, for as long as
    /// it lasts (a server that is down a minute comes back to a stream that plays again, not to one given up on).
    nonisolated static let readRecoveryInterval = 5.0
    nonisolated static let readRecoveryMaximumInterval = 30.0

    private var lastWindowRecoveryAt: ContinuousClock.Instant?
    private var readRecoveries = 0
    private var lastReadRecoveryAt: ContinuousClock.Instant?

    /// Whether the picture at `time` has fallen out of the window and should be brought back; records the attempt.
    func shouldRecoverWindow(at time: Double, now: ContinuousClock.Instant = .now) -> Bool {
        guard let window = window(at: now), !window.hasEnded, time < window.start - Self.expirySlack else {
            return false
        }
        if let last = lastWindowRecoveryAt, now - last < .seconds(Self.windowRecoveryInterval) { return false }
        lastWindowRecoveryAt = now
        return true
    }

    /// Whether to seek to read again: the demuxer stopped reading (its playlist failed to load for good: a server
    /// error, `max_reload` spent) and what was read is played. Records the attempt; apart (the more the longer), and the count starts
    /// over once reading goes on.
    func shouldRecoverReading(isStopped: Bool, now: ContinuousClock.Instant = .now) -> Bool {
        guard isLive, !isEnded, isStopped else {
            if !isStopped { readRecoveries = 0 }
            return false
        }
        let interval = min(
            Self.readRecoveryInterval * pow(2, Double(readRecoveries - 1)), Self.readRecoveryMaximumInterval)
        if let last = lastReadRecoveryAt, now - last < .seconds(interval) { return false }
        readRecoveries += 1
        lastReadRecoveryAt = now
        return true
    }
}
