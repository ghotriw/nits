import Foundation

/// Policy for timeline hover thumbnail generation on network streams.
public enum NetworkThumbnailPolicy: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Generate thumbnails automatically on local network streams (LAN / private IP / Bonjour), skip for WAN streams.
    case localNetworkOnly
    /// Generate thumbnails on all network streams (LAN and WAN).
    case always
    /// Disable thumbnail generation on all network streams (only local disk files).
    case never

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localNetworkOnly:
            return "Local Network Only (LAN)"
        case .always:
            return "Always (All Network Streams)"
        case .never:
            return "Never (Local Files Only)"
        }
    }
}

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

    /// Target reference white level in nits for BT.2390 tone mapping (default `ToneMapController.referenceWhiteNits`).
    /// For backward compatibility, setting `targetNits` adjusts `targetNitsScale` relative to that.
    public var targetNits: Float {
        get { ToneMapController.referenceWhiteNits * targetNitsScale }
        set { targetNitsScale = max(newValue / ToneMapController.referenceWhiteNits, 0.1) }
    }

    /// Default sharpness factor for FidelityFX CAS (0.0 ... 1.0).
    public var sharpness: Float

    /// Whether Dolby Vision L2 trims (the colorist's 100-nit SDR corrections) are applied on top of the BT.2390
    /// curve (default false). Off, Metal tone mapping uses L1 only, as mpv does: the trims correct Dolby's own base
    /// curve, which is not public, so on BT.2390 they are an approximation.
    public var applyDolbyVisionTrims: Bool

    /// Strength of the local contrast in Metal tone mapping, 0 ... 1, 0: off (default
    /// `ToneMapController.defaultLocalContrast`; see `ToneMapController.localContrast`).
    public var localContrast: Float

    /// Default volume level (0.0 ... 1.0).
    public var initialVolume: Float

    /// Custom HTTP headers to pass when streaming over HTTP/HTTPS (e.g. for custom authentication tokens).
    public var httpHeaders: [String: String]

    /// Whether to automatically resume playback from previously saved position (default true).
    public var resumePlayback: Bool

    /// Whether to record and display recently opened media in the Welcome window and Open Recent menu (default true).
    public var rememberRecentMedia: Bool

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

    /// Draw ASS / SSA subtitles with libass as their authors styled and positioned them (default), rather than as
    /// plain text in the subtitle style above.
    public var usesAuthoredSubtitleStyles: Bool

    /// Show only the forced sets of bitmap tracks (PGS, VobSub): the signs and foreign-language lines a Blu-ray keeps
    /// inside its full track. Text tracks don't mark them and show as usual; so does a track flagged forced as a whole.
    public var showsOnlyForcedSubtitles: Bool
    /// How much of the subtitle style above replaces an ASS script's own on its dialogue, when it is drawn as authored.
    public var assStyleOverride: AssStyleOverride
    /// Size of ASS dialogue and picture subtitles (PGS, VobSub, DVB) against the script's or the disc's, 0.5-2;
    /// plain text has its own font size.
    public var subtitleScale: Double
    /// Height of bottom subtitles in percent of the picture from its top: 100 keeps them where they are, lower raises
    /// them (mpv's `sub-pos`). Applies to every kind of subtitle.
    public var subtitlePosition: Double

    /// Subtitle font family / design (default "System Rounded").
    public var subtitleFontName: String

    /// Subtitle font weight (e.g. "Regular", "Medium", "Semibold", "Bold", "Heavy", default "Semibold").
    public var subtitleFontWeight: String

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

    /// Whether to automatically discover and add sibling media files in the folder to the playlist (default true).
    public var autoLoadFolderMedia: Bool

    /// Seek step in seconds for arrow key navigation (default 5.0).
    public var seekStepSeconds: Double

    /// Whether a single arrow key press seeks to the exact target time (default true).
    /// When disabled, all seeks navigate strictly by keyframes.
    public var exactSeekOnSinglePress: Bool

    /// How the picture is sized to the window (default `.fit`); a change from the Video menu lasts the session.
    public var videoScaling: VideoScaling

    /// Explicit start time in seconds requested on launch (if provided, including `0`, overrides resume history).
    public var startTime: Double?

    /// Explicit audio track requested on launch: internal track id (`0, 1...`), explicit stream index
    /// via `stream:N` / `s:N` (container stream index), or language code / title fragment
    /// (if provided, overrides the track saved in resume history).
    public var audioTrack: String?

    /// Explicit subtitle track requested on launch: internal track id (`0, 1...`), explicit stream index
    /// via `stream:N` / `s:N`, language code / title fragment, or `off` to disable subtitles
    /// (if provided, overrides the track saved in resume history).
    public var subtitleTrack: String?

    /// Policy for timeline hover thumbnail generation on network streams (default .localNetworkOnly).
    public var networkThumbnailPolicy: NetworkThumbnailPolicy
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
    /// Seconds of playback an action button ("Skip Intro") stays up on its own before it hides with the controls
    /// (default 8).
    public var actionButtonDisplayDuration: Double
    /// Press an action button by itself once `actionButtonDisplayDuration` runs out, unless the button opts out
    /// (default false).
    public var actionButtonAutoPress: Bool
    /// Languages that choose the audio and subtitle tracks a media starts with, when neither a request nor its saved
    /// history names them.
    public var trackLanguages: TrackLanguagePreferences
    /// Encoding of subtitle files that have no byte order mark and aren't UTF-8; `nil` lets `TextFileEncoding` detect
    /// it (default).
    public var subtitleEncoding: String.Encoding?

    /// Folders whose media files should never be saved to recent media or playback history.
    public var historyExcludedFolders: [ExcludedFolder] {
        didSet {
            historyExclusionPolicy = HistoryExclusionPolicy(
                excludedFolders: historyExcludedFolders, excludedDomains: historyExcludedDomains)
        }
    }

    /// Network domains whose streams should never be saved to recent media or playback history.
    public var historyExcludedDomains: [String] {
        didSet {
            historyExclusionPolicy = HistoryExclusionPolicy(
                excludedFolders: historyExcludedFolders, excludedDomains: historyExcludedDomains)
        }
    }

    /// Cached exclusion policy derived from `historyExcludedFolders` and `historyExcludedDomains`.
    public private(set) var historyExclusionPolicy: HistoryExclusionPolicy

    public init(
        enableToneMapping: Bool = true,
        defaultRenderMode: RenderMode = .auto,
        targetNits: Float = ToneMapController.referenceWhiteNits,
        targetNitsScale: Float? = nil,
        sharpness: Float = 0.5,
        applyDolbyVisionTrims: Bool = false,
        localContrast: Float = ToneMapController.defaultLocalContrast,
        initialVolume: Float = 1.0,
        httpHeaders: [String: String] = [:],
        resumePlayback: Bool = true,
        rememberRecentMedia: Bool = true,
        resumeStartThreshold: Double = 15.0,
        resumeEndThresholdRatio: Double = 0.95,
        subtitleFontSize: Double = 24.0,
        subtitleFontName: String = SubtitleSystemFont.rounded.rawValue,
        subtitleFontWeight: String = "Semibold",
        subtitleTextColorHex: String = "#FFFFFF",
        subtitleBgColorHex: String = "#000000",
        subtitleBgOpacity: Double = 0.65,
        usesAuthoredSubtitleStyles: Bool = true,
        showsOnlyForcedSubtitles: Bool = false,
        assStyleOverride: AssStyleOverride = .none,
        subtitleScale: Double = 1.0,
        subtitlePosition: Double = 100,
        enableOSD: Bool = true,
        osdDuration: Double = 1.3,
        enableDebugOSD: Bool = false,
        debugOSDMinimumLevel: LogLevel = .warning,
        debugOSDDuration: Double = 4.0,
        autoLoadFolderMedia: Bool = true,
        seekStepSeconds: Double = 5.0,
        exactSeekOnSinglePress: Bool = true,
        videoScaling: VideoScaling = .fit,
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil,
        networkThumbnailPolicy: NetworkThumbnailPolicy = .localNetworkOnly,
        resolvesWithYTDLP: Bool = true,
        ytdlpPath: String = "",
        sponsorBlock: Bool = true,
        pictureInPictureWindowBehavior: PictureInPictureWindowBehavior = .hide,
        pausesOnPictureInPicture: Bool = false,
        entersPictureInPictureOnMinimize: Bool = false,
        actionButtonDisplayDuration: Double = 8.0,
        actionButtonAutoPress: Bool = false,
        trackLanguages: TrackLanguagePreferences = TrackLanguagePreferences(),
        subtitleEncoding: String.Encoding? = nil,
        historyExcludedFolders: [ExcludedFolder] = [],
        historyExcludedDomains: [String] = []
    ) {
        self.enableToneMapping = enableToneMapping
        self.defaultRenderMode = defaultRenderMode
        if let scale = targetNitsScale {
            self.targetNitsScale = scale
        } else {
            self.targetNitsScale = max(targetNits / ToneMapController.referenceWhiteNits, 0.1)
        }
        self.sharpness = sharpness
        self.applyDolbyVisionTrims = applyDolbyVisionTrims
        self.localContrast = max(0, min(1, localContrast))
        self.initialVolume = initialVolume
        self.httpHeaders = httpHeaders
        self.resumePlayback = resumePlayback
        self.rememberRecentMedia = rememberRecentMedia
        self.resumeStartThreshold = resumeStartThreshold
        self.resumeEndThresholdRatio = resumeEndThresholdRatio
        self.subtitleFontSize = subtitleFontSize
        self.subtitleFontName = subtitleFontName
        self.subtitleFontWeight = subtitleFontWeight
        self.subtitleTextColorHex = subtitleTextColorHex
        self.subtitleBgColorHex = subtitleBgColorHex
        self.subtitleBgOpacity = subtitleBgOpacity
        self.usesAuthoredSubtitleStyles = usesAuthoredSubtitleStyles
        self.showsOnlyForcedSubtitles = showsOnlyForcedSubtitles
        self.assStyleOverride = assStyleOverride
        self.subtitleScale = subtitleScale
        self.subtitlePosition = subtitlePosition
        self.enableOSD = enableOSD
        self.osdDuration = osdDuration
        self.enableDebugOSD = enableDebugOSD
        self.debugOSDMinimumLevel = debugOSDMinimumLevel
        self.debugOSDDuration = debugOSDDuration
        self.autoLoadFolderMedia = autoLoadFolderMedia
        self.seekStepSeconds = seekStepSeconds
        self.exactSeekOnSinglePress = exactSeekOnSinglePress
        self.videoScaling = videoScaling
        self.startTime = startTime
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
        self.networkThumbnailPolicy = networkThumbnailPolicy
        self.resolvesWithYTDLP = resolvesWithYTDLP
        self.ytdlpPath = ytdlpPath
        self.sponsorBlock = sponsorBlock
        self.pictureInPictureWindowBehavior = pictureInPictureWindowBehavior
        self.pausesOnPictureInPicture = pausesOnPictureInPicture
        self.entersPictureInPictureOnMinimize = entersPictureInPictureOnMinimize
        self.actionButtonDisplayDuration = Self.clampActionButtonDisplayDuration(actionButtonDisplayDuration)
        self.actionButtonAutoPress = actionButtonAutoPress
        self.trackLanguages = trackLanguages
        self.subtitleEncoding = subtitleEncoding
        self.historyExcludedFolders = historyExcludedFolders
        self.historyExcludedDomains = historyExcludedDomains
        self.historyExclusionPolicy = HistoryExclusionPolicy(
            excludedFolders: historyExcludedFolders, excludedDomains: historyExcludedDomains)
    }

    public static let keyEnableToneMapping = "Nits.enableToneMapping"
    public static let keyTargetNits = "Nits.targetNits"
    public static let keyTargetNitsScale = "Nits.targetNitsScale"
    public static let keySharpness = "Nits.sharpness"
    public static let keyApplyDolbyVisionTrims = "Nits.applyDolbyVisionTrims"
    public static let keyLocalContrast = "Nits.localContrast"
    public static let keyResumePlayback = "Nits.resumePlayback"
    public static let keyRememberRecentMedia = "Nits.rememberRecentMedia"
    public static let keyHistoryExcludedFolders = "Nits.historyExcludedFolders"
    public static let keyHistoryExcludedDomains = "Nits.historyExcludedDomains"
    public static let keyResumeStartThreshold = "Nits.resumeStartThreshold"
    public static let keyResumeEndThresholdRatio = "Nits.resumeEndThresholdRatio"
    public static let keySubtitleFontSize = "Nits.subtitleFontSize"
    public static let keySubtitleFontName = "Nits.subtitleFontName"
    public static let keySubtitleFontWeight = "Nits.subtitleFontWeight"
    public static let keySubtitleTextColorHex = "Nits.subtitleTextColorHex"
    public static let keySubtitleBgColorHex = "Nits.subtitleBgColorHex"
    public static let keySubtitleBgOpacity = "Nits.subtitleBgOpacity"
    public static let keyAuthoredSubtitleStyles = "Nits.subtitleAuthoredStyles"
    public static let keyForcedSubtitlesOnly = "Nits.subtitleForcedOnly"
    public static let keyAssStyleOverride = "Nits.subtitleAssStyleOverride"
    public static let keySubtitleScale = "Nits.subtitleScale"
    public static let keySubtitlePosition = "Nits.subtitlePosition"
    public static let keyEnableOSD = "Nits.enableOSD"
    public static let keyOSDDuration = "Nits.osdDuration"
    public static let keyEnableDebugOSD = "Nits.enableDebugOSD"
    public static let keyDebugOSDMinimumLevel = "Nits.debugOSDMinimumLevel"
    public static let keyDebugOSDDuration = "Nits.debugOSDDuration"
    public static let keyAutoLoadFolderMedia = "Nits.autoLoadFolderMedia"
    public static let keySeekStepSeconds = "Nits.seekStepSeconds"
    public static let keyExactSeekOnSinglePress = "Nits.exactSeekOnSinglePress"
    public static let keyVideoScaling = "Nits.videoScaling"
    public static let keyNetworkThumbnailPolicy = "Nits.networkThumbnailPolicy"
    public static let keyResolvesWithYTDLP = "Nits.resolvesWithYTDLP"
    public static let keyYTDLPPath = "Nits.ytdlpPath"
    public static let keySponsorBlock = "Nits.sponsorBlock"
    public static let keyPictureInPictureWindowBehavior = "Nits.pictureInPictureWindowBehavior"
    public static let keyPausesOnPictureInPicture = "Nits.pausesOnPictureInPicture"
    public static let keyEntersPictureInPictureOnMinimize = "Nits.entersPictureInPictureOnMinimize"
    public static let keyActionButtonDisplayDuration = "Nits.actionButtonDisplayDuration"
    public static let keyActionButtonAutoPress = "Nits.actionButtonAutoPress"
    public static let keyAudioLanguages = "Nits.audioLanguages"
    public static let keySubtitleLanguages = "Nits.subtitleLanguages"
    public static let keyForcedSubtitleSelection = "Nits.forcedSubtitleSelection"
    public static let keySubtitlesWithKnownAudio = "Nits.subtitlesWithKnownAudio"
    /// The IANA name of `subtitleEncoding`; empty for detection.
    public static let keySubtitleEncoding = "Nits.subtitleEncoding"

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
        if userDefaults.object(forKey: keyApplyDolbyVisionTrims) != nil {
            config.applyDolbyVisionTrims = userDefaults.bool(forKey: keyApplyDolbyVisionTrims)
        }
        if let localContrast = userDefaults.object(forKey: keyLocalContrast) as? NSNumber {
            config.localContrast = max(0, min(1, localContrast.floatValue))
        }
        if userDefaults.object(forKey: keyResumePlayback) != nil {
            config.resumePlayback = userDefaults.bool(forKey: keyResumePlayback)
        }
        if userDefaults.object(forKey: keyRememberRecentMedia) != nil {
            config.rememberRecentMedia = userDefaults.bool(forKey: keyRememberRecentMedia)
        }
        let exclusionPolicy = loadHistoryExclusionPolicy(from: userDefaults)
        config.historyExcludedFolders = exclusionPolicy.excludedFolders
        config.historyExcludedDomains = exclusionPolicy.excludedDomains
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
        if userDefaults.object(forKey: keyAuthoredSubtitleStyles) != nil {
            config.usesAuthoredSubtitleStyles = userDefaults.bool(forKey: keyAuthoredSubtitleStyles)
        }
        if userDefaults.object(forKey: keyForcedSubtitlesOnly) != nil {
            config.showsOnlyForcedSubtitles = userDefaults.bool(forKey: keyForcedSubtitlesOnly)
        }
        if let override = userDefaults.string(forKey: keyAssStyleOverride).flatMap(AssStyleOverride.init(rawValue:)) {
            config.assStyleOverride = override
        }
        if let scale = userDefaults.object(forKey: keySubtitleScale) as? NSNumber {
            config.subtitleScale = scale.doubleValue
        }
        if let position = userDefaults.object(forKey: keySubtitlePosition) as? NSNumber {
            config.subtitlePosition = position.doubleValue
        }
        if let bgOpacity = userDefaults.object(forKey: keySubtitleBgOpacity) as? NSNumber {
            config.subtitleBgOpacity = bgOpacity.doubleValue
        }
        if userDefaults.object(forKey: keyEnableOSD) != nil {
            config.enableOSD = userDefaults.bool(forKey: keyEnableOSD)
        }
        if let duration = userDefaults.object(forKey: keyOSDDuration) as? NSNumber {
            config.osdDuration = clampOSDDuration(duration.doubleValue)
        }
        if userDefaults.object(forKey: keyEnableDebugOSD) != nil {
            config.enableDebugOSD = userDefaults.bool(forKey: keyEnableDebugOSD)
        }
        if let levelRaw = userDefaults.string(forKey: keyDebugOSDMinimumLevel),
            let level = LogLevel(rawValue: levelRaw)
        {
            config.debugOSDMinimumLevel = level
        }
        if let duration = userDefaults.object(forKey: keyDebugOSDDuration) as? NSNumber {
            config.debugOSDDuration = clampDebugOSDDuration(duration.doubleValue)
        }
        if userDefaults.object(forKey: keyAutoLoadFolderMedia) != nil {
            config.autoLoadFolderMedia = userDefaults.bool(forKey: keyAutoLoadFolderMedia)
        }
        if let seekStep = userDefaults.object(forKey: keySeekStepSeconds) as? NSNumber {
            let val = seekStep.doubleValue
            if val.isFinite && val > 0 {
                config.seekStepSeconds = max(1.0, min(300.0, val))
            }
        }
        if userDefaults.object(forKey: keyExactSeekOnSinglePress) != nil {
            config.exactSeekOnSinglePress = userDefaults.bool(forKey: keyExactSeekOnSinglePress)
        }
        if let scalingRaw = userDefaults.string(forKey: keyVideoScaling),
            let scaling = VideoScaling(rawValue: scalingRaw)
        {
            config.videoScaling = scaling
        }
        if let networkThumbnailsRaw = userDefaults.string(forKey: keyNetworkThumbnailPolicy),
            let policy = NetworkThumbnailPolicy(rawValue: networkThumbnailsRaw)
        {
            config.networkThumbnailPolicy = policy
        }
        if userDefaults.object(forKey: keyResolvesWithYTDLP) != nil {
            config.resolvesWithYTDLP = userDefaults.bool(forKey: keyResolvesWithYTDLP)
        }
        if let path = userDefaults.string(forKey: keyYTDLPPath) {
            config.ytdlpPath = path
        }
        if userDefaults.object(forKey: keySponsorBlock) != nil {
            config.sponsorBlock = userDefaults.bool(forKey: keySponsorBlock)
        }
        if let pipWindowRaw = userDefaults.string(forKey: keyPictureInPictureWindowBehavior),
            let behavior = PictureInPictureWindowBehavior(rawValue: pipWindowRaw)
        {
            config.pictureInPictureWindowBehavior = behavior
        }
        if userDefaults.object(forKey: keyPausesOnPictureInPicture) != nil {
            config.pausesOnPictureInPicture = userDefaults.bool(forKey: keyPausesOnPictureInPicture)
        }
        if userDefaults.object(forKey: keyEntersPictureInPictureOnMinimize) != nil {
            config.entersPictureInPictureOnMinimize = userDefaults.bool(forKey: keyEntersPictureInPictureOnMinimize)
        }
        if let duration = userDefaults.object(forKey: keyActionButtonDisplayDuration) as? NSNumber {
            config.actionButtonDisplayDuration = clampActionButtonDisplayDuration(duration.doubleValue)
        }
        if userDefaults.object(forKey: keyActionButtonAutoPress) != nil {
            config.actionButtonAutoPress = userDefaults.bool(forKey: keyActionButtonAutoPress)
        }
        if let languages = userDefaults.string(forKey: keyAudioLanguages) {
            config.trackLanguages.audioLanguages = TrackLanguagePreferences.languages(fromStored: languages)
        }
        if let languages = userDefaults.string(forKey: keySubtitleLanguages) {
            config.trackLanguages.subtitleLanguages = TrackLanguagePreferences.languages(fromStored: languages)
        }
        if let forced = userDefaults.string(forKey: keyForcedSubtitleSelection).flatMap(
            ForcedSubtitleSelection.init(rawValue:))
        {
            config.trackLanguages.forcedSubtitles = forced
        }
        if let known = userDefaults.string(forKey: keySubtitlesWithKnownAudio).flatMap(
            SubtitlesWithKnownAudio.init(rawValue:))
        {
            config.trackLanguages.subtitlesWithKnownAudio = known
        }
        config.subtitleEncoding = userDefaults.string(forKey: keySubtitleEncoding).flatMap(
            TextFileEncoding.encoding(named:))
        return config
    }

    /// Loads only the history exclusion policy from UserDefaults without parsing the entire configuration.
    public static func loadHistoryExclusionPolicy(from userDefaults: UserDefaults = .standard) -> HistoryExclusionPolicy
    {
        let folders =
            userDefaults.string(forKey: keyHistoryExcludedFolders).map(HistoryExclusionPolicy.decodeFolders) ?? []
        let domains =
            userDefaults.string(forKey: keyHistoryExcludedDomains).map(HistoryExclusionPolicy.decodeList) ?? []
        return HistoryExclusionPolicy(excludedFolders: folders, excludedDomains: domains)
    }

    /// Saves configuration properties to UserDefaults.
    public func saveToUserDefaults(userDefaults: UserDefaults = .standard) {
        userDefaults.set(enableToneMapping, forKey: Self.keyEnableToneMapping)
        userDefaults.set(targetNitsScale, forKey: Self.keyTargetNitsScale)
        userDefaults.set(targetNits, forKey: Self.keyTargetNits)
        userDefaults.set(sharpness, forKey: Self.keySharpness)
        userDefaults.set(applyDolbyVisionTrims, forKey: Self.keyApplyDolbyVisionTrims)
        userDefaults.set(localContrast, forKey: Self.keyLocalContrast)
        userDefaults.set(resumePlayback, forKey: Self.keyResumePlayback)
        userDefaults.set(rememberRecentMedia, forKey: Self.keyRememberRecentMedia)
        userDefaults.set(resumeStartThreshold, forKey: Self.keyResumeStartThreshold)
        userDefaults.set(resumeEndThresholdRatio, forKey: Self.keyResumeEndThresholdRatio)
        userDefaults.set(subtitleFontSize, forKey: Self.keySubtitleFontSize)
        userDefaults.set(subtitleFontName, forKey: Self.keySubtitleFontName)
        userDefaults.set(subtitleFontWeight, forKey: Self.keySubtitleFontWeight)
        userDefaults.set(subtitleTextColorHex, forKey: Self.keySubtitleTextColorHex)
        userDefaults.set(subtitleBgColorHex, forKey: Self.keySubtitleBgColorHex)
        userDefaults.set(subtitleBgOpacity, forKey: Self.keySubtitleBgOpacity)
        userDefaults.set(usesAuthoredSubtitleStyles, forKey: Self.keyAuthoredSubtitleStyles)
        userDefaults.set(showsOnlyForcedSubtitles, forKey: Self.keyForcedSubtitlesOnly)
        userDefaults.set(assStyleOverride.rawValue, forKey: Self.keyAssStyleOverride)
        userDefaults.set(subtitleScale, forKey: Self.keySubtitleScale)
        userDefaults.set(subtitlePosition, forKey: Self.keySubtitlePosition)
        userDefaults.set(enableOSD, forKey: Self.keyEnableOSD)
        userDefaults.set(osdDuration, forKey: Self.keyOSDDuration)
        userDefaults.set(enableDebugOSD, forKey: Self.keyEnableDebugOSD)
        userDefaults.set(debugOSDMinimumLevel.rawValue, forKey: Self.keyDebugOSDMinimumLevel)
        userDefaults.set(debugOSDDuration, forKey: Self.keyDebugOSDDuration)
        userDefaults.set(autoLoadFolderMedia, forKey: Self.keyAutoLoadFolderMedia)
        userDefaults.set(seekStepSeconds, forKey: Self.keySeekStepSeconds)
        userDefaults.set(exactSeekOnSinglePress, forKey: Self.keyExactSeekOnSinglePress)
        userDefaults.set(videoScaling.rawValue, forKey: Self.keyVideoScaling)
        userDefaults.set(networkThumbnailPolicy.rawValue, forKey: Self.keyNetworkThumbnailPolicy)
        userDefaults.set(resolvesWithYTDLP, forKey: Self.keyResolvesWithYTDLP)
        userDefaults.set(ytdlpPath, forKey: Self.keyYTDLPPath)
        userDefaults.set(sponsorBlock, forKey: Self.keySponsorBlock)
        userDefaults.set(pictureInPictureWindowBehavior.rawValue, forKey: Self.keyPictureInPictureWindowBehavior)
        userDefaults.set(pausesOnPictureInPicture, forKey: Self.keyPausesOnPictureInPicture)
        userDefaults.set(entersPictureInPictureOnMinimize, forKey: Self.keyEntersPictureInPictureOnMinimize)
        userDefaults.set(actionButtonDisplayDuration, forKey: Self.keyActionButtonDisplayDuration)
        userDefaults.set(actionButtonAutoPress, forKey: Self.keyActionButtonAutoPress)
        userDefaults.set(
            TrackLanguagePreferences.storedValue(of: trackLanguages.audioLanguages), forKey: Self.keyAudioLanguages)
        userDefaults.set(
            TrackLanguagePreferences.storedValue(of: trackLanguages.subtitleLanguages),
            forKey: Self.keySubtitleLanguages)
        userDefaults.set(trackLanguages.forcedSubtitles.rawValue, forKey: Self.keyForcedSubtitleSelection)
        userDefaults.set(trackLanguages.subtitlesWithKnownAudio.rawValue, forKey: Self.keySubtitlesWithKnownAudio)
        userDefaults.set(
            subtitleEncoding.flatMap(TextFileEncoding.name(of:)) ?? "", forKey: Self.keySubtitleEncoding)
        userDefaults.set(
            HistoryExclusionPolicy.encodeFolders(historyExcludedFolders), forKey: Self.keyHistoryExcludedFolders)
        userDefaults.set(
            HistoryExclusionPolicy.encodeList(historyExcludedDomains), forKey: Self.keyHistoryExcludedDomains)
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
            } else if arg == "--dovi-trims" {
                config.applyDolbyVisionTrims = true
            } else if arg == "--no-dovi-trims" {
                config.applyDolbyVisionTrims = false
            } else if arg.starts(with: "--local-contrast=") {
                if let val = Float(arg.dropFirst("--local-contrast=".count)) {
                    config.localContrast = max(0, min(1, val))
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
            } else if arg == "--no-recent-media" || arg == "--disable-recent-media" {
                config.rememberRecentMedia = false
            } else if arg == "--recent-media" || arg == "--enable-recent-media" {
                config.rememberRecentMedia = true
            } else if arg == "--no-osd" || arg == "--disable-osd" {
                config.enableOSD = false
            } else if arg == "--enable-osd" || arg == "--osd" {
                config.enableOSD = true
            } else if arg.starts(with: "--osd-duration=") {
                if let val = Double(arg.dropFirst("--osd-duration=".count)) {
                    config.osdDuration = clampOSDDuration(val)
                }
            } else if arg == "--debug-osd" {
                config.enableDebugOSD = true
            } else if arg == "--no-debug-osd" {
                config.enableDebugOSD = false
            } else if arg.starts(with: "--debug-osd-level=") {
                let val = String(arg.dropFirst("--debug-osd-level=".count)).uppercased()
                if let level = LogLevel(rawValue: val) {
                    config.debugOSDMinimumLevel = level
                }
            } else if arg.starts(with: "--debug-osd-duration=") {
                if let val = Double(arg.dropFirst("--debug-osd-duration=".count)) {
                    config.debugOSDDuration = clampDebugOSDDuration(val)
                }
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
            } else if arg.starts(with: "--network-thumbnails=") {
                let val = String(arg.dropFirst("--network-thumbnails=".count)).lowercased()
                if val == "always" || val == "all" || val == "true" {
                    config.networkThumbnailPolicy = .always
                } else if val == "never" || val == "none" || val == "false" || val == "off" {
                    config.networkThumbnailPolicy = .never
                } else if val == "lan" || val == "local" || val == "localnetwork" {
                    config.networkThumbnailPolicy = .localNetworkOnly
                }
            } else if arg == "--no-ytdl" {
                config.resolvesWithYTDLP = false
            } else if arg == "--ytdl" {
                config.resolvesWithYTDLP = true
            } else if arg.starts(with: "--ytdl-path=") {
                config.ytdlpPath = String(arg.dropFirst("--ytdl-path=".count))
            } else if arg == "--no-sponsorblock" {
                config.sponsorBlock = false
            } else if arg == "--sponsorblock" {
                config.sponsorBlock = true
            } else if arg == "--no-network-thumbnails" {
                config.networkThumbnailPolicy = .never
            } else if arg == "--always-network-thumbnails" {
                config.networkThumbnailPolicy = .always
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
