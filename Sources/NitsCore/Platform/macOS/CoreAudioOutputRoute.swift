#if os(macOS)
    @preconcurrency import AVFoundation
    import CoreAudio
    import Foundation

    typealias PlatformAudioOutputRoute = CoreAudioOutputRoute

    /// Follows the system-wide default output device through CoreAudio (e.g. AirPods connecting or disconnecting):
    /// moves the renderer to the new device by its UID.
    final class CoreAudioOutputRoute: AudioOutputRoute {
        private var listenerBlock: AudioObjectPropertyListenerBlock?
        private var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        private let queue = DispatchQueue.main

        init() {}

        func startMonitoring(binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void) {
            stopMonitoring()

            let block: AudioObjectPropertyListenerBlock = { [weak self, weak renderer] _, _ in
                guard self != nil else { return }
                let newUID = Self.fetchDefaultOutputDeviceUID()
                MainActor.assumeIsolated {
                    AppLog.info(
                        .audio, "Default audio output device changed (UID: \(newUID ?? "nil [system default]"))")
                    renderer?.audioOutputDeviceUniqueID = newUID
                    onChange()
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

        func stopMonitoring() {
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
        nonisolated static func fetchDefaultOutputDeviceUID() -> String? {
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

        /// Output latency of the current default output device in seconds: device and first output stream latency,
        /// safety offset and IO buffer, i.e. the time from handing a sample to the device until it is audible.
        /// `nil` when the device cannot be queried.
        nonisolated static func currentOutputLatency() -> TimeInterval? {
            guard let deviceID = fetchDefaultOutputDeviceID() else { return nil }

            func outputProperty<T: BitwiseCopyable>(
                _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T
            )
                -> Bool
            {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<T>.size)
                return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
            }

            var sampleRate = Float64(0)
            guard outputProperty(deviceID, kAudioDevicePropertyNominalSampleRate, &sampleRate), sampleRate > 0 else {
                return nil
            }
            var deviceLatency = UInt32(0)
            var safetyOffset = UInt32(0)
            var bufferFrames = UInt32(0)
            _ = outputProperty(deviceID, kAudioDevicePropertyLatency, &deviceLatency)
            _ = outputProperty(deviceID, kAudioDevicePropertySafetyOffset, &safetyOffset)
            _ = outputProperty(deviceID, kAudioDevicePropertyBufferFrameSize, &bufferFrames)

            var streamLatency = UInt32(0)
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize = UInt32(0)
            if AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
                streamsSize >= UInt32(MemoryLayout<AudioStreamID>.size)
            {
                var firstStream = AudioStreamID(0)
                var firstSize = UInt32(MemoryLayout<AudioStreamID>.size)
                if AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &firstSize, &firstStream) == noErr {
                    _ = outputProperty(firstStream, kAudioStreamPropertyLatency, &streamLatency)
                }
            }

            let totalFrames =
                Float64(deviceLatency) + Float64(safetyOffset) + Float64(bufferFrames) + Float64(streamLatency)
            return totalFrames / sampleRate
        }

        nonisolated private static func fetchDefaultOutputDeviceID() -> AudioDeviceID? {
            var deviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
            guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
            return deviceID
        }
    }
#endif
