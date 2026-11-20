#if os(iOS)
    @preconcurrency import AVFoundation
    import Foundation

    typealias PlatformAudioOutputRoute = AudioSessionOutputRoute

    /// The iOS audio output, through the shared `AVAudioSession`: a long-form video session that is active while the
    /// engine lives, reporting route changes, route loss and interruptions (a call, Siri, an alarm).
    @MainActor
    final class AudioSessionOutputRoute: AudioOutputRoute {
        private var observers: [any NSObjectProtocol] = []
        private var isActive = false

        init() {}

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
                ) {
                    notification in
                    let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                    MainActor.assumeIsolated {
                        switch reason {
                        case .oldDeviceUnavailable:
                            onRouteLost()
                        case .newDeviceAvailable, .override, .unknown, .wakeFromSleep:
                            onChange()
                        default:
                            // A category or configuration change keeps the output; the renderer needs nothing.
                            break
                        }
                    }
                })
            observers.append(
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                    queue: .main
                ) {
                    notification in
                    let info = notification.userInfo
                    let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt)
                        .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                    let options = AVAudioSession.InterruptionOptions(
                        rawValue: (info?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
                    MainActor.assumeIsolated {
                        switch type {
                        case .began: onInterruption(true, false)
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

        /// A long-form video session, active from the first playback until `deactivate`: activating takes the output
        /// from other apps' audio, which an app with nothing loaded must not do.
        func activate() {
            guard !isActive else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
                try session.setActive(true)
                isActive = true
            } catch {
                AppLog.error(.audio, "Could not activate the audio session: \(error)")
            }
        }

        /// Hands the output back, telling the apps that were interrupted they may resume.
        func deactivate() {
            guard isActive else { return }
            isActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        nonisolated static func currentOutputLatency() -> TimeInterval? {
            AVAudioSession.sharedInstance().outputLatency
        }
    }
#endif
