import Foundation
import NitsCore

/// What happens to the player window while its video plays in Picture in Picture. Fullscreen and minimized windows
/// are always left as they are.
public enum PictureInPictureWindowBehavior: String, Sendable, Codable, CaseIterable, Identifiable {
    case hide
    case doNothing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hide: "Hide"
        case .doNothing: "Keep Open"
        }
    }
}

/// The app's settings that the engine doesn't read: the OSD, action buttons, recent media, yt-dlp and the player
/// window in Picture in Picture. They are saved in the same `UserDefaults` as the engine's `PlayerConfiguration`.
/// In `NitsUI` rather than `NitsKit`, which owns most of them, for `SettingsView` and `OSDManager` to reach.
public struct AppSettings: Sendable, Equatable {
    /// Whether On-Screen Display (OSD) notifications are enabled (default true).
    public var enableOSD: Bool
    /// How long regular OSD notifications stay on screen, in seconds (default 1.3).
    public var osdDuration: Double
    /// Whether log messages are mirrored to the On-Screen Display as debug badges (default false).
    public var enableDebugOSD: Bool
    /// Minimum log level mirrored to the debug OSD (default .warning).
    public var debugOSDMinimumLevel: LogLevel
    /// How long each debug OSD message stays on screen, in seconds (default 4.0).
    public var debugOSDDuration: Double
    /// Seconds of playback an action button ("Skip Intro") stays up on its own before it hides with the controls
    /// (default 8).
    public var actionButtonDisplayDuration: Double
    /// Press an action button by itself once `actionButtonDisplayDuration` runs out, unless the button opts out
    /// (default false).
    public var actionButtonAutoPress: Bool
    /// Whether to record and display recently opened media in the Welcome window and Open Recent menu (default true).
    public var rememberRecentMedia: Bool
    /// How many recently opened media the list keeps (`recentMediaLimits`, default 20); lowering it drops the oldest.
    public var recentMediaLimit: Int
    /// Whether the pages of video sites play, resolved by yt-dlp found on the system (default true).
    public var resolvesWithYTDLP: Bool
    /// The yt-dlp to run in place of the one found on the system (empty: search for it).
    public var ytdlpPath: String
    /// Skip buttons for a YouTube video's SponsorBlock segments (sponsors, intros, …), and its community chapters
    /// when the author gave none (default true).
    public var sponsorBlock: Bool
    /// What happens to the player window while its video plays in Picture in Picture.
    public var pictureInPictureWindowBehavior: PictureInPictureWindowBehavior
    /// Pause playback when Picture in Picture starts.
    public var pausesOnPictureInPicture: Bool
    /// Enter Picture in Picture when the player window is minimized during playback, and leave it on restore.
    public var entersPictureInPictureOnMinimize: Bool

    public init(
        enableOSD: Bool = true,
        osdDuration: Double = 1.3,
        enableDebugOSD: Bool = false,
        debugOSDMinimumLevel: LogLevel = .warning,
        debugOSDDuration: Double = 4.0,
        actionButtonDisplayDuration: Double = 8.0,
        actionButtonAutoPress: Bool = false,
        rememberRecentMedia: Bool = true,
        recentMediaLimit: Int = 20,
        resolvesWithYTDLP: Bool = true,
        ytdlpPath: String = "",
        sponsorBlock: Bool = true,
        pictureInPictureWindowBehavior: PictureInPictureWindowBehavior = .hide,
        pausesOnPictureInPicture: Bool = false,
        entersPictureInPictureOnMinimize: Bool = false
    ) {
        self.enableOSD = enableOSD
        self.osdDuration = Self.clampOSDDuration(osdDuration)
        self.enableDebugOSD = enableDebugOSD
        self.debugOSDMinimumLevel = debugOSDMinimumLevel
        self.debugOSDDuration = Self.clampDebugOSDDuration(debugOSDDuration)
        self.actionButtonDisplayDuration = Self.clampActionButtonDisplayDuration(actionButtonDisplayDuration)
        self.actionButtonAutoPress = actionButtonAutoPress
        self.rememberRecentMedia = rememberRecentMedia
        self.recentMediaLimit = Self.clampRecentMediaLimit(recentMediaLimit)
        self.resolvesWithYTDLP = resolvesWithYTDLP
        self.ytdlpPath = ytdlpPath
        self.sponsorBlock = sponsorBlock
        self.pictureInPictureWindowBehavior = pictureInPictureWindowBehavior
        self.pausesOnPictureInPicture = pausesOnPictureInPicture
        self.entersPictureInPictureOnMinimize = entersPictureInPictureOnMinimize
    }

    public static let keyEnableOSD = "Nits.enableOSD"
    public static let keyOSDDuration = "Nits.osdDuration"
    public static let keyEnableDebugOSD = "Nits.enableDebugOSD"
    public static let keyDebugOSDMinimumLevel = "Nits.debugOSDMinimumLevel"
    public static let keyDebugOSDDuration = "Nits.debugOSDDuration"
    public static let keyActionButtonDisplayDuration = "Nits.actionButtonDisplayDuration"
    public static let keyActionButtonAutoPress = "Nits.actionButtonAutoPress"
    public static let keyRememberRecentMedia = "Nits.rememberRecentMedia"
    public static let keyRecentMediaLimit = "Nits.recentMediaLimit"
    public static let keyResolvesWithYTDLP = "Nits.resolvesWithYTDLP"
    public static let keyYTDLPPath = "Nits.ytdlpPath"
    public static let keySponsorBlock = "Nits.sponsorBlock"
    public static let keyPictureInPictureWindowBehavior = "Nits.pictureInPictureWindowBehavior"
    public static let keyPausesOnPictureInPicture = "Nits.pausesOnPictureInPicture"
    public static let keyEntersPictureInPictureOnMinimize = "Nits.entersPictureInPictureOnMinimize"

