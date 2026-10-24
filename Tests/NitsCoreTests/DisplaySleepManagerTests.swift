import Foundation
import NitsCore
import Testing

@Suite("DisplaySleepManager Tests")
@MainActor
struct DisplaySleepManagerTests {
    @Test("Initial state has sleep enabled (assertion not held)")
    func testInitialState() {
        let manager = DisplaySleepManager()
        #expect(!manager.isSleepDisabled)
    }

    @Test("Disabling and enabling display sleep toggles assertion state")
    func testDisableAndEnable() {
        let manager = DisplaySleepManager(reason: "Test Playback Assertion")
        #expect(!manager.isSleepDisabled)

        manager.disableDisplaySleep()
        #expect(manager.isSleepDisabled)

        // Idempotent call
        manager.disableDisplaySleep()
        #expect(manager.isSleepDisabled)

        manager.enableDisplaySleep()
        #expect(!manager.isSleepDisabled)

        // Idempotent call
        manager.enableDisplaySleep()
        #expect(!manager.isSleepDisabled)
    }

    @Test("Update policy only blocks sleep when actively playing video")
    func testUpdatePolicy() {
        let manager = DisplaySleepManager()

        // 1. Playing video -> sleep disabled
        manager.update(isPlaying: true, hasVideo: true)
        #expect(manager.isSleepDisabled)

        // 2. Paused video -> sleep enabled
        manager.update(isPlaying: false, hasVideo: true)
        #expect(!manager.isSleepDisabled)

        // 3. Audio-only playing -> sleep enabled (do not block sleep for music)
        manager.update(isPlaying: true, hasVideo: false)
        #expect(!manager.isSleepDisabled)

        // 4. Resumed video -> sleep disabled
        manager.update(isPlaying: true, hasVideo: true)
        #expect(manager.isSleepDisabled)

        // 5. Cleanup
        manager.enableDisplaySleep()
        #expect(!manager.isSleepDisabled)
    }
}
