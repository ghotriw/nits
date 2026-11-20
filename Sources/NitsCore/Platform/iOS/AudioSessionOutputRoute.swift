#if os(iOS)
    @preconcurrency import AVFoundation
    import Foundation

    typealias PlatformAudioOutputRoute = AudioSessionOutputRoute

    /// The iOS audio output, through `AVAudioSession`. A compiling stub until the iOS platform layer task.
    @MainActor
    final class AudioSessionOutputRoute: AudioOutputRoute {
        init() {}

        func startMonitoring(
            binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
            onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void
        ) {}

        func stopMonitoring() {}

        nonisolated static func currentOutputLatency() -> TimeInterval? { nil }
    }
#endif
