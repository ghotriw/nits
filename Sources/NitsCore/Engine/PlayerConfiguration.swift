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

    /// Whether to automatically resume playback from previously saved position (default true).
    public var resumePlayback: Bool

    /// Minimum seconds played before a position is saved / resumed (default 15.0).
    public var resumeStartThreshold: Double

    /// Whether a media without a speed of its own saved starts at the speed of the one before it, rather than at 1×
    /// (default false). The speed chosen for a media is saved with it either way; one only kept isn't.
    public var carriesPlaybackRate: Bool

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

    /// Whether to automatically discover and add sibling media files in the folder to the playlist (default true).
    public var autoLoadFolderMedia: Bool

    /// Seek step in seconds for arrow key navigation (default 5.0).
    public var seekStepSeconds: Double

    /// Whether a single arrow key press seeks to the exact target time (default true).
    /// When disabled, all seeks navigate strictly by keyframes.
    public var exactSeekOnSinglePress: Bool

    /// How the picture is sized to the window (default `.fit`); a change from the Video menu lasts the session.
    public var videoScaling: VideoScaling

    /// Policy for timeline hover thumbnail generation on network streams (default .localNetworkOnly).
    public var networkThumbnailPolicy: NetworkThumbnailPolicy
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
        resumePlayback: Bool = true,
        resumeStartThreshold: Double = 15.0,
        resumeEndThresholdRatio: Double = 0.95,
        carriesPlaybackRate: Bool = false,
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
        autoLoadFolderMedia: Bool = true,
        seekStepSeconds: Double = 5.0,
        exactSeekOnSinglePress: Bool = true,
        videoScaling: VideoScaling = .fit,
        networkThumbnailPolicy: NetworkThumbnailPolicy = .localNetworkOnly,
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
        self.resumePlayback = resumePlayback
        self.resumeStartThreshold = resumeStartThreshold
        self.resumeEndThresholdRatio = resumeEndThresholdRatio
        self.carriesPlaybackRate = carriesPlaybackRate
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
        self.autoLoadFolderMedia = autoLoadFolderMedia
        self.seekStepSeconds = seekStepSeconds
        self.exactSeekOnSinglePress = exactSeekOnSinglePress
        self.videoScaling = videoScaling
        self.networkThumbnailPolicy = networkThumbnailPolicy
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
    public static let keyHistoryExcludedFolders = "Nits.historyExcludedFolders"
    public static let keyHistoryExcludedDomains = "Nits.historyExcludedDomains"
    public static let keyResumeStartThreshold = "Nits.resumeStartThreshold"
    public static let keyResumeEndThresholdRatio = "Nits.resumeEndThresholdRatio"
    public static let keyCarriesPlaybackRate = "Nits.carriesPlaybackRate"
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
    public static let keyAutoLoadFolderMedia = "Nits.autoLoadFolderMedia"
    public static let keySeekStepSeconds = "Nits.seekStepSeconds"
    public static let keyExactSeekOnSinglePress = "Nits.exactSeekOnSinglePress"
    public static let keyVideoScaling = "Nits.videoScaling"
    public static let keyNetworkThumbnailPolicy = "Nits.networkThumbnailPolicy"
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
        let exclusionPolicy = loadHistoryExclusionPolicy(from: userDefaults)
        config.historyExcludedFolders = exclusionPolicy.excludedFolders
        config.historyExcludedDomains = exclusionPolicy.excludedDomains
        if let startThreshold = userDefaults.object(forKey: keyResumeStartThreshold) as? NSNumber {
            config.resumeStartThreshold = startThreshold.doubleValue
        }
        if let endThreshold = userDefaults.object(forKey: keyResumeEndThresholdRatio) as? NSNumber {
            config.resumeEndThresholdRatio = endThreshold.doubleValue
        }
        if userDefaults.object(forKey: keyCarriesPlaybackRate) != nil {
            config.carriesPlaybackRate = userDefaults.bool(forKey: keyCarriesPlaybackRate)
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
        userDefaults.set(resumeStartThreshold, forKey: Self.keyResumeStartThreshold)
        userDefaults.set(resumeEndThresholdRatio, forKey: Self.keyResumeEndThresholdRatio)
        userDefaults.set(carriesPlaybackRate, forKey: Self.keyCarriesPlaybackRate)
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
        userDefaults.set(autoLoadFolderMedia, forKey: Self.keyAutoLoadFolderMedia)
        userDefaults.set(seekStepSeconds, forKey: Self.keySeekStepSeconds)
        userDefaults.set(exactSeekOnSinglePress, forKey: Self.keyExactSeekOnSinglePress)
        userDefaults.set(videoScaling.rawValue, forKey: Self.keyVideoScaling)
        userDefaults.set(networkThumbnailPolicy.rawValue, forKey: Self.keyNetworkThumbnailPolicy)
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
}
