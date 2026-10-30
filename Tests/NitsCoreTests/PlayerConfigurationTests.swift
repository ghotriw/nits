import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("PlayerConfiguration Tests")
struct PlayerConfigurationTests {

    @Test("Default configuration enables tone mapping and auto render mode")
    func testDefaultConfiguration() {
        let config = PlayerConfiguration()
        #expect(config.enableToneMapping == true)
        #expect(config.defaultRenderMode == .auto)
        #expect(config.targetNits == ToneMapController.referenceWhiteNits)
        #expect(config.sharpness == 0.5)
        #expect(config.initialVolume == 1.0)
        #expect(config.enableOSD == true)
    }

    @Test("Engine respects isToneMappingPermitted=false even on SDR display")
    @MainActor
    func testEngineToneMappingDisabled() {
        let config = PlayerConfiguration(enableToneMapping: false, defaultRenderMode: .auto)
        let engine = PlayerEngine.makeForTesting(configuration: config)

        engine.isHDRDisplay = false  // Normally triggers .metalToneMap in auto mode
        #expect(engine.isToneMappingPermitted == false)
        #expect(engine.activeRenderMode == .system)

        // Attempting to manually switch to metalToneMap when prohibited remains system
        engine.renderMode = .metalToneMap
        #expect(engine.activeRenderMode == .system)

        // Re-enabling tone mapping dynamically restores metalToneMap
        engine.isToneMappingPermitted = true
        #expect(engine.activeRenderMode == .metalToneMap)
    }

    @Test("Picture in Picture forces the display-layer render mode and restores it on exit")
    @MainActor
    func testPictureInPictureForcesSystemRenderMode() {
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration())
        engine.renderMode = .metalToneMap
        #expect(engine.activeRenderMode == .metalToneMap)

        // PiP only mirrors the AVSampleBufferDisplayLayer, never the Metal layer.
        engine.isPictureInPictureActive = true
        #expect(engine.activeRenderMode == .system)

        engine.isPictureInPictureActive = false
        #expect(engine.activeRenderMode == .metalToneMap)
    }

    @Test("UserDefaults roundtrip preserves subtitle font name")
    func testUserDefaultsSubtitleFont() {
        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.subtitleFontName = "Avenir Next"
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.subtitleFontName == "Avenir Next")
    }

    @Test("UserDefaults roundtrip preserves subtitle font weight")
    func testUserDefaultsSubtitleWeight() {
        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.subtitleFontWeight = "Heavy"
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.subtitleFontWeight == "Heavy")
    }

    @Test("Dolby Vision trims default off and persist")
    func testDolbyVisionTrimsSetting() {
        #expect(PlayerConfiguration().applyDolbyVisionTrims == false)

        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.applyDolbyVisionTrims = true
        config.saveToUserDefaults(userDefaults: defaults)
        #expect(PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults).applyDolbyVisionTrims == true)
    }

    @Test("Local contrast defaults to the fitted strength and persists")
    func testLocalContrastSetting() {
        #expect(PlayerConfiguration().localContrast == ToneMapController.defaultLocalContrast)

        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.localContrast = 0
        config.saveToUserDefaults(userDefaults: defaults)
        #expect(PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults).localContrast == 0)
    }

    @Test("Picture in Picture defaults hide the window and stay opt-in")
    func testPictureInPictureDefaults() {
        let config = PlayerConfiguration()
        #expect(config.pictureInPictureWindowBehavior == .hide)
        #expect(config.pausesOnPictureInPicture == false)
        #expect(config.entersPictureInPictureOnMinimize == false)
    }

    @Test("UserDefaults roundtrip preserves Picture in Picture settings")
    func testUserDefaultsPictureInPicture() {
        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.pictureInPictureWindowBehavior = .doNothing
        config.pausesOnPictureInPicture = true
        config.entersPictureInPictureOnMinimize = true
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.pictureInPictureWindowBehavior == .doNothing)
        #expect(loaded.pausesOnPictureInPicture == true)
        #expect(loaded.entersPictureInPictureOnMinimize == true)
    }

    @Test("UserDefaults roundtrip preserves action button settings and clamps the duration")
    func testUserDefaultsActionButton() {
        let defaults = InMemoryUserDefaults()
        #expect(PlayerConfiguration().actionButtonDisplayDuration == 8.0)
        #expect(PlayerConfiguration().actionButtonAutoPress == false)

        var config = PlayerConfiguration()
        config.actionButtonDisplayDuration = 15
        config.actionButtonAutoPress = true
        config.saveToUserDefaults(userDefaults: defaults)
        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.actionButtonDisplayDuration == 15)
        #expect(loaded.actionButtonAutoPress == true)

        defaults.set(0.5, forKey: PlayerConfiguration.keyActionButtonDisplayDuration)
        #expect(PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults).actionButtonDisplayDuration == 3)
        defaults.set(Double.infinity, forKey: PlayerConfiguration.keyActionButtonDisplayDuration)
        #expect(PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults).actionButtonDisplayDuration == 8)
    }

    @Test("UserDefaults roundtrip preserves enableOSD flag")
    func testUserDefaultsOSD() {
        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.enableOSD = false
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.enableOSD == false)
    }

}

@Suite("Debug OSD Configuration Tests")
struct DebugOSDConfigurationTests {
    @Test("Debug OSD is disabled by default")
    func testDefaults() {
        let config = PlayerConfiguration()
        #expect(config.enableDebugOSD == false)
        #expect(config.debugOSDMinimumLevel == .warning)
        #expect(config.debugOSDDuration == 4.0)
        #expect(config.osdDuration == 1.3)
    }

    @Test("UserDefaults roundtrip preserves debug OSD settings")
    func testUserDefaultsRoundtrip() {
        let defaults = InMemoryUserDefaults()
        var config = PlayerConfiguration()
        config.enableDebugOSD = true
        config.debugOSDMinimumLevel = .debug
        config.debugOSDDuration = 10.0
        config.osdDuration = 3.0
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.enableDebugOSD == true)
        #expect(loaded.debugOSDMinimumLevel == .debug)
        #expect(loaded.debugOSDDuration == 10.0)
        #expect(loaded.osdDuration == 3.0)
    }
}
