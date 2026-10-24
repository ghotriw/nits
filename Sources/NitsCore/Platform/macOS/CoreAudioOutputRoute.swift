#if os(macOS)
    @preconcurrency import AVFoundation
    import CoreAudio
    import Foundation
    import os

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

        func startMonitoring(
            binding renderer: AVSampleBufferAudioRenderer, onChange: @escaping @MainActor () -> Void,
            onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void
        ) {
            stopMonitoring()
            self.onRunningChange = onRunningChange

            let block: AudioObjectPropertyListenerBlock = { [weak self, weak renderer] _, _ in
                guard self != nil else { return }
                let newUID = Self.fetchDefaultOutputDeviceUID()
                MainActor.assumeIsolated {
                    AppLog.info(
                        .audio, "Default audio output device changed (UID: \(newUID ?? "nil [system default]"))")
                    renderer?.audioOutputDeviceUniqueID = newUID
                    // The previous device's events stop before `onChange` forgets its runs, and the new one's start
                    // after: neither ends up on the wrong side of it.
                    self?.unwatchOutputDevice()
                    onChange()
                    self?.watchDefaultOutputDevice()
                }
            }
            self.listenerBlock = block
            watchDefaultOutputDevice()

            var address = propertyAddress
            _ = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
        }

        func stopMonitoring() {
            unwatchOutputDevice()
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

        // MARK: - Output device running state

        /// Watched on the current output device and passed to `onRunningChange`: a Bluetooth device that restarts its
        /// IO right after playback starts (switching from a placeholder to the real A2DP stream) leaves the renderer's
        /// audio queue behind the clock (see `AudioOutputInterruptionDetector`).
        nonisolated private static var deviceIsRunningAddress: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunning, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
        }

        /// Not the main queue: the synchronizer's `setRate` on the main thread can wait for the audio queue to start,
        /// and the start waits for the HAL to deliver the device's running-state change to its listeners. A listener
        /// on the main queue deadlocked the two until the start timed out after 15 s (seen after seeks on AirPods).
        private static let deviceListenerQueue = DispatchQueue(label: "com.nits.audio-output-device-listener")

        private var watchedDevice: AudioDeviceID?
        private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
        private var onRunningChange: (@Sendable (_ isRunning: Bool) -> Void)?
        /// The device whose events go to `onRunningChange`; `nil` while none is watched. Removing a listener doesn't
        /// cancel the blocks it already queued: a listener passes its event on, under this lock, only for this device.
        private let reportedDevice = OSAllocatedUnfairLock<AudioDeviceID?>(initialState: nil)

        private func watchDefaultOutputDevice() {
            unwatchOutputDevice()
            guard let deviceID = Self.fetchDefaultOutputDeviceID(), let onRunningChange else { return }
            reportedDevice.withLock { $0 = deviceID }
            let block = Self.makeDeviceListener(
                for: deviceID, reportedDevice: reportedDevice, onRunningChange: onRunningChange)
            var address = Self.deviceIsRunningAddress
            _ = AudioObjectAddPropertyListenerBlock(deviceID, &address, Self.deviceListenerQueue, block)
            watchedDevice = deviceID
            deviceListenerBlock = block
        }

        private func unwatchOutputDevice() {
            reportedDevice.withLock { $0 = nil }
            guard let deviceID = watchedDevice, let block = deviceListenerBlock else { return }
            var address = Self.deviceIsRunningAddress
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, Self.deviceListenerQueue, block)
            watchedDevice = nil
            deviceListenerBlock = nil
        }

        /// Built outside the main actor: a closure formed in an isolated method would be main-actor isolated, and the
        /// runtime traps when the HAL calls it on `deviceListenerQueue`.
        nonisolated private static func makeDeviceListener(
            for deviceID: AudioDeviceID, reportedDevice: OSAllocatedUnfairLock<AudioDeviceID?>,
            onRunningChange: @escaping @Sendable (_ isRunning: Bool) -> Void
        ) -> AudioObjectPropertyListenerBlock {
            { @Sendable _, _ in
                guard let isRunning = isDeviceRunning(deviceID) else { return }
                AppLog.debug(.audio, "Output device \(deviceID) \(isRunning ? "started" : "stopped") its IO")
                // Held across the call, so a device change can't come in between the check and the report.
                reportedDevice.withLock { current in
                    guard current == deviceID else { return }
                    onRunningChange(isRunning)
                }
            }
        }

        nonisolated private static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool? {
            var address = deviceIsRunningAddress
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value != 0
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
