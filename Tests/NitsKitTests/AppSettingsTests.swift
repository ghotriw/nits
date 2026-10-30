import Foundation
import NitsCore
import NitsTestSupport
import NitsUI
import Testing

@Suite("App settings")
struct AppSettingsTests {
    @Test("Defaults of every setting")
    func testDefaults() {
        let settings = AppSettings()
        #expect(settings.enableOSD == true)
        #expect(settings.osdDuration == 1.3)
        #expect(settings.enableDebugOSD == false)
        #expect(settings.debugOSDMinimumLevel == .warning)
        #expect(settings.debugOSDDuration == 4.0)
        #expect(settings.actionButtonDisplayDuration == 8.0)
        #expect(settings.actionButtonAutoPress == false)
        #expect(settings.rememberRecentMedia == true)
        #expect(settings.resolvesWithYTDLP == true)
        #expect(settings.ytdlpPath.isEmpty)
        #expect(settings.sponsorBlock == true)
        #expect(settings.pictureInPictureWindowBehavior == .hide)
        #expect(settings.pausesOnPictureInPicture == false)
        #expect(settings.entersPictureInPictureOnMinimize == false)
    }

    @Test("UserDefaults roundtrip preserves every setting")
    func testUserDefaultsRoundtrip() {
        let defaults = InMemoryUserDefaults()
        let settings = AppSettings(
            enableOSD: false, osdDuration: 3.0, enableDebugOSD: true, debugOSDMinimumLevel: .debug,
            debugOSDDuration: 10.0, actionButtonDisplayDuration: 15, actionButtonAutoPress: true,
            rememberRecentMedia: false, resolvesWithYTDLP: false, ytdlpPath: "/opt/yt-dlp", sponsorBlock: false,
            pictureInPictureWindowBehavior: .doNothing, pausesOnPictureInPicture: true,
            entersPictureInPictureOnMinimize: true)
        settings.saveToUserDefaults(userDefaults: defaults)
        #expect(AppSettings.loadFromUserDefaults(userDefaults: defaults) == settings)
    }

    @Test("Durations out of range are clamped, given or saved")
    func testClampedDurations() {
        let given = AppSettings(osdDuration: 99, debugOSDDuration: 0, actionButtonDisplayDuration: 500)
        #expect(given.osdDuration == 10)
        #expect(given.debugOSDDuration == 1)
        #expect(given.actionButtonDisplayDuration == 60)

        let defaults = InMemoryUserDefaults()
        defaults.set(0.5, forKey: AppSettings.keyActionButtonDisplayDuration)
        defaults.set(99.0, forKey: AppSettings.keyOSDDuration)
        defaults.set(500.0, forKey: AppSettings.keyDebugOSDDuration)
        var loaded = AppSettings.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.actionButtonDisplayDuration == 3)
        #expect(loaded.osdDuration == 10)
        #expect(loaded.debugOSDDuration == 60)

        defaults.set(Double.infinity, forKey: AppSettings.keyActionButtonDisplayDuration)
        loaded = AppSettings.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.actionButtonDisplayDuration == 8)
    }
}
