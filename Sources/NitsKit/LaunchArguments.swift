import Foundation
import NitsCore
import NitsUI

/// The command line of the app: the media to open and how (`--start-time=…`, `--header=…`), and the settings its
/// flags give (`--no-osd`), for the engine (`PlayerConfiguration`) and the app (`AppSettings`). The flags stand over
/// the saved settings for the session, each until the user changes that setting.
public struct LaunchArguments {
    /// One flag's setting: the value it sets, and how to tell the user changed that setting since.
    private struct Override<Settings> {
        let apply: (inout Settings) -> Void
        let differs: (Settings, Settings) -> Bool

        init<Value: Equatable>(_ keyPath: WritableKeyPath<Settings, Value>, _ value: Value) {
            apply = { $0[keyPath: keyPath] = value }
            differs = { $0[keyPath: keyPath] != $1[keyPath: keyPath] }
        }
    }

    /// The first argument that isn't a flag: a path or a URL.
    public private(set) var mediaPath: String?
    /// HTTP headers to open `mediaPath` with, when it is a URL.
    public private(set) var headers: [String: String] = [:]
    /// Where `mediaPath` starts, in seconds; given, even `0`, it overrides the position saved in the history.
    public private(set) var startTime: Double?
    /// The audio track `mediaPath` starts with: a track id (`0, 1…`), a container stream index (`stream:N` / `s:N`),
    /// or a language code or title fragment; given, it overrides the track saved in the history.
    public private(set) var audioTrack: String?
    /// The subtitle track `mediaPath` starts with, named as `audioTrack` is, or `off`.
    public private(set) var subtitleTrack: String?
    /// In the order given: a later flag for the same setting wins.
    private var configurationOverrides: [Override<PlayerConfiguration>] = []
    private var settingsOverrides: [Override<AppSettings>] = []

    public init(_ arguments: [String] = CommandLine.arguments) {
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]

