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
}
