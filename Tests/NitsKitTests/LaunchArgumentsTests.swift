import Foundation
import NitsCore
import NitsKit
import NitsTestSupport
import Testing

@Suite("Launch arguments")
struct LaunchArgumentsTests {
    private func parse(_ arguments: [String], base: PlayerConfiguration = PlayerConfiguration()) -> (
        configuration: PlayerConfiguration, mediaPath: String?
    ) {
        let launch = LaunchArguments(arguments)
        return (launch.applied(to: base), launch.mediaPath)
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
        let (config, mediaPath) = parse([
            "Nits",
            "--header=X-Api-Key: test-api-key-12345",
            "--header",
            "Authorization: Bearer token-xyz",
            "https://stream.example.com/videos/123/stream.mkv",
        ])
        #expect(mediaPath == "https://stream.example.com/videos/123/stream.mkv")
        #expect(config.httpHeaders["X-Api-Key"] == "test-api-key-12345")
        #expect(config.httpHeaders["Authorization"] == "Bearer token-xyz")
    }

    @Test("Recent media flags")
    func testParseRecentMedia() {
        #expect(parse(["nits", "--no-recent-media"]).configuration.rememberRecentMedia == false)
        #expect(
            parse(["nits", "--recent-media"], base: PlayerConfiguration(rememberRecentMedia: false)).configuration
                .rememberRecentMedia)
    }

    @Test("A `-Key value` default for the session is no media path, and the media after it still is")
    func testArgumentDomainPairs() {
        let (config, mediaPath) = parse([
            "Nits", "-NSDocumentRevisionsDebugMode", "YES", "-AppleLanguages", "(uk)", "--no-osd", "/tmp/movie.mkv",
        ])
        #expect(mediaPath == "/tmp/movie.mkv")
        #expect(config.enableOSD == false)
        #expect(parse(["Nits", "-AppleLanguages", "(uk)"]).mediaPath == nil)
    }

    @Test("Start time, resume, and the audio and subtitle tracks")
    func testParseStartTimeResumeAndTracks() {
        let (config, mediaPath) = parse([
            "Nits", "--start-time=124.5", "--no-resume", "--audio-track=jpn", "--subtitle-track", "off", "movie.mkv",
        ])
        #expect(mediaPath == "movie.mkv")
        #expect(config.startTime == 124.5)
        #expect(config.resumePlayback == false)
        #expect(config.audioTrack == "jpn")
        #expect(config.subtitleTrack == "off")
    }

    @Test("Subtitle font name and weight")
    func testParseSubtitleFont() {
        let (config, _) = parse(["Nits", "--subtitle-font=Helvetica Neue", "--subtitle-weight=bold", "movie.mkv"])
        #expect(config.subtitleFontName == "Helvetica Neue")
        #expect(config.subtitleFontWeight == "bold")
    }

    @Test("OSD flags and a clamped OSD duration")
    func testParseOSD() {
        #expect(parse(["Nits", "--no-osd", "movie.mkv"]).configuration.enableOSD == false)
        #expect(parse(["Nits", "--enable-osd"], base: PlayerConfiguration(enableOSD: false)).configuration.enableOSD)
        #expect(parse(["Nits", "--osd-duration=2.5"]).configuration.osdDuration == 2.5)
        #expect(parse(["Nits", "--osd-duration=99"]).configuration.osdDuration == 10.0)
        #expect(parse(["Nits", "--osd-duration=0"]).configuration.osdDuration == 0.5)
    }

    @Test("Debug OSD flags; an unknown level is ignored and the duration clamped")
    func testParseDebugOSD() {
        let (config, mediaPath) = parse([
            "Nits", "--debug-osd", "--debug-osd-level=info", "--debug-osd-duration=500", "movie.mkv",
        ])
        #expect(config.enableDebugOSD == true)
        #expect(config.debugOSDMinimumLevel == .info)
        #expect(config.debugOSDDuration == 60.0)
        #expect(mediaPath == "movie.mkv")

        let (disabled, _) = parse(
            ["Nits", "--no-debug-osd", "--debug-osd-level=bogus"], base: PlayerConfiguration(enableDebugOSD: true))
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
        let (config, _) = parse(["Nits", "--no-ytdl", "--ytdl-path=/opt/yt-dlp", "--no-sponsorblock"])
        #expect(config.resolvesWithYTDLP == false)
        #expect(config.ytdlpPath == "/opt/yt-dlp")
        #expect(config.sponsorBlock == false)
        #expect(
            parse(["Nits", "--sponsorblock"], base: PlayerConfiguration(sponsorBlock: false)).configuration.sponsorBlock
        )
    }

    @Test("A later flag for the same setting wins")
    func testLaterFlagWins() {
        #expect(parse(["Nits", "--no-osd", "--osd"]).configuration.enableOSD == true)
        #expect(parse(["Nits", "--target-nits=300", "--target-nits-scale=2"]).configuration.targetNitsScale == 2)
    }

    @Test("Flags stay over the saved settings until the user changes the same setting")
    func testOverridesDropWhenTheSettingChanges() {
        let arguments = ["Nits", "--no-osd", "--no-tone-mapping", "--no-ytdl", "--header=Referer: https://example.com"]
        var launch = LaunchArguments(arguments)
        let atLaunch = PlayerConfiguration(ytdlpPath: "/opt/yt-dlp")

        // Another setting changes: every flag still applies.
        var saved = atLaunch
        saved.seekStepSeconds = 10
        launch.dropOverrides(changedFrom: atLaunch, to: saved)
        var configuration = launch.applied(to: saved)
        #expect(configuration.seekStepSeconds == 10)
        #expect(configuration.enableOSD == false)
        #expect(configuration.enableToneMapping == false)
        #expect(configuration.resolvesWithYTDLP == false)
        #expect(configuration.ytdlpPath == "/opt/yt-dlp")
        #expect(configuration.httpHeaders["Referer"] == "https://example.com")

        // The user turns the OSD off and on again in Settings: their choice wins from the first change on.
        var turnedOff = saved
        turnedOff.enableOSD = false
        launch.dropOverrides(changedFrom: saved, to: turnedOff)
        var turnedOn = turnedOff
        turnedOn.enableOSD = true
        launch.dropOverrides(changedFrom: turnedOff, to: turnedOn)
        configuration = launch.applied(to: turnedOn)
        #expect(configuration.enableOSD == true)
        #expect(configuration.enableToneMapping == false)
        #expect(configuration.httpHeaders["Referer"] == "https://example.com")
    }
}
