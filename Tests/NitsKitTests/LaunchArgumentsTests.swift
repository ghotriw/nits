import Foundation
import NitsCore
import NitsKit
import NitsTestSupport
import NitsUI
import Testing

@Suite("Launch arguments")
struct LaunchArgumentsTests {
    private func parse(_ arguments: [String], base: PlayerConfiguration = PlayerConfiguration()) -> (
        configuration: PlayerConfiguration, mediaPath: String?
    ) {
        let launch = LaunchArguments(arguments)
        return (launch.applied(to: base), launch.mediaPath)
    }

    private func settings(_ arguments: [String], base: AppSettings = AppSettings()) -> AppSettings {
        LaunchArguments(arguments).applied(to: base)
    }

    @Test("Tone mapping flags and the media path")
    func testParseDisableToneMapping() {
        let (config, mediaPath) = parse(["Nits", "--disable-tone-mapping", "/path/to/movie.mkv"])
        #expect(config.enableToneMapping == false)
        #expect(mediaPath == "/path/to/movie.mkv")
    }

    @Test("Render mode, target nits, sharpness, and volume")
    func testParseCustomFlags() {
        let (config, mediaPath) = parse([
            "Nits", "--render-mode=system", "--target-nits=300", "--sharpness=0.8", "--volume=0.4", "video.mp4",
        ])
        #expect(config.defaultRenderMode == .system)
        #expect(config.targetNits == 300.0)
        #expect(config.sharpness == 0.8)
        #expect(config.initialVolume == 0.4)
        #expect(mediaPath == "video.mp4")
    }