            if arg == "--disable-tone-mapping" || arg == "--no-tone-mapping" {
                set(\.enableToneMapping, false)
            } else if arg == "--enable-tone-mapping" {
                set(\.enableToneMapping, true)
            } else if arg.starts(with: "--render-mode=") {
                let val = String(arg.dropFirst("--render-mode=".count)).lowercased()
                if val == "system" || val == "hdr" {
                    set(\.defaultRenderMode, .system)
                } else if val == "metal" || val == "sdr" || val == "tonemap" {
                    set(\.defaultRenderMode, .metalToneMap)
                } else {
                    set(\.defaultRenderMode, .auto)
                }
            } else if arg.starts(with: "--target-nits-scale=") {
                if let val = Float(arg.dropFirst("--target-nits-scale=".count)) {
                    set(\.targetNitsScale, max(0.1, min(4.0, val)))
                }
            } else if arg.starts(with: "--target-nits=") {
                if let val = Float(arg.dropFirst("--target-nits=".count)) {
                    set(\.targetNits, val)
                }
            } else if arg.starts(with: "--sharpness=") {
                if let val = Float(arg.dropFirst("--sharpness=".count)) {
                    set(\.sharpness, max(0.0, min(1.0, val)))
                }
            } else if arg == "--dovi-trims" {
                set(\.applyDolbyVisionTrims, true)
            } else if arg == "--no-dovi-trims" {
                set(\.applyDolbyVisionTrims, false)
            } else if arg.starts(with: "--local-contrast=") {
                if let val = Float(arg.dropFirst("--local-contrast=".count)) {
                    set(\.localContrast, max(0, min(1, val)))
                }
            } else if arg.starts(with: "--volume=") {
                if let val = Float(arg.dropFirst("--volume=".count)) {
                    set(\.initialVolume, max(0.0, min(1.0, val)))
                }
            } else if arg.starts(with: "--start-time=") {
                if let val = Double(arg.dropFirst("--start-time=".count)) {
                    startTime = max(0.0, val)
                }
            } else if arg == "--start-time" && i + 1 < arguments.count {
                i += 1
                if let val = Double(arguments[i]) {
                    startTime = max(0.0, val)
                }
            } else if arg.starts(with: "--audio-track=") {
                audioTrack = Self.nonEmpty(String(arg.dropFirst("--audio-track=".count)))
            } else if arg == "--audio-track" && i + 1 < arguments.count {
                i += 1
                audioTrack = Self.nonEmpty(arguments[i])
            } else if arg.starts(with: "--subtitle-track=") {
                subtitleTrack = Self.nonEmpty(String(arg.dropFirst("--subtitle-track=".count)))
            } else if arg == "--subtitle-track" && i + 1 < arguments.count {
                i += 1
                subtitleTrack = Self.nonEmpty(arguments[i])
            } else if arg == "--no-resume" || arg == "--disable-resume" {
                set(\.resumePlayback, false)
            } else if arg == "--resume" || arg == "--enable-resume" {
                set(\.resumePlayback, true)
            } else if arg == "--no-recent-media" || arg == "--disable-recent-media" {
                set(\.rememberRecentMedia, false)
            } else if arg == "--recent-media" || arg == "--enable-recent-media" {
                set(\.rememberRecentMedia, true)
            } else if arg == "--no-osd" || arg == "--disable-osd" {
                set(\.enableOSD, false)
            } else if arg == "--enable-osd" || arg == "--osd" {
                set(\.enableOSD, true)
            } else if arg.starts(with: "--osd-duration=") {
                if let val = Double(arg.dropFirst("--osd-duration=".count)) {
                    set(\.osdDuration, AppSettings.clampOSDDuration(val))
                }
            } else if arg == "--debug-osd" {
                set(\.enableDebugOSD, true)
            } else if arg == "--no-debug-osd" {
                set(\.enableDebugOSD, false)
            } else if arg.starts(with: "--debug-osd-level=") {
                let val = String(arg.dropFirst("--debug-osd-level=".count)).uppercased()
                if let level = LogLevel(rawValue: val) {
                    set(\.debugOSDMinimumLevel, level)
                }
            } else if arg.starts(with: "--debug-osd-duration=") {
                if let val = Double(arg.dropFirst("--debug-osd-duration=".count)) {
                    set(\.debugOSDDuration, AppSettings.clampDebugOSDDuration(val))
                }
            } else if arg == "--auto-load-folder" {
                set(\.autoLoadFolderMedia, true)
            } else if arg == "--no-auto-load-folder" || arg == "--disable-auto-load-folder" {
                set(\.autoLoadFolderMedia, false)
            } else if arg.starts(with: "--auto-load-folder=") {
                let val = String(arg.dropFirst("--auto-load-folder=".count)).lowercased()
                set(\.autoLoadFolderMedia, val == "true" || val == "1" || val == "yes")
            } else if arg.starts(with: "--subtitle-font=") {
                set(\.subtitleFontName, String(arg.dropFirst("--subtitle-font=".count)))
            } else if arg.starts(with: "--subtitle-weight=") {
                set(\.subtitleFontWeight, String(arg.dropFirst("--subtitle-weight=".count)))
            } else if arg.starts(with: "--network-thumbnails=") {
                let val = String(arg.dropFirst("--network-thumbnails=".count)).lowercased()
                if val == "always" || val == "all" || val == "true" {
                    set(\.networkThumbnailPolicy, .always)
                } else if val == "never" || val == "none" || val == "false" || val == "off" {
                    set(\.networkThumbnailPolicy, .never)
                } else if val == "lan" || val == "local" || val == "localnetwork" {
                    set(\.networkThumbnailPolicy, .localNetworkOnly)
                }
            } else if arg == "--no-ytdl" {
                set(\.resolvesWithYTDLP, false)
            } else if arg == "--ytdl" {
                set(\.resolvesWithYTDLP, true)
            } else if arg.starts(with: "--ytdl-path=") {
                set(\.ytdlpPath, String(arg.dropFirst("--ytdl-path=".count)))
            } else if arg == "--no-sponsorblock" {
                set(\.sponsorBlock, false)
            } else if arg == "--sponsorblock" {
                set(\.sponsorBlock, true)
            } else if arg == "--no-network-thumbnails" {
                set(\.networkThumbnailPolicy, .never)
            } else if arg == "--always-network-thumbnails" {
                set(\.networkThumbnailPolicy, .always)
            } else if arg.starts(with: "--header=") {
                addHeader(String(arg.dropFirst("--header=".count)))
            } else if arg == "--header" && i + 1 < arguments.count {
                i += 1
                addHeader(arguments[i])
            } else if arg.starts(with: "-") && !arg.starts(with: "--") {
                // `-Key value` sets a default for the session (`UserDefaults.argumentDomain`: Xcode's
                // `-NSDocumentRevisionsDebugMode YES`, `-AppleLanguages "(uk)"`): its value is no media.
                i += 1
            } else if !arg.starts(with: "-") && mediaPath == nil {
                mediaPath = arg
            }

            i += 1
        }
    }

    /// `saved` with the flags on top.
    public func applied(to saved: PlayerConfiguration) -> PlayerConfiguration {
        Self.apply(configurationOverrides, to: saved)
    }

    /// `saved` with the flags on top.
    public func applied(to saved: AppSettings) -> AppSettings {
        Self.apply(settingsOverrides, to: saved)
    }

    /// Drops the flags of the settings that differ between `previous` and `saved`: the user has changed them since,
    /// so their choice wins for the rest of the session.
    public mutating func dropOverrides(changedFrom previous: PlayerConfiguration, to saved: PlayerConfiguration) {
        configurationOverrides.removeAll { $0.differs(previous, saved) }
    }

    /// Drops the flags of the settings that differ between `previous` and `saved`; see the `PlayerConfiguration` one.
    public mutating func dropOverrides(changedFrom previous: AppSettings, to saved: AppSettings) {
        settingsOverrides.removeAll { $0.differs(previous, saved) }
    }

    private static func apply<Settings>(_ overrides: [Override<Settings>], to saved: Settings) -> Settings {
        var settings = saved
        for override in overrides {
            override.apply(&settings)
        }
        return settings
    }

    private mutating func set<Value: Equatable>(_ keyPath: WritableKeyPath<PlayerConfiguration, Value>, _ value: Value)
    {
        configurationOverrides.append(Override(keyPath, value))
    }

    private mutating func set<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>, _ value: Value) {
        settingsOverrides.append(Override(keyPath, value))
    }

    /// `Name: value`; a header without a name is ignored.
    private mutating func addHeader(_ header: String) {
        guard let colonIdx = header.firstIndex(of: ":") else { return }
        let key = header[..<colonIdx].trimmingCharacters(in: .whitespaces)
        let val = header[header.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            headers[key] = val
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
