import Foundation

/// Global configuration for playback behavior, rendering engines, and hardware options.
public struct PlayerConfiguration: Sendable, Equatable {
    /// Whether automatic tone mapping and custom Metal SDR rendering are permitted.
    /// When `false`, the player strictly utilizes Apple's native `AVSampleBufferDisplayLayer` pipeline
    /// and never engages custom Metal compute tone mapping.
    public var enableToneMapping: Bool

    /// Default render mode requested on startup.
    public var defaultRenderMode: RenderMode

    /// User multiplier coefficient scaling the content-adaptive target white level (default 1.0, range 0.5 ... 2.0).
    public var targetNitsScale: Float

    /// Target reference white level in nits for BT.2390 tone mapping (default 203.0).
    /// For backward compatibility, setting `targetNits` adjusts `targetNitsScale` relative to 203.0.
    public var targetNits: Float {
        get { 203.0 * targetNitsScale }
        set { targetNitsScale = max(newValue / 203.0, 0.1) }
    }

    /// Default sharpness factor for FidelityFX CAS (0.0 ... 1.0).
    public var sharpness: Float

    /// Default volume level (0.0 ... 1.0).
    public var initialVolume: Float

    /// Custom HTTP headers to pass when streaming over HTTP/HTTPS (e.g. for custom authentication tokens).
    public var httpHeaders: [String: String]

    /// Whether to automatically resume playback from previously saved position (default true).
    public var resumePlayback: Bool

    /// Minimum seconds played before a position is saved / resumed (default 15.0).
    public var resumeStartThreshold: Double

    /// Fraction of video duration after which it is considered completed (default 0.95).
    public var resumeEndThresholdRatio: Double

    /// Font size for text subtitles (default 24.0).
    public var subtitleFontSize: Double

    /// Subtitle text color as hex string (default "#FFFFFF").
    public var subtitleTextColorHex: String

    /// Subtitle background box color as hex string (default "#000000").
    public var subtitleBgColorHex: String

    /// Subtitle background opacity (0.0 ... 1.0, default 0.65).
    public var subtitleBgOpacity: Double

    /// Subtitle font family / design (default "System Rounded").
    public var subtitleFontName: String

    /// Subtitle font weight (e.g. "Regular", "Medium", "Semibold", "Bold", "Heavy", default "Semibold").
    public var subtitleFontWeight: String

    /// Whether On-Screen Display (OSD) notifications are enabled (default true).
    public var enableOSD: Bool

    /// Whether to automatically discover and add sibling media files in the folder to the playlist (default true).
    public var autoLoadFolderMedia: Bool

    /// Explicit start time in seconds requested on launch (if provided, overrides resume history).
    public var startTime: Double?

    /// Explicit audio track requested on launch: internal track id (`0, 1...`), explicit stream index
    /// via `stream:N` / `s:N` (container stream index), or language code / title fragment
    /// (if provided, overrides the track saved in resume history).
    public var audioTrack: String?

    /// Explicit subtitle track requested on launch: internal track id (`0, 1...`), explicit stream index
    /// via `stream:N` / `s:N`, language code / title fragment, or `off` to disable subtitles
    /// (if provided, overrides the track saved in resume history).
    public var subtitleTrack: String?

    public init(
        enableToneMapping: Bool = true,
        defaultRenderMode: RenderMode = .auto,
        targetNits: Float = 203.0,
        targetNitsScale: Float? = nil,
        sharpness: Float = 0.5,
        initialVolume: Float = 1.0,
        httpHeaders: [String: String] = [:],
        resumePlayback: Bool = true,
        resumeStartThreshold: Double = 15.0,
        resumeEndThresholdRatio: Double = 0.95,
        subtitleFontSize: Double = 24.0,
        subtitleFontName: String = "System Rounded",
        subtitleFontWeight: String = "Semibold",
        subtitleTextColorHex: String = "#FFFFFF",
        subtitleBgColorHex: String = "#000000",
        subtitleBgOpacity: Double = 0.65,
        enableOSD: Bool = true,
        autoLoadFolderMedia: Bool = true,
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil
    ) {
        self.enableToneMapping = enableToneMapping
        self.defaultRenderMode = defaultRenderMode
        if let scale = targetNitsScale {
            self.targetNitsScale = scale
        } else {
            self.targetNitsScale = max(targetNits / 203.0, 0.1)
        }
        self.sharpness = sharpness
        self.initialVolume = initialVolume
        self.httpHeaders = httpHeaders
        self.resumePlayback = resumePlayback
        self.resumeStartThreshold = resumeStartThreshold
        self.resumeEndThresholdRatio = resumeEndThresholdRatio
        self.subtitleFontSize = subtitleFontSize
        self.subtitleFontName = subtitleFontName
        self.subtitleFontWeight = subtitleFontWeight
        self.subtitleTextColorHex = subtitleTextColorHex
        self.subtitleBgColorHex = subtitleBgColorHex
        self.subtitleBgOpacity = subtitleBgOpacity
        self.enableOSD = enableOSD
        self.autoLoadFolderMedia = autoLoadFolderMedia
        self.startTime = startTime
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
    }