    @Test("Dolby Vision trims and local contrast, clamped to 0 ... 1")
    func testToneMappingTuning() {
        #expect(parse(["Nits", "--dovi-trims"]).configuration.applyDolbyVisionTrims)
        #expect(
            !parse(["Nits", "--no-dovi-trims"], base: PlayerConfiguration(applyDolbyVisionTrims: true)).configuration
                .applyDolbyVisionTrims)
        #expect(parse(["Nits", "--local-contrast=0.75"]).configuration.localContrast == 0.75)
        #expect(parse(["Nits", "--local-contrast=3"]).configuration.localContrast == 1)
    }

    @Test("HTTP headers in both spellings and a network URL")
    func testParseHTTPHeadersAndURL() {
        let launch = LaunchArguments([
            "Nits",
            "--header=X-Api-Key: test-api-key-12345",
            "--header",
            "Authorization: Bearer token-xyz",
            "https://stream.example.com/videos/123/stream.mkv",
        ])
        #expect(launch.mediaPath == "https://stream.example.com/videos/123/stream.mkv")
        #expect(launch.headers["X-Api-Key"] == "test-api-key-12345")
        #expect(launch.headers["Authorization"] == "Bearer token-xyz")
    }

    @Test("Recent media flags")
    func testParseRecentMedia() {
        #expect(settings(["nits", "--no-recent-media"]).rememberRecentMedia == false)
        let disabled = AppSettings(rememberRecentMedia: false)
        #expect(settings(["nits", "--recent-media"], base: disabled).rememberRecentMedia)
    }

    @Test("A `-Key value` default for the session is no media path, and the media after it still is")
    func testArgumentDomainPairs() {
        let arguments = [
            "Nits", "-NSDocumentRevisionsDebugMode", "YES", "-AppleLanguages", "(uk)", "--no-osd", "/tmp/movie.mkv",
        ]
        #expect(LaunchArguments(arguments).mediaPath == "/tmp/movie.mkv")
        #expect(settings(arguments).enableOSD == false)
        #expect(LaunchArguments(["Nits", "-AppleLanguages", "(uk)"]).mediaPath == nil)
    }

    @Test("Start time, resume, and the audio and subtitle tracks")
    func testParseStartTimeResumeAndTracks() {
        let arguments = [
            "Nits", "--start-time=124.5", "--no-resume", "--audio-track=jpn", "--subtitle-track", "off", "movie.mkv",
        ]
        let launch = LaunchArguments(arguments)
        #expect(launch.mediaPath == "movie.mkv")
        #expect(launch.startTime == 124.5)
        #expect(launch.audioTrack == "jpn")
        #expect(launch.subtitleTrack == "off")
        #expect(parse(arguments).configuration.resumePlayback == false)
        #expect(LaunchArguments(["Nits", "--start-time", "-3"]).startTime == 0)
        #expect(LaunchArguments(["Nits", "--audio-track= "]).audioTrack == nil)
    }

    @Test("Subtitle font name and weight")
    func testParseSubtitleFont() {
        let (config, _) = parse(["Nits", "--subtitle-font=Helvetica Neue", "--subtitle-weight=bold", "movie.mkv"])
        #expect(config.subtitleFontName == "Helvetica Neue")
        #expect(config.subtitleFontWeight == "bold")
    }

    @Test("OSD flags and a clamped OSD duration")
    func testParseOSD() {
        #expect(settings(["Nits", "--no-osd", "movie.mkv"]).enableOSD == false)
        #expect(settings(["Nits", "--enable-osd"], base: AppSettings(enableOSD: false)).enableOSD)
        #expect(settings(["Nits", "--osd-duration=2.5"]).osdDuration == 2.5)
        #expect(settings(["Nits", "--osd-duration=99"]).osdDuration == 10.0)
        #expect(settings(["Nits", "--osd-duration=0"]).osdDuration == 0.5)
    }

    @Test("Debug OSD flags; an unknown level is ignored and the duration clamped")
    func testParseDebugOSD() {
        let enabled = settings(["Nits", "--debug-osd", "--debug-osd-level=info", "--debug-osd-duration=500"])
        #expect(enabled.enableDebugOSD == true)
        #expect(enabled.debugOSDMinimumLevel == .info)
        #expect(enabled.debugOSDDuration == 60.0)

        let disabled = settings(
            ["Nits", "--no-debug-osd", "--debug-osd-level=bogus"], base: AppSettings(enableDebugOSD: true))
        #expect(disabled.enableDebugOSD == false)
        #expect(disabled.debugOSDMinimumLevel == .warning)
    }

    @Test("Network thumbnail policy flags")
    func testParseNetworkThumbnails() {
        #expect(parse(["app", "--network-thumbnails=always"]).configuration.networkThumbnailPolicy == .always)
        #expect(parse(["app", "--no-network-thumbnails"]).configuration.networkThumbnailPolicy == .never)
        #expect(
            parse(["app", "--network-thumbnails=lan"], base: PlayerConfiguration(networkThumbnailPolicy: .always))
                .configuration.networkThumbnailPolicy == .localNetworkOnly)
    }

    @Test("yt-dlp and SponsorBlock flags")
    func testParseYTDLP() {
        let parsed = settings(["Nits", "--no-ytdl", "--ytdl-path=/opt/yt-dlp", "--no-sponsorblock"])
        #expect(parsed.resolvesWithYTDLP == false)
        #expect(parsed.ytdlpPath == "/opt/yt-dlp")
        #expect(parsed.sponsorBlock == false)
        #expect(settings(["Nits", "--sponsorblock"], base: AppSettings(sponsorBlock: false)).sponsorBlock)
    }

    @Test("A later flag for the same setting wins")
    func testLaterFlagWins() {
        #expect(settings(["Nits", "--no-osd", "--osd"]).enableOSD == true)
        #expect(parse(["Nits", "--target-nits=300", "--target-nits-scale=2"]).configuration.targetNitsScale == 2)
    }

    @Test("Flags stay over the saved settings until the user changes the same setting")
    func testOverridesDropWhenTheSettingChanges() {
        let arguments = ["Nits", "--no-osd", "--no-tone-mapping", "--no-ytdl"]
        var launch = LaunchArguments(arguments)
        let configurationAtLaunch = PlayerConfiguration()
        let settingsAtLaunch = AppSettings(ytdlpPath: "/opt/yt-dlp")

        // Other settings change: every flag still applies.
        var savedConfiguration = configurationAtLaunch
        savedConfiguration.seekStepSeconds = 10
        launch.dropOverrides(changedFrom: configurationAtLaunch, to: savedConfiguration)
        var savedSettings = settingsAtLaunch
        savedSettings.osdDuration = 3
        launch.dropOverrides(changedFrom: settingsAtLaunch, to: savedSettings)
        #expect(launch.applied(to: savedConfiguration).seekStepSeconds == 10)
        #expect(launch.applied(to: savedConfiguration).enableToneMapping == false)
        var settings = launch.applied(to: savedSettings)
        #expect(settings.osdDuration == 3)
        #expect(settings.enableOSD == false)
        #expect(settings.resolvesWithYTDLP == false)
        #expect(settings.ytdlpPath == "/opt/yt-dlp")

        // The user turns the OSD off and on again in Settings: their choice wins from the first change on.
        var turnedOff = savedSettings
        turnedOff.enableOSD = false
        launch.dropOverrides(changedFrom: savedSettings, to: turnedOff)
        var turnedOn = turnedOff
        turnedOn.enableOSD = true
        launch.dropOverrides(changedFrom: turnedOff, to: turnedOn)
        settings = launch.applied(to: turnedOn)
        #expect(settings.enableOSD == true)
        #expect(settings.resolvesWithYTDLP == false)
        #expect(launch.applied(to: savedConfiguration).enableToneMapping == false)
    }
}
