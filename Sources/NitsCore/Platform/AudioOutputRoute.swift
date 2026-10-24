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
    /// route's own and never the main one: the synchronizer's `setRate` on the main thread can wait for the audio
    /// queue to start, and the start for this notification to be delivered.
    func startMonitoring(
        binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
        onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void)
    func stopMonitoring()

    /// Seconds from handing a sample to the current output until it is audible; `nil` when it cannot be queried.
    nonisolated static func currentOutputLatency() -> TimeInterval?
}
