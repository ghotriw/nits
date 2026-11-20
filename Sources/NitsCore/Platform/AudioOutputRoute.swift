@preconcurrency import AVFoundation
import Foundation

/// The system's audio output, as far as the engine follows it: device changes and the latency its clock start
/// aligns with.
///
/// Each platform provides one in `Platform/<os>/` as `PlatformAudioOutputRoute`.
@MainActor
protocol AudioOutputRoute: AnyObject {
    init()

    /// Keeps `renderer` on the system's current output and calls `onChange` once it has moved to a new one
    /// (AirPods connected, HDMI unplugged, …), before reporting the new one's running state.
    ///
    /// `onRunningChange` is called whenever the current output device starts or stops its IO, on a queue of the
    /// route's own and never the main one, for the outputs that can swap their stream under a running audio queue
    /// (Bluetooth; see `AudioOutputInterruptionDetector`) and for no other: the synchronizer's `setRate` on the main thread can wait for the audio
    /// queue to start, and the start for this notification to be delivered.
    ///
    /// `onInterruption` is called when the system takes the audio away (`began`) and when it hands it back (`shouldResume`
    /// says whether the user would want playback to go on), `onRouteLost` when the output in use is gone (headphones
    /// unplugged, AirPods out). iOS reports both; macOS has neither and never calls them.
    func startMonitoring(
        binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
        onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void,
        onInterruption: @escaping @MainActor (_ began: Bool, _ shouldResume: Bool) -> Void,
        onRouteLost: @escaping @MainActor () -> Void)
    func stopMonitoring()

    /// Takes the output for playback (iOS: activates the audio session, which stops other apps' audio) and gives it back.
    /// The engine asks when playback starts and when the media is stopped, never at creation: an app that has loaded
    /// nothing must not silence anyone. Both are idempotent; macOS has no session, so they do nothing there.
    ///
    /// Neither blocks the calling thread (activating takes a while, and the system warns of an interface that hangs on
    /// it): `activate` calls `completion` on the main actor once the session is active, at once when it already is, or
    /// could not be activated (playback goes on without it, not stuck). The engine starts the clock from there.
    /// The route tells when the output device restarts its IO under a running clock (`onRunningChange`, macOS: Bluetooth
    /// switching its stream), which the engine answers by re-anchoring the clock (`AudioOutputInterruptionDetector`). A
    /// route that does not (iOS) leaves the engine to re-anchor after a change of output by itself.
    var reportsOutputRestarts: Bool { get }

    func activate(_ completion: @escaping @MainActor () -> Void)
    func deactivate()

    /// Seconds from handing a sample to the current output until it is audible; `nil` when it cannot be queried.
    nonisolated static func currentOutputLatency() -> TimeInterval?
}