    public static let keyEnableToneMapping = "Nits.enableToneMapping"
    public static let keyTargetNits = "Nits.targetNits"
    public static let keyTargetNitsScale = "Nits.targetNitsScale"
    public static let keySharpness = "Nits.sharpness"
    public static let keyResumePlayback = "Nits.resumePlayback"
    public static let keyResumeStartThreshold = "Nits.resumeStartThreshold"
    public static let keyResumeEndThresholdRatio = "Nits.resumeEndThresholdRatio"
    public static let keySubtitleFontSize = "Nits.subtitleFontSize"
    public static let keySubtitleFontName = "Nits.subtitleFontName"
    public static let keySubtitleFontWeight = "Nits.subtitleFontWeight"
    public static let keySubtitleTextColorHex = "Nits.subtitleTextColorHex"
    public static let keySubtitleBgColorHex = "Nits.subtitleBgColorHex"
    public static let keySubtitleBgOpacity = "Nits.subtitleBgOpacity"
    public static let keyEnableOSD = "Nits.enableOSD"
    public static let keyAutoLoadFolderMedia = "Nits.autoLoadFolderMedia"

    /// Loads configuration from UserDefaults, falling back to defaults if not set.
    public static func loadFromUserDefaults(userDefaults: UserDefaults = .standard) -> PlayerConfiguration {
        var config = PlayerConfiguration()
        if userDefaults.object(forKey: keyEnableToneMapping) != nil {
            config.enableToneMapping = userDefaults.bool(forKey: keyEnableToneMapping)
        }
        if let targetNitsScale = userDefaults.object(forKey: keyTargetNitsScale) as? NSNumber {
            config.targetNitsScale = targetNitsScale.floatValue
        } else if let targetNits = userDefaults.object(forKey: keyTargetNits) as? NSNumber {
            config.targetNits = targetNits.floatValue
        }
        if let sharpness = userDefaults.object(forKey: keySharpness) as? NSNumber {
            config.sharpness = sharpness.floatValue
        }
        if userDefaults.object(forKey: keyResumePlayback) != nil {
            config.resumePlayback = userDefaults.bool(forKey: keyResumePlayback)
        }
        if let startThreshold = userDefaults.object(forKey: keyResumeStartThreshold) as? NSNumber {
            config.resumeStartThreshold = startThreshold.doubleValue
        }
        if let endThreshold = userDefaults.object(forKey: keyResumeEndThresholdRatio) as? NSNumber {
            config.resumeEndThresholdRatio = endThreshold.doubleValue
        }
        if let fontSize = userDefaults.object(forKey: keySubtitleFontSize) as? NSNumber {
            config.subtitleFontSize = fontSize.doubleValue
        }
        if let fontName = userDefaults.string(forKey: keySubtitleFontName) {
            config.subtitleFontName = fontName
        }
        if let fontWeight = userDefaults.string(forKey: keySubtitleFontWeight) {
            config.subtitleFontWeight = fontWeight
        }
        if let textColor = userDefaults.string(forKey: keySubtitleTextColorHex) {
            config.subtitleTextColorHex = textColor
        }
        if let bgColor = userDefaults.string(forKey: keySubtitleBgColorHex) {
            config.subtitleBgColorHex = bgColor
        }
        if let bgOpacity = userDefaults.object(forKey: keySubtitleBgOpacity) as? NSNumber {
            config.subtitleBgOpacity = bgOpacity.doubleValue
        }
        if userDefaults.object(forKey: keyEnableOSD) != nil {
            config.enableOSD = userDefaults.bool(forKey: keyEnableOSD)
        }
        if userDefaults.object(forKey: keyAutoLoadFolderMedia) != nil {
            config.autoLoadFolderMedia = userDefaults.bool(forKey: keyAutoLoadFolderMedia)
        }
        return config
    }

