#if os(iOS)
    @preconcurrency import AVFoundation
    import Foundation

    typealias PlatformAudioOutputRoute = AudioSessionOutputRoute

    /// The iOS audio output, through the shared `AVAudioSession`: a long-form video session that is active while the
    /// engine lives, reporting route changes, route loss and interruptions (a call, Siri, an alarm).
    @MainActor
    final class AudioSessionOutputRoute: AudioOutputRoute {
        private var observers: [any NSObjectProtocol] = []

        init() {}

        /// iOS has no signal for the output device restarting its IO: the engine re-anchors itself after a change of output.
        var reportsOutputRestarts: Bool { false }

        /// `onRunningChange` never fires: the HAL's device IO notifications are a macOS thing (Bluetooth startup).
        func startMonitoring(
            binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
            onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void,
            onInterruption: @escaping @MainActor (_ began: Bool, _ shouldResume: Bool) -> Void,
            onRouteLost: @escaping @MainActor () -> Void
        ) {
            stopMonitoring()
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                    queue: .main
                ) { notification in
                    let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                    let previous =
                        (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                        as? AVAudioSessionRouteDescription)
                        .map(Self.outputs(of:)) ?? []
                    let current = Self.outputs(of: AVAudioSession.sharedInstance().currentRoute)
                    MainActor.assumeIsolated {
                        let name = reason.map(Self.name(of:)) ?? "reason \(raw ?? 0)"
                        let outputsDiffer = previous != current
                        // What the engine is told: a lost device pauses; another output, or a change the system calls a new
                        // device / override / wake / configuration, moves the renderer. A change of category alone (our own
                        // activation sets it) with the same outputs keeps the output: the renderer needs nothing.
                        let action: String
                        switch reason {
                        case .oldDeviceUnavailable:
                            action = "route lost"
                            AppLog.info(
                                .audio,
                                "Audio route change: \(name), outputs \(previous) -> \(current); \(action)")
                            onRouteLost()
                            return
                        case .newDeviceAvailable, .override, .unknown, .wakeFromSleep, .routeConfigurationChange:
                            action = "output changed"
                        default:
                            action = outputsDiffer ? "output changed" : "ignored (same outputs)"
                        }
                        AppLog.info(
                            .audio, "Audio route change: \(name), outputs \(previous) -> \(current); \(action)")
                        if action == "output changed" { onChange() }
                    }
                })
            observers.append(
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                    queue: .main
                ) {
                    [weak self]
                    notification in
                    let info = notification.userInfo
                    let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt)
                        .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                    let options = AVAudioSession.InterruptionOptions(
                        rawValue: (info?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
                    MainActor.assumeIsolated {
                        switch type {
                        case .began:
                            // The system has deactivated our session: it is not active any more, whatever we cached, so the
                            // play that follows the interruption activates it again.
                            self?.sessionWasTakenBySystem()
                            onInterruption(true, false)
                        case .ended: onInterruption(false, options.contains(.shouldResume))
                        default: break
                        }
                    }
                })
        }

        func stopMonitoring() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            deactivate()
        }

        /// `activate` is under way, or done, or neither; the session itself is changed on `sessionQueue` only.
        private enum Phase { case inactive, activating, active }
        private var phase = Phase.inactive
        /// Counts requests, so the end of an activation that `deactivate` has since overtaken changes nothing.
        private var generation = 0
        private var waiters: [@MainActor () -> Void] = []
        /// `setActive` blocks for as long as the system takes to switch audio (the interface hangs, and the system says
        /// so in the log), so it never runs on the main thread. One queue, so a deactivation after an activation
        /// follows it. The asynchronous calls of the session are from iOS 27 only.
        ///
        /// The session is the process's, shared by every route (two engines can play at once, as in a second window or
        /// a scene): the queue, the count of routes that hold it and its epoch are the type's, so that one route's end
        /// does not take the sound from the others (`setActive(false)` only from the last holder), and a route whose
        /// own state says "active" is not trusted once the session has been given back or taken since.
        private static let sessionQueue = DispatchQueue(label: "com.nits.audio-session", qos: .userInitiated)
        private static var holders = 0
        /// Changes whenever the session stops being active for all (the last holder let go, the system took it).
        private static var epoch = 0
        private var holdsSession = false
        private var activeEpoch = 0

        private func acquireSession() {
            guard !holdsSession else { return }
            holdsSession = true
            Self.holders += 1
        }

        /// Lets go of the session; true when this was the last holder, which is the one that gives it back.
        private func releaseSession() -> Bool {
            guard holdsSession else { return false }
            holdsSession = false
            Self.holders -= 1
            guard Self.holders == 0 else { return false }
            Self.epoch += 1
            return true
        }

        /// A long-form video session, active from the first playback until `deactivate`: activating takes the output
        /// from other apps' audio, which an app with nothing loaded must not do. Not on the main thread: `completion`
        /// runs on it once the session is active (or could not be).
        func activate(_ completion: @escaping @MainActor () -> Void) {
            // Active only while the session still is the one this route made active.
            if phase == .active, activeEpoch != Self.epoch { phase = .inactive }
            switch phase {
            case .active:
                completion()
                return
            case .activating:
                waiters.append(completion)
                return
            case .inactive:
                break
            }
            phase = .activating
            generation += 1
            let mine = generation
            waiters = [completion]
            acquireSession()
            Self.sessionQueue.async { [weak self] in
                let session = AVAudioSession.sharedInstance()
                var failure: (any Error)?
                do {
                    try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
                    try session.setActive(true)
                } catch {
                    failure = error
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finishActivation(generation: mine, failure: failure) }
                }
            }
        }

        private func finishActivation(generation finished: Int, failure: (any Error)?) {
            guard finished == generation, phase == .activating else { return }
            if let failure {
                AppLog.error(.audio, "Could not activate the audio session: \(failure)")
            }
            phase = failure == nil ? .active : .inactive
            activeEpoch = Self.epoch
            if failure != nil, releaseSession() { Self.sessionQueue.async { Self.deactivateSession() } }
            let ready = waiters
            waiters = []
            for waiter in ready { waiter() }
        }

        /// An interruption began: the system deactivated the session itself. The state is reset (and an activation still
        /// under way is outdated), without a `setActive(false)` of ours, which would be for a session already gone.
        private func sessionWasTakenBySystem() {
            phase = .inactive
            generation += 1
            // Gone for every route: the first of them to be told starts a new epoch, the others find it already changed.
            if holdsSession {
                holdsSession = false
                Self.holders -= 1
            }
            if Self.holders == 0 { Self.epoch += 1 }
            let ready = waiters
            waiters = []
            for waiter in ready { waiter() }
        }

        /// Hands the output back, telling the apps that were interrupted they may resume.
        func deactivate() {
            guard phase != .inactive else { return }
            phase = .inactive
            generation += 1
            // Whoever waited for the activation is not left waiting.
            let ready = waiters
            waiters = []
            for waiter in ready { waiter() }
            // Only the last holder hands the output back: another route may still be playing.
            if releaseSession() { Self.sessionQueue.async { Self.deactivateSession() } }
        }

        nonisolated private static func deactivateSession() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        /// The ports an output is made of, as `name (type)`, for comparing routes and for the log.
        nonisolated private static func outputs(of route: AVAudioSessionRouteDescription) -> [String] {
            route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        }

        nonisolated private static func name(of reason: AVAudioSession.RouteChangeReason) -> String {
            switch reason {
            case .unknown: "unknown"
            case .newDeviceAvailable: "newDeviceAvailable"
            case .oldDeviceUnavailable: "oldDeviceUnavailable"
            case .categoryChange: "categoryChange"
            case .override: "override"
            case .wakeFromSleep: "wakeFromSleep"
            case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
            case .routeConfigurationChange: "routeConfigurationChange"
            @unknown default: "reason \(reason.rawValue)"
            }
        }

        nonisolated static func currentOutputLatency() -> TimeInterval? {
            AVAudioSession.sharedInstance().outputLatency
        }
    }
#endif
