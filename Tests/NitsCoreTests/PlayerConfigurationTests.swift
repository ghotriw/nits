import Foundation
import Testing

@testable import NitsCore

@Suite("PlayerConfiguration & Launch Arguments Tests")
struct PlayerConfigurationTests {

    @Test("Default configuration enables tone mapping and auto render mode")
    func testDefaultConfiguration() {
        let config = PlayerConfiguration()
        #expect(config.enableToneMapping == true)
        #expect(config.defaultRenderMode == .auto)
        #expect(config.targetNits == 203.0)
        #expect(config.sharpness == 0.5)
        #expect(config.initialVolume == 1.0)
        #expect(config.enableOSD == true)
    }

    @Test("CLI arguments correctly parse tone mapping disable flag")
    func testParseDisableToneMapping() {
        let args = ["Nits", "--disable-tone-mapping", "/path/to/movie.mkv"]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)

        #expect(config.enableToneMapping == false)
        #expect(mediaPath == "/path/to/movie.mkv")
    }

    @Test("CLI arguments parse render mode, target nits, sharpness, and volume")
    func testParseCustomFlags() {
        let args = [
            "Nits",
            "--render-mode=system",
            "--target-nits=300",
            "--sharpness=0.8",
            "--volume=0.4",
            "video.mp4",
        ]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)

        #expect(config.defaultRenderMode == .system)
        #expect(config.targetNits == 300.0)
        #expect(config.sharpness == 0.8)
        #expect(config.initialVolume == 0.4)
        #expect(mediaPath == "video.mp4")
    }

    @Test("Engine respects isToneMappingPermitted=false even on SDR display")
    @MainActor
    func testEngineToneMappingDisabled() {
        let config = PlayerConfiguration(enableToneMapping: false, defaultRenderMode: .auto)
        let engine = PlayerEngine(configuration: config)

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

    @Test("CLI arguments correctly parse HTTP headers and network URL")
    func testParseHTTPHeadersAndURL() {
        let args = [
            "Nits",
            "--header=X-Api-Key: test-api-key-12345",
            "--header",
            "Authorization: Bearer token-xyz",
            "https://stream.example.com/videos/123/stream.mkv",
        ]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)

        #expect(mediaPath == "https://stream.example.com/videos/123/stream.mkv")
        #expect(config.httpHeaders["X-Api-Key"] == "test-api-key-12345")
        #expect(config.httpHeaders["Authorization"] == "Bearer token-xyz")
    }

    @Test("CLI arguments correctly parse start-time and resume flags")
    func testParseStartTimeAndResumeFlags() {
        let args = [
            "Nits",
            "--start-time=124.5",
            "--no-resume",
            "movie.mkv",
        ]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)

        #expect(mediaPath == "movie.mkv")
        #expect(config.startTime == 124.5)
        #expect(config.resumePlayback == false)
    }

    @Test("CLI arguments correctly parse subtitle font name")
    func testParseSubtitleFontFlag() {
        let args = ["Nits", "--subtitle-font=Helvetica Neue", "movie.mkv"]
        let (config, _) = PlayerConfiguration.parse(arguments: args)
        #expect(config.subtitleFontName == "Helvetica Neue")
    }

    @Test("UserDefaults roundtrip preserves subtitle font name")
    func testUserDefaultsSubtitleFont() {
        let defaults = UserDefaults(suiteName: "test.subtitle.font")!
        defaults.removePersistentDomain(forName: "test.subtitle.font")
        var config = PlayerConfiguration()
        config.subtitleFontName = "Avenir Next"
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.subtitleFontName == "Avenir Next")
    }

    @Test("CLI arguments correctly parse subtitle font weight")
    func testParseSubtitleWeightFlag() {
        let args = ["Nits", "--subtitle-weight=bold", "movie.mkv"]
        let (config, _) = PlayerConfiguration.parse(arguments: args)
        #expect(config.subtitleFontWeight == "bold")
    }

    @Test("UserDefaults roundtrip preserves subtitle font weight")
    func testUserDefaultsSubtitleWeight() {
        let defaults = UserDefaults(suiteName: "test.subtitle.weight")!
        defaults.removePersistentDomain(forName: "test.subtitle.weight")
        var config = PlayerConfiguration()
        config.subtitleFontWeight = "Heavy"
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.subtitleFontWeight == "Heavy")
    }

    @Test("CLI arguments correctly parse audio-track and subtitle-track flags")
    func testParseTrackFlags() {
        let args = ["Nits", "--audio-track=jpn", "--subtitle-track", "off", "/tmp/movie.mkv"]
        let config = PlayerConfiguration.parse(arguments: args).configuration
        #expect(config.audioTrack == "jpn")
        #expect(config.subtitleTrack == "off")
    }

    @Test("UserDefaults roundtrip preserves enableOSD flag")
    func testUserDefaultsOSD() {
        let defaults = UserDefaults(suiteName: "test.osd.flag")!
        defaults.removePersistentDomain(forName: "test.osd.flag")
        var config = PlayerConfiguration()
        config.enableOSD = false
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.enableOSD == false)
    }

    @Test("CLI arguments correctly parse OSD disable and enable flags")
    func testParseOSDFlags() {
        let argsDisable = ["Nits", "--no-osd", "movie.mkv"]
        let (configDisabled, _) = PlayerConfiguration.parse(arguments: argsDisable)
        #expect(configDisabled.enableOSD == false)

        let argsEnable = ["Nits", "--enable-osd", "movie.mkv"]
        let (configEnabled, _) = PlayerConfiguration.parse(
            arguments: argsEnable,
            base: PlayerConfiguration(enableOSD: false)
        )
        #expect(configEnabled.enableOSD == true)
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
        let defaults = UserDefaults(suiteName: "test.debug.osd")!
        defaults.removePersistentDomain(forName: "test.debug.osd")
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

    @Test("CLI arguments parse debug OSD flags and clamp duration")
    func testParseFlags() {
        let args = ["Nits", "--debug-osd", "--debug-osd-level=info", "--debug-osd-duration=500", "movie.mkv"]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)
        #expect(config.enableDebugOSD == true)
        #expect(config.debugOSDMinimumLevel == .info)
        #expect(config.debugOSDDuration == 60.0)
        #expect(mediaPath == "movie.mkv")

        let (disabled, _) = PlayerConfiguration.parse(
            arguments: ["Nits", "--no-debug-osd", "--debug-osd-level=bogus"],
            base: PlayerConfiguration(enableDebugOSD: true)
        )
        #expect(disabled.enableDebugOSD == false)
        #expect(disabled.debugOSDMinimumLevel == .warning)
    }
}

@Suite("OSD Duration Configuration Tests")
struct OSDDurationConfigurationTests {
    @Test("CLI argument parses and clamps OSD duration")
    func testParseOSDDuration() {
        let (config, _) = PlayerConfiguration.parse(arguments: ["Nits", "--osd-duration=2.5"])
        #expect(config.osdDuration == 2.5)

        let (tooLong, _) = PlayerConfiguration.parse(arguments: ["Nits", "--osd-duration=99"])
        #expect(tooLong.osdDuration == 10.0)

        let (tooShort, _) = PlayerConfiguration.parse(arguments: ["Nits", "--osd-duration=0"])
        #expect(tooShort.osdDuration == 0.5)
    }
}