    /// Saves configuration properties to UserDefaults.
    public func saveToUserDefaults(userDefaults: UserDefaults = .standard) {
        userDefaults.set(enableToneMapping, forKey: Self.keyEnableToneMapping)
        userDefaults.set(targetNitsScale, forKey: Self.keyTargetNitsScale)
        userDefaults.set(targetNits, forKey: Self.keyTargetNits)
        userDefaults.set(sharpness, forKey: Self.keySharpness)
        userDefaults.set(resumePlayback, forKey: Self.keyResumePlayback)
        userDefaults.set(resumeStartThreshold, forKey: Self.keyResumeStartThreshold)
        userDefaults.set(resumeEndThresholdRatio, forKey: Self.keyResumeEndThresholdRatio)
        userDefaults.set(subtitleFontSize, forKey: Self.keySubtitleFontSize)
        userDefaults.set(subtitleFontName, forKey: Self.keySubtitleFontName)
        userDefaults.set(subtitleFontWeight, forKey: Self.keySubtitleFontWeight)
        userDefaults.set(subtitleTextColorHex, forKey: Self.keySubtitleTextColorHex)
        userDefaults.set(subtitleBgColorHex, forKey: Self.keySubtitleBgColorHex)
        userDefaults.set(subtitleBgOpacity, forKey: Self.keySubtitleBgOpacity)
        userDefaults.set(enableOSD, forKey: Self.keyEnableOSD)
        userDefaults.set(autoLoadFolderMedia, forKey: Self.keyAutoLoadFolderMedia)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses command-line arguments into a configuration structure and returns
    /// the configuration along with any remaining non-flag arguments (such as media paths).
    /// If `base` is supplied, command line flags will override values from `base`.
    public static func parse(
        arguments: [String] = CommandLine.arguments,
        base: PlayerConfiguration = PlayerConfiguration()
    ) -> (configuration: PlayerConfiguration, mediaPath: String?) {
        var config = base
        var mediaPath: String?

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]

            if arg == "--disable-tone-mapping" || arg == "--no-tone-mapping" {
                config.enableToneMapping = false
            } else if arg == "--enable-tone-mapping" {
                config.enableToneMapping = true
            } else if arg.starts(with: "--render-mode=") {
                let val = String(arg.dropFirst("--render-mode=".count)).lowercased()
                if val == "system" || val == "hdr" {
                    config.defaultRenderMode = .system
                } else if val == "metal" || val == "sdr" || val == "tonemap" {
                    config.defaultRenderMode = .metalToneMap
                } else {
                    config.defaultRenderMode = .auto
                }
            } else if arg.starts(with: "--target-nits-scale=") {
                if let val = Float(arg.dropFirst("--target-nits-scale=".count)) {
                    config.targetNitsScale = max(0.1, min(4.0, val))
                }
            } else if arg.starts(with: "--target-nits=") {
                if let val = Float(arg.dropFirst("--target-nits=".count)) {
                    config.targetNits = val
                }
            } else if arg.starts(with: "--sharpness=") {
                if let val = Float(arg.dropFirst("--sharpness=".count)) {
                    config.sharpness = max(0.0, min(1.0, val))
                }
            } else if arg.starts(with: "--volume=") {
                if let val = Float(arg.dropFirst("--volume=".count)) {
                    config.initialVolume = max(0.0, min(1.0, val))
                }
            } else if arg.starts(with: "--start-time=") {
                if let val = Double(arg.dropFirst("--start-time=".count)) {
                    config.startTime = max(0.0, val)
                }
            } else if arg == "--start-time" && i + 1 < arguments.count {
                i += 1
                if let val = Double(arguments[i]) {
                    config.startTime = max(0.0, val)
                }
            } else if arg.starts(with: "--audio-track=") {
                config.audioTrack = nonEmpty(String(arg.dropFirst("--audio-track=".count)))
            } else if arg == "--audio-track" && i + 1 < arguments.count {
                i += 1
                config.audioTrack = nonEmpty(arguments[i])
            } else if arg.starts(with: "--subtitle-track=") {
                config.subtitleTrack = nonEmpty(String(arg.dropFirst("--subtitle-track=".count)))
            } else if arg == "--subtitle-track" && i + 1 < arguments.count {
                i += 1
                config.subtitleTrack = nonEmpty(arguments[i])
            } else if arg == "--no-resume" || arg == "--disable-resume" {
                config.resumePlayback = false
            } else if arg == "--resume" || arg == "--enable-resume" {
                config.resumePlayback = true
            } else if arg == "--no-osd" || arg == "--disable-osd" {
                config.enableOSD = false
            } else if arg == "--enable-osd" || arg == "--osd" {
                config.enableOSD = true
            } else if arg == "--auto-load-folder" {
                config.autoLoadFolderMedia = true
            } else if arg == "--no-auto-load-folder" || arg == "--disable-auto-load-folder" {
                config.autoLoadFolderMedia = false
            } else if arg.starts(with: "--auto-load-folder=") {
                let val = String(arg.dropFirst("--auto-load-folder=".count)).lowercased()
                config.autoLoadFolderMedia = (val == "true" || val == "1" || val == "yes")
            } else if arg.starts(with: "--subtitle-font=") {
                config.subtitleFontName = String(arg.dropFirst("--subtitle-font=".count))
            } else if arg.starts(with: "--subtitle-weight=") {
                config.subtitleFontWeight = String(arg.dropFirst("--subtitle-weight=".count))
            } else if arg.starts(with: "--header=") {
                let headerStr = String(arg.dropFirst("--header=".count))
                if let colonIdx = headerStr.firstIndex(of: ":") {
                    let key = headerStr[..<colonIdx].trimmingCharacters(in: .whitespaces)
                    let val = headerStr[headerStr.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        config.httpHeaders[key] = val
                    }
                }
            } else if arg == "--header" && i + 1 < arguments.count {
                i += 1
                let headerStr = arguments[i]
                if let colonIdx = headerStr.firstIndex(of: ":") {
                    let key = headerStr[..<colonIdx].trimmingCharacters(in: .whitespaces)
                    let val = headerStr[headerStr.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        config.httpHeaders[key] = val
                    }
                }
            } else if !arg.starts(with: "-") && mediaPath == nil {
                mediaPath = arg
            }

            i += 1
        }

        return (config, mediaPath)
    }
}
