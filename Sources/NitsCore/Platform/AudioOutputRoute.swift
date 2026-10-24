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
    /// (AirPods connected, HDMI unplugged, …).
    func startMonitoring(binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void)
    func stopMonitoring()

    /// Seconds from handing a sample to the current output until it is audible; `nil` when it cannot be queried.
    nonisolated static func currentOutputLatency() -> TimeInterval?
}