    /// Loads the settings from UserDefaults, falling back to defaults if not set.
    public static func loadFromUserDefaults(userDefaults: UserDefaults = .standard) -> AppSettings {
        var settings = AppSettings()
        if userDefaults.object(forKey: keyEnableOSD) != nil {
            settings.enableOSD = userDefaults.bool(forKey: keyEnableOSD)
        }
        if let duration = userDefaults.object(forKey: keyOSDDuration) as? NSNumber {
            settings.osdDuration = clampOSDDuration(duration.doubleValue)
        }
        if userDefaults.object(forKey: keyEnableDebugOSD) != nil {
            settings.enableDebugOSD = userDefaults.bool(forKey: keyEnableDebugOSD)
        }
        if let level = userDefaults.string(forKey: keyDebugOSDMinimumLevel).flatMap(LogLevel.init(rawValue:)) {
            settings.debugOSDMinimumLevel = level
        }
        if let duration = userDefaults.object(forKey: keyDebugOSDDuration) as? NSNumber {
            settings.debugOSDDuration = clampDebugOSDDuration(duration.doubleValue)
        }
        if let duration = userDefaults.object(forKey: keyActionButtonDisplayDuration) as? NSNumber {
            settings.actionButtonDisplayDuration = clampActionButtonDisplayDuration(duration.doubleValue)
        }
        if userDefaults.object(forKey: keyActionButtonAutoPress) != nil {
            settings.actionButtonAutoPress = userDefaults.bool(forKey: keyActionButtonAutoPress)
        }
        if userDefaults.object(forKey: keyRememberRecentMedia) != nil {
            settings.rememberRecentMedia = userDefaults.bool(forKey: keyRememberRecentMedia)
        }
        if let limit = userDefaults.object(forKey: keyRecentMediaLimit) as? NSNumber {
            settings.recentMediaLimit = clampRecentMediaLimit(limit.intValue)
        }
        if userDefaults.object(forKey: keyResolvesWithYTDLP) != nil {
            settings.resolvesWithYTDLP = userDefaults.bool(forKey: keyResolvesWithYTDLP)
        }
        if let path = userDefaults.string(forKey: keyYTDLPPath) {
            settings.ytdlpPath = path
        }
        if userDefaults.object(forKey: keySponsorBlock) != nil {
            settings.sponsorBlock = userDefaults.bool(forKey: keySponsorBlock)
        }
        if let behavior = userDefaults.string(forKey: keyPictureInPictureWindowBehavior).flatMap(
            PictureInPictureWindowBehavior.init(rawValue:))
        {
            settings.pictureInPictureWindowBehavior = behavior
        }
        if userDefaults.object(forKey: keyPausesOnPictureInPicture) != nil {
            settings.pausesOnPictureInPicture = userDefaults.bool(forKey: keyPausesOnPictureInPicture)
        }
        if userDefaults.object(forKey: keyEntersPictureInPictureOnMinimize) != nil {
            settings.entersPictureInPictureOnMinimize = userDefaults.bool(forKey: keyEntersPictureInPictureOnMinimize)
        }
        return settings
    }

    /// Saves the settings to UserDefaults.
    public func saveToUserDefaults(userDefaults: UserDefaults = .standard) {
        userDefaults.set(enableOSD, forKey: Self.keyEnableOSD)
        userDefaults.set(osdDuration, forKey: Self.keyOSDDuration)
        userDefaults.set(enableDebugOSD, forKey: Self.keyEnableDebugOSD)
        userDefaults.set(debugOSDMinimumLevel.rawValue, forKey: Self.keyDebugOSDMinimumLevel)
        userDefaults.set(debugOSDDuration, forKey: Self.keyDebugOSDDuration)
        userDefaults.set(actionButtonDisplayDuration, forKey: Self.keyActionButtonDisplayDuration)
        userDefaults.set(actionButtonAutoPress, forKey: Self.keyActionButtonAutoPress)
        userDefaults.set(rememberRecentMedia, forKey: Self.keyRememberRecentMedia)
        userDefaults.set(recentMediaLimit, forKey: Self.keyRecentMediaLimit)
        userDefaults.set(resolvesWithYTDLP, forKey: Self.keyResolvesWithYTDLP)
        userDefaults.set(ytdlpPath, forKey: Self.keyYTDLPPath)
        userDefaults.set(sponsorBlock, forKey: Self.keySponsorBlock)
        userDefaults.set(pictureInPictureWindowBehavior.rawValue, forKey: Self.keyPictureInPictureWindowBehavior)
        userDefaults.set(pausesOnPictureInPicture, forKey: Self.keyPausesOnPictureInPicture)
        userDefaults.set(entersPictureInPictureOnMinimize, forKey: Self.keyEntersPictureInPictureOnMinimize)
    }

    /// Clamps a regular OSD notification duration to a sane on-screen range (0.5...10 s).
    public static func clampOSDDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 1.3 }
        return max(0.5, min(10.0, value))
    }

    /// Clamps a debug OSD message duration to a sane on-screen range (1...60 s).
    public static func clampDebugOSDDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 4.0 }
        return max(1.0, min(60.0, value))
    }

    /// Clamps how long an action button stays up on its own to a usable range (3...60 s).
    public static func clampActionButtonDisplayDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 8.0 }
        return max(3.0, min(60.0, value))
    }

    /// The lengths of the recent media list Settings offers.
    public static let recentMediaLimits = [10, 20, 50, 100]

    /// Clamps the length of the recent media list to the range Settings offers (10...100).
    public static func clampRecentMediaLimit(_ value: Int) -> Int {
        max(recentMediaLimits[0], min(recentMediaLimits[recentMediaLimits.count - 1], value))
    }
}
