import Foundation
import Testing

@testable import NitsCore

/// Measures how long the state behind the seek spinner (`LoadingOverlayView`) holds after seeks on a local file:
/// `isSeeking`, `isAwaitingClockStart` and `isBuffering`. Prints a line per seek and a summary per scenario; run with
/// `swift test --filter SeekSpinnerTimelineTests` and read the `[seek-timeline]` lines. Asserts nothing about timing:
/// it is a measurement, not a gate.
@Suite("Seek spinner timeline", .serialized, .realtimePlayback, .hostDependent)
struct SeekSpinnerTimelineTests {
    /// The spinner's delay before showing during a seek, and its hold after the clock starts (`LoadingOverlayView`).
    private static let spinnerDelayMs = 150.0
    private static let spinnerHoldMs = 100.0

    fileprivate static let presets: [SyntheticTestMediaFactory.Preset] = [.hevc10BitHDR, .h264HFR60, .wideGOPH264]

    private struct Sample {
        var seekingMs: Double
        var clockStartMs: Double
        var buffered: Bool
        var spinnerMs: Double
    }

    @MainActor
    private static func measure(
        _ engine: PlayerEngine, label: String, playing: Bool, seeks: Int, targets: () -> Double
    ) async -> [Sample] {
        var samples: [Sample] = []
        for index in 0..<seeks {
            let target = targets()
            let clock = ContinuousClock()
            let start = clock.now
            func ms(_ instant: ContinuousClock.Instant) -> Double {
                let d = instant - start
                return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            }
            engine.seek(to: target)
            var seekingEnd: Double?
            var clockEnd: Double?
            var buffered = false
            var bufferingStart: Double?
            var bufferingMs = 0.0
            var spinnerOn: Double?
            var settledAt: ContinuousClock.Instant?
            while ms(clock.now) < 4000 {
                try? await Task.sleep(for: .milliseconds(2))
                let now = ms(clock.now)
                if engine.isBuffering {
                    buffered = true
                    if bufferingStart == nil { bufferingStart = now }
                    bufferingMs = now - (bufferingStart ?? now)
                } else if bufferingStart != nil, bufferingMs > 0 {
                    bufferingStart = nil
                }
                if seekingEnd == nil, !engine.isSeeking { seekingEnd = now }
                if seekingEnd == nil, spinnerOn == nil, now >= spinnerDelayMs { spinnerOn = now }
                if seekingEnd != nil, clockEnd == nil, !engine.isAwaitingClockStart {
                    clockEnd = now
                    settledAt = clock.now

                }
                // After the clock starts, watch a further 400 ms for starvation right behind the seek.
                if let settledAt, clock.now - settledAt >= .milliseconds(400) { break }
            }
            let seekingMs = seekingEnd ?? .nan
            let clockMs = clockEnd ?? .nan
            // Spinner model: shown once the seek has run `spinnerDelayMs`, kept until the clock starts + the hold.
            let spinnerMs: Double =
                (spinnerOn != nil && seekingMs >= spinnerDelayMs)
                ? (clockMs + (playing ? spinnerHoldMs : 0)) - spinnerDelayMs : (buffered ? .nan : 0)
            print(
                "[seek-timeline] \(label) #\(index) -> \(String(format: "%.1f", target))s: "
                    + "isSeeking \(String(format: "%.0f", seekingMs)) ms, "
                    + "awaitingClock \(String(format: "%.0f", clockMs)) ms, buffering \(buffered ? String(format: "%.0f ms", bufferingMs) : "no"), "
                    + "spinner ≈ \(spinnerMs.isNaN ? "buffering" : String(format: "%.0f", spinnerMs) + " ms")")
            samples.append(
                Sample(seekingMs: seekingMs, clockStartMs: clockMs, buffered: buffered, spinnerMs: spinnerMs))
            try? await Task.sleep(for: .milliseconds(300))
        }
        let shown = samples.filter { $0.spinnerMs != 0 }.count
        let worst = samples.map(\.clockStartMs).filter { !$0.isNaN }.max() ?? .nan
        print(
            "[seek-timeline] \(label) SUMMARY: spinner on \(shown)/\(samples.count) seeks, "
                + "buffering after \(samples.filter(\.buffered).count), worst clock start \(String(format: "%.0f", worst)) ms"
        )
        return samples
    }

