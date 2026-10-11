import CoreAudio
import Foundation

/// Monitors system-wide default audio output device changes via CoreAudio
/// and notifies the player engine to migrate audio rendering pipelines (e.g. AirPods connection/disconnection).
@MainActor
public final class AudioDeviceRouteMonitor {
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let queue = DispatchQueue.main

    public init() {}

    public func startMonitoring(onRouteChange: @escaping @MainActor @Sendable (_ newDeviceUID: String?) -> Void) {
        stopMonitoring()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard self != nil else { return }
            let newUID = Self.fetchDefaultOutputDeviceUID()
            MainActor.assumeIsolated {
                onRouteChange(newUID)
            }
        }
        self.listenerBlock = block

        var address = propertyAddress
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
    }

    public func stopMonitoring() {
        guard let block = listenerBlock else { return }
        var address = propertyAddress
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        self.listenerBlock = nil
    }

    isolated deinit {
        stopMonitoring()
    }

    /// Queries CoreAudio for the unique identifier (UID) of the current default output device.
    nonisolated public static func fetchDefaultOutputDeviceUID() -> String? {
        var defaultDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        guard status == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceUID: Unmanaged<CFString>? = nil
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let uidStatus = AudioObjectGetPropertyData(
            defaultDeviceID,
            &uidAddress,
            0,
            nil,
            &uidSize,
            &deviceUID
        )
        guard uidStatus == noErr, let deviceUID else { return nil }
        return deviceUID.takeRetainedValue() as String
    }
}