    @Test(
        "Spinner state after single seeks and repeated seeks",
        arguments: SeekSpinnerTimelineTests.presets)
    @MainActor
    func timeline(preset: SyntheticTestMediaFactory.Preset) async {
        // `NITS_TIMELINE_MEDIA=<file>` measures that file instead of the presets (once).
        let custom = ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"]
        if custom != nil, preset != Self.presets[0] { return }
        guard let path = custom ?? SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: path)
        guard engine.isLoaded, engine.media.duration > 10 else { return }
        let maxSeek = engine.media.duration - 3

        engine.play()
        _ = await engine.waitForPlayback()
        let name = custom.map { URL(filePath: $0).lastPathComponent } ?? "\(preset)"
        _ = await Self.measure(engine, label: "\(name) playing/random", playing: true, seeks: 12) {
            Double.random(in: 1...maxSeek)
        }
        var forward = 2.0
        _ = await Self.measure(engine, label: "\(name) playing/step+5s", playing: true, seeks: 12) {
            forward = forward + 5 > maxSeek ? 2 : forward + 5
            return forward
        }
        engine.pause()
        _ = await Self.measure(engine, label: "\(name) paused/random", playing: false, seeks: 12) {
            Double.random(in: 1...maxSeek)
        }
        engine.stop()
    }

    // MARK: - Arrow keys

    /// Single and repeated arrow presses with the exact-on-first-press setting off and on, measured to the moment the
    /// picture moves again. Needs `NITS_TIMELINE_MEDIA` (a long file with sparse keyframes shows it best).
    @Test(
        "Arrow presses: single and burst, forward and backward, exact seek off and on",
        .enabled(if: ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] != nil))
    @MainActor
    func keyPresses() async {
        guard let custom = ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: custom)
        // A network source opens in the background.
        _ = await engine.waitUntil(timeout: .seconds(60)) { engine.isLoaded }
        guard engine.isLoaded, engine.media.duration > 600 else { return }
        engine.play()
        _ = await engine.waitForPlayback()
        let clock = ContinuousClock()

        for exact in [false, true] {
            for (direction, step) in [("fwd", 10.0), ("back", -10.0)] {
                for burst in [false, true] {
                    // `NITS_BURST_PRESSES=<n>`: only bursts, of n presses (a long series, as on a slow source).
                    let burstPresses = ProcessInfo.processInfo.environment["NITS_BURST_PRESSES"].flatMap { Int($0) }
                    if burstPresses != nil && !burst { continue }
                    let label = "exact=\(exact) \(direction) \(burst ? "burst x\(burstPresses ?? 25)" : "single")"
                    engine.exactSeekOnSinglePress = exact
                    for round in 0..<(burst ? 4 : 6) {
                        engine.seek(to: 1200 + Double(round) * 37, exact: true)
                        _ = await engine.waitForPlayback()
                        try? await Task.sleep(for: .milliseconds(1500))
                        let startTime = engine.currentTime
                        let start = clock.now
                        func ms() -> Double {
                            let d = clock.now - start
                            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                        }
                        let presses = burst ? (burstPresses ?? 25) : 1
                        var busyAfterLastPress = 0.0
                        var slowestCall = 0.0
                        for press in 0..<presses {
                            let callStart = ms()
                            engine.seekRelative(by: step)
                            slowestCall = max(slowestCall, ms() - callStart)
                            if press < presses - 1 { try? await Task.sleep(for: .milliseconds(60)) }
                        }
                        let lastPress = ms()
                        var landed: Double?
                        var clockStarted: Double?
                        var moved: Double?
                        var spinnerFlagMs = 0.0
                        var firstFramePTS = 0.0
                        var visible = false
                        var visibleSince = 0.0
                        var visibleTotal = 0.0
                        var visibleAfterLast = 0.0
                        var pendingSince: Double?
                        var hideAt: Double?
                        var lastTick = ms()
                        while ms() < 6000 {
                            try? await Task.sleep(for: .milliseconds(2))
                            let now = ms()
                            let busy = engine.isSeeking || engine.isAwaitingClockStart || engine.isBuffering
                            if busy {
                                spinnerFlagMs += now - lastTick
                                busyAfterLastPress = now - lastPress
                            }
                            lastTick = now
                            // The spinner as `LoadingOverlayView` shows it: 150 ms into a seek, kept while a pending
                            // resume awaits the clock, 100 ms after.
                            let inFlight = engine.isSeeking || (visible && engine.isAwaitingClockStart)
                            if inFlight {
                                hideAt = nil
                                if !visible {
                                    if pendingSince == nil {
                                        pendingSince = now
                                    } else if now - (pendingSince ?? now) >= 150, engine.isSeeking {
                                        visible = true
                                        visibleSince = now
                                    }
                                }
                            } else {
                                pendingSince = nil
                                if visible {
                                    if hideAt == nil {
                                        hideAt = now + 100
                                    } else if now >= (hideAt ?? now) {
                                        visible = false
                                        visibleTotal += now - visibleSince
                                        if now > lastPress { visibleAfterLast += now - max(visibleSince, lastPress) }
                                    }
                                }
                            }
                            if landed == nil, !engine.isSeeking, now >= lastPress { landed = now - lastPress }
                            if landed != nil, clockStarted == nil, !engine.isAwaitingClockStart {
                                clockStarted = now - lastPress
                                firstFramePTS = engine.currentFramePTS
                            }
                            if clockStarted != nil, moved == nil, engine.currentFramePTS - firstFramePTS >= 0.15 {
                                moved = now - lastPress
                            }
                            if moved != nil, !busy { break }
                        }
                        func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "never" }
                        print(
                            "[seek-timeline] \(label) #\(round) \(String(format: "%.1f", startTime))s -> "
                                + "\(String(format: "%.1f", engine.currentTime))s: after last press landed \(fmt(landed)) ms, "
                                + "clock \(fmt(clockStarted)) ms, picture moving \(fmt(moved)) ms, "
                                + "presses took \(String(format: "%.0f", lastPress)) ms (slowest call \(String(format: "%.0f", slowestCall)) ms), "
                                + "busy until \(String(format: "%.0f", busyAfterLastPress)) ms, "
                                + "spinner \(String(format: "%.0f", visibleTotal)) ms total, "
                                + "\(String(format: "%.0f", visibleAfterLast)) ms after the last press")
                    }
                }
            }
        }
        engine.stop()
    }

    // MARK: - Rapid taps

    /// Arrow taps, each a press and its release (which ends nothing), one after another at a pace: how the picture follows
    /// them (press to a changed picture), how often the clock is started and the spinner shows. Needs `NITS_TIMELINE_MEDIA`.
    @Test(
        "Rapid arrow taps: clock starts and spinner",
        .enabled(if: ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] != nil))
    @MainActor
    func rapidTaps() async {
        guard let custom = ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: custom)
        // A network source opens in the background.
        _ = await engine.waitUntil(timeout: .seconds(60)) { engine.isLoaded }
        guard engine.isLoaded, engine.media.duration > 600 else { return }
        Self.printStand(engine, path: custom)
        engine.play()
        _ = await engine.waitForPlayback()
        let clock = ContinuousClock()

        for gapMs in [120.0, 200.0, 350.0] {
            for direction in [10.0, -10.0] {
                engine.seek(to: 1200, exact: true)
                _ = await engine.waitForPlayback()
                try? await Task.sleep(for: .milliseconds(1500))
                let start = clock.now
                func ms() -> Double { Self.ms(clock.now - start) }
                let taps = 12
                var nextTap = 0.0
                var tapped = 0
                var pressAt: Double?
                var releaseAt: Double?
                var picturePTS = engine.currentFramePTS
                var latencies: [Double] = []
                var clockStarts = 0
                var wasAwaiting = engine.isAwaitingClockStart
                var maxTickGap = 0.0
                var lastTick = ms()
                var visible = false
                var visibleSince = 0.0
                var visibleTotal = 0.0
                var pendingSince: Double?
                var hideAt: Double?
                var endAt = Double.infinity
                while ms() < endAt {
                    try? await Task.sleep(for: .milliseconds(2))
                    let now = ms()
                    maxTickGap = max(maxTickGap, now - lastTick)
                    lastTick = now
                    if tapped < taps, now >= nextTap {
                        engine.seekRelative(by: direction)
                        pressAt = now
                        releaseAt = now + 40
                        nextTap = now + gapMs
                        tapped += 1
                        if tapped == taps { endAt = now + 3000 }
                    }
                    // A tap and its release: nothing happens on the release.
                    if let release = releaseAt, now >= release { releaseAt = nil }
                    if let press = pressAt, engine.currentFramePTS != picturePTS {
                        latencies.append(now - press)
                        pressAt = nil
                    }
                    picturePTS = engine.currentFramePTS
                    if wasAwaiting, !engine.isAwaitingClockStart { clockStarts += 1 }
                    wasAwaiting = engine.isAwaitingClockStart
                    let inFlight = engine.isSeeking || (visible && engine.isAwaitingClockStart)
                    if inFlight {
                        hideAt = nil
                        if !visible {
                            if pendingSince == nil {
                                pendingSince = now
                            } else if now - (pendingSince ?? now) >= Self.spinnerDelayMs, engine.isSeeking {
                                visible = true
                                visibleSince = now
                            }
                        }
                    } else {
                        pendingSince = nil
                        if visible {
                            if hideAt == nil {
                                hideAt = now + Self.spinnerHoldMs
                            } else if now >= (hideAt ?? now) {
                                visible = false
                                visibleTotal += now - visibleSince
                            }
                        }
                    }
                }
                let sorted = latencies.sorted()
                func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
                print(
                    "[seek-timeline] taps every \(Int(gapMs)) ms \(direction > 0 ? "fwd" : "back"): "
                        + "\(latencies.count)/\(taps) taps changed the picture, press to picture median "
                        + "\(fmt(sorted.isEmpty ? nil : sorted[sorted.count / 2])) ms, worst \(fmt(sorted.last)) ms, "
                        + "clock started \(clockStarts)x, spinner \(fmt(visibleTotal)) ms, "
                        + "worst main-actor tick gap \(fmt(maxTickGap)) ms, landed at \(String(format: "%.1f", engine.currentTime))s"
                )
            }
        }
        engine.stop()
    }

    // MARK: - Held key

    /// An arrow key held down at the system's repeat rhythm (`InitialKeyRepeat` before the first repeat, `KeyRepeat`
    /// between the rest), released after `repeats` repeats: when the spinner shows and goes, and when the clock starts.
    /// Needs `NITS_TIMELINE_MEDIA`.
    @Test(
        "Held arrow key: spinner and clock start by the system repeat rhythm",
        .enabled(if: ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] != nil))
    @MainActor
    func heldKey() async {
        guard let custom = ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: custom)
        // A network source opens in the background.
        _ = await engine.waitUntil(timeout: .seconds(60)) { engine.isLoaded }
        guard engine.isLoaded, engine.media.duration > 600 else { return }
        Self.printStand(engine, path: custom)
        engine.play()
        _ = await engine.waitForPlayback()
        let clock = ContinuousClock()
        let defaults = UserDefaults.standard
        let initialDelay = Double(defaults.object(forKey: "InitialKeyRepeat") as? Int ?? 25) * 15
        let interval = Double(defaults.object(forKey: "KeyRepeat") as? Int ?? 6) * 15

        for repeats in [3, 10, 25] {
            for direction in [10.0, -10.0] {
                engine.exactSeekOnSinglePress = false
                engine.seek(to: 1200, exact: true)
                _ = await engine.waitForPlayback()
                try? await Task.sleep(for: .milliseconds(1500))
                let start = clock.now
                let startUptime = DispatchTime.now().uptimeNanoseconds / 1_000_000
                func ms() -> Double { Self.ms(clock.now - start) }
                var nextPress = 0.0
                var presses = 0
                var releasedAt: Double?
                var clockStarts: [Double] = []
                var wasAwaiting = engine.isAwaitingClockStart
                var visible = false
                var lastState = ""
                var stalls: [String] = []
                var lastTickAt = 0.0
                var transitions: [String] = []
                var spinnerShownAt: [Double] = []
                var spinnerGoneAt: [Double] = []
                var pendingSince: Double?
                var hideAt: Double?
                var endAt = Double.infinity
                while ms() < endAt {
                    try? await Task.sleep(for: .milliseconds(2))
                    let now = ms()
                    if now - lastTickAt > 30, lastTickAt > 0 {
                        stalls.append(String(format: "main actor stalled %.0f-%.0f ms", lastTickAt, now))
                    }
                    lastTickAt = now
                    if presses <= repeats, now >= nextPress {
                        engine.seekRelative(by: direction)
                        nextPress = now + (presses == 0 ? initialDelay : interval)
                        presses += 1
                        if presses > repeats {
                            releasedAt = now + 30
                        }
                    }
                    if let release = releasedAt, now >= release {
                        releasedAt = nil
                        endAt = now + 3000
                    }
                    if wasAwaiting, !engine.isAwaitingClockStart { clockStarts.append(now) }
                    wasAwaiting = engine.isAwaitingClockStart
                    let state =
                        "seeking \(engine.isSeeking ? 1 : 0) awaiting \(engine.isAwaitingClockStart ? 1 : 0) "
                        + "buffering \(engine.isBuffering ? 1 : 0) playing \(engine.isPlaying ? 1 : 0)"
                    if repeats == 10, direction > 0, state != lastState {
                        transitions.append(String(format: "%.0f ms: ", now) + state)
                        lastState = state
                    }
                    let inFlight = engine.isSeeking || (visible && engine.isAwaitingClockStart)
                    if inFlight {
                        hideAt = nil
                        if !visible {
                            if pendingSince == nil {
                                pendingSince = now
                            } else if now - (pendingSince ?? now) >= Self.spinnerDelayMs, engine.isSeeking {
                                visible = true
                                spinnerShownAt.append(now)
                            }
                        }
                    } else {
                        pendingSince = nil
                        if visible {
                            if hideAt == nil {
                                hideAt = now + Self.spinnerHoldMs
                            } else if now >= (hideAt ?? now) {
                                visible = false
                                spinnerGoneAt.append(now)
                            }
                        }
                    }
                }
                func list(_ values: [Double]) -> String {
                    values.isEmpty ? "-" : values.map { String(format: "%.0f", $0) }.joined(separator: ", ")
                }
                print(
                    "[seek-timeline] held \(direction > 0 ? "fwd" : "back") x\(repeats) repeats (first repeat at "
                        + "\(Int(initialDelay)) ms, then every \(Int(interval)) ms), release at "
                        + "\(String(format: "%.0f", initialDelay + Double(repeats) * interval)) ms: "
                        + "spinner shown at [\(list(spinnerShownAt))] ms, gone at [\(list(spinnerGoneAt))] ms, "
                        + "clock started at [\(list(clockStarts))] ms")
                if !stalls.isEmpty { print("[seek-timeline] " + stalls.joined(separator: "; ")) }
                if !transitions.isEmpty {
                    print(
                        "[seek-timeline] test started at \(startUptime) ms; states: "
                            + transitions.joined(separator: " | "))
                }
            }
        }
        engine.stop()
    }

    // MARK: - Load and audio track switch

    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The setup a run was made on, printed first so a log says what it measured.
    @MainActor
    private static func printStand(_ engine: PlayerEngine, path: String) {
        let url = URL(filePath: path)
        let isNetwork = path.hasPrefix("http") || path.hasPrefix("/Volumes/")
        let tracks = engine.audioTracks.map { "#\($0.id) \($0.codecName) \($0.channels)ch \($0.language)" }
        let latency =
            PlatformAudioOutputRoute.currentOutputLatency().map { String(format: "%.1f ms", $0 * 1000) } ?? "?"
        let info = ProcessInfo.processInfo
        print(
            "[stand] file \(url.lastPathComponent), source \(isNetwork ? "network volume or URL" : "local disk"), "
                + "audio tracks [\(tracks.joined(separator: "; "))], output latency \(latency), "
                + "output \(info.environment["NITS_STAND_OUTPUT"] ?? "unspecified"), thermal \(info.thermalState.rawValue), "
                + "low power \(info.isLowPowerModeEnabled), \(info.operatingSystemVersionString)")
    }

    /// Loads of the file and audio track switches while it plays: when the picture and the clock run, and whether
    /// buffering shows on the way (a spinner flash). Needs `NITS_TIMELINE_MEDIA`; `NITS_STAND_OUTPUT` names the audio
    /// output for the log.
    @Test(
        "Load and audio track switch: time to a moving picture, buffering on the way",
        .enabled(if: ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] != nil))
    @MainActor
    func loadAndTrackSwitch() async {
        guard let path = ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        let clock = ContinuousClock()

        for round in 0..<5 {
            let start = clock.now
            engine.load(path: path)
            let loadReturned = Self.ms(clock.now - start)
            if round == 0 { Self.printStand(engine, path: path) }
            var buffering: Double?
            var bufferedMs = 0.0
            var moved: Double?
            var firstFrame: Double?
            let firstTime = engine.currentTime
            while Self.ms(clock.now - start) < 6000 {
                try? await Task.sleep(for: .milliseconds(2))
                let now = Self.ms(clock.now - start)
                if firstFrame == nil, engine.currentFramePTS >= 0 { firstFrame = now }
                if moved == nil, engine.isPlaying, engine.currentTime - firstTime >= 0.15 { moved = now }
                if engine.isBuffering {
                    if buffering == nil { buffering = now }
                    bufferedMs = now - (buffering ?? now)
                }
                if moved != nil, now - (moved ?? now) > 600 { break }
            }
            func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "never" }
            print(
                "[seek-timeline] load #\(round): load() returned after \(fmt(loadReturned)), first frame \(fmt(firstFrame)), "
                    + "clock moving \(fmt(moved)), buffering \(buffering == nil ? "no" : "at \(fmt(buffering)) for \(fmt(bufferedMs))")"
            )
        }

        let tracks = engine.audioTracks
        guard tracks.count > 1 else {
            engine.stop()
            return
        }
        engine.load(path: path)
        _ = await engine.waitForPlayback()
        try? await Task.sleep(for: .milliseconds(1500))
        for round in 0..<6 {
            let track = tracks[(round + 1) % tracks.count]
            let start = clock.now
            let clockBefore = engine.currentTime
            engine.selectAudioTrack(id: track.id)
            let callMs = Self.ms(clock.now - start)
            var buffering: Double?
            var bufferedMs = 0.0
            var lastTime = clockBefore
            var lastChange = Self.ms(clock.now - start)
            var worstStall = 0.0
            while Self.ms(clock.now - start) < 2500 {
                try? await Task.sleep(for: .milliseconds(2))
                let now = Self.ms(clock.now - start)
                if engine.currentTime != lastTime {
                    worstStall = max(worstStall, now - lastChange)
                    lastTime = engine.currentTime
                    lastChange = now
                }
                if engine.isBuffering {
                    if buffering == nil { buffering = now }
                    bufferedMs = now - (buffering ?? now)
                }
            }
            func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "never" }
            print(
                "[seek-timeline] track switch #\(round) -> #\(track.id) \(track.codecName): call took \(fmt(callMs)), "
                    + "worst clock stall \(fmt(worstStall)), "
                    + "buffering \(buffering == nil ? "no" : "at \(fmt(buffering)) for \(fmt(bufferedMs))")")
        }
        engine.stop()
    }

    // MARK: - Play after a seek that did not resume

    /// `play()` after a seek the user paused during, and after a seek made on pause: the audio renderer was flushed and
    /// nothing has fed it, and `play()` joins the audio to the picture (`AudioJoin`). Prints when the picture moves and whether
    /// buffering shows. Needs `NITS_TIMELINE_MEDIA`.
    @Test(
        "Play after seek then pause, and after a seek on pause",
        .enabled(if: ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] != nil))
    @MainActor
    func playAfterSeek() async {
        guard let path = ProcessInfo.processInfo.environment["NITS_TIMELINE_MEDIA"] else { return }
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(resumePlayback: false))
        engine.load(path: path)
        guard engine.isLoaded, engine.media.duration > 600 else { return }
        Self.printStand(engine, path: path)
        engine.play()
        _ = await engine.waitForPlayback()
        let clock = ContinuousClock()

        for scenario in ["seek, pause during it, play", "seek on pause, play"] {
            for round in 0..<6 {
                engine.seek(to: 1200 + Double(round) * 41, exact: true)
                _ = await engine.waitForPlayback()
                try? await Task.sleep(for: .milliseconds(1000))
                let target = 1200 + Double(round) * 41 + 300
                if scenario.hasPrefix("seek,") {
                    engine.seek(to: target, exact: false)
                    try? await Task.sleep(for: .milliseconds(30))
                    engine.pause()
                } else {
                    engine.pause()
                    try? await Task.sleep(for: .milliseconds(200))
                    engine.seek(to: target, exact: false)
                }
                _ = await engine.waitUntil { !engine.isSeeking && engine.pendingSeekTime == nil }
                try? await Task.sleep(for: .milliseconds(500))

                let start = clock.now
                let startTime = engine.currentTime
                engine.play()
                var moved: Double?
                var buffering: Double?
                var bufferedMs = 0.0
                while Self.ms(clock.now - start) < 3000 {
                    try? await Task.sleep(for: .milliseconds(2))
                    let now = Self.ms(clock.now - start)
                    if moved == nil, engine.currentTime - startTime >= 0.15 { moved = now }
                    if engine.isBuffering {
                        if buffering == nil { buffering = now }
                        bufferedMs = now - (buffering ?? now)
                    }
                    if moved != nil, now - (moved ?? now) > 800 { break }
                }
                func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "never" }
                print(
                    "[seek-timeline] \(scenario) #\(round): clock moving \(fmt(moved)) after play(), "
                        + "buffering \(buffering == nil ? "no" : "at \(fmt(buffering)) for \(fmt(bufferedMs))")")
            }
        }
        engine.stop()
    }
}
