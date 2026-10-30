import NitsCore
import SwiftUI

public struct SettingsView: View {
    @AppStorage(PlayerConfiguration.keyEnableToneMapping)
    private var enableToneMapping: Bool = true

    @AppStorage(PlayerConfiguration.keySharpness)
    private var sharpness: Double = 0.5

    @AppStorage(PlayerConfiguration.keyTargetNitsScale)
    private var targetNitsScale: Double = 1.0

    @AppStorage(PlayerConfiguration.keyApplyDolbyVisionTrims)
    private var applyDolbyVisionTrims: Bool = false

    @AppStorage(PlayerConfiguration.keyLocalContrast)
    private var localContrast: Double = Double(ToneMapController.defaultLocalContrast)

    @AppStorage(PlayerConfiguration.keyResumePlayback)
    private var resumePlayback: Bool = true

    @AppStorage(AppSettings.keyRememberRecentMedia)
    private var rememberRecentMedia: Bool = true

    @AppStorage(PlayerConfiguration.keyHistoryExcludedFolders)
    private var rawHistoryExcludedFolders: String = "[]"

    @AppStorage(PlayerConfiguration.keyHistoryExcludedDomains)
    private var rawHistoryExcludedDomains: String = "[]"

    @AppStorage(PlayerConfiguration.keyResumeStartThreshold)
    private var resumeStartThreshold: Double = 15.0

    @AppStorage(PlayerConfiguration.keyResumeEndThresholdRatio)
    private var resumeEndThresholdRatio: Double = 0.95

    @AppStorage(AppSettings.keyEnableOSD)
    private var enableOSD: Bool = true

    @AppStorage(AppSettings.keyOSDDuration)
    private var osdDuration: Double = 1.3

    @AppStorage(AppSettings.keyEnableDebugOSD)
    private var enableDebugOSD: Bool = false

    @AppStorage(AppSettings.keyDebugOSDMinimumLevel)
    private var debugOSDMinimumLevel: LogLevel = .warning

    @AppStorage(AppSettings.keyDebugOSDDuration)
    private var debugOSDDuration: Double = 4.0

    @AppStorage(PlayerConfiguration.keyAutoLoadFolderMedia)
    private var autoLoadFolderMedia: Bool = true

    @AppStorage(PlayerConfiguration.keySeekStepSeconds)
    private var seekStepSeconds: Double = 5.0

    @AppStorage(PlayerConfiguration.keyExactSeekOnSinglePress)
    private var exactSeekOnSinglePress: Bool = true

    @AppStorage(PlayerConfiguration.keyVideoScaling)
    private var videoScaling: VideoScaling = .fit

    @AppStorage(PlayerConfiguration.keyNetworkThumbnailPolicy)
    private var networkThumbnailPolicy: NetworkThumbnailPolicy = .localNetworkOnly

    @AppStorage(AppSettings.keyPictureInPictureWindowBehavior)
    private var pictureInPictureWindowBehavior: PictureInPictureWindowBehavior = .hide

    @AppStorage(AppSettings.keyPausesOnPictureInPicture)
    private var pausesOnPictureInPicture: Bool = false

    @AppStorage(AppSettings.keyEntersPictureInPictureOnMinimize)
    private var entersPictureInPictureOnMinimize: Bool = false

    @AppStorage(AppSettings.keyActionButtonDisplayDuration)
    private var actionButtonDisplayDuration: Double = 8.0

    @AppStorage(AppSettings.keyActionButtonAutoPress)
    private var actionButtonAutoPress: Bool = false

    private static let actionButtonDurations: [Double] = [5.0, 8.0, 10.0, 15.0]
    private static let standardSeekSteps: [Double] = [1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0]
    private static let osdDurations: [Double] = [0.8, 1.3, 2.0, 3.0, 5.0]
    private static let debugOSDDurations: [Double] = [2.0, 4.0, 6.0, 10.0, 15.0, 30.0]

    @State private var showClearPositionsConfirmation: Bool = false
    @State private var showClearRecentConfirmation: Bool = false
    @State private var selectedTab: SettingsTab = .general
    @State private var hasSavedPositions: Bool = PlaybackHistoryStore.shared.hasSavedPositions

    private var currentExcludedFolders: [ExcludedFolder] {
        HistoryExclusionPolicy.decodeFolders(from: rawHistoryExcludedFolders)
    }

    private var currentExcludedDomains: [String] {
        HistoryExclusionPolicy.decodeList(from: rawHistoryExcludedDomains)
    }

    private func handleAddFolder(_ folder: ExcludedFolder) {
        var folders = currentExcludedFolders
        guard !folders.contains(where: { $0.overlaps(folder) }) else { return }
        folders.append(folder)
        rawHistoryExcludedFolders = HistoryExclusionPolicy.encodeFolders(folders)
        RecentMediaStore.shared.purge(matching: HistoryExclusionPolicy(excludedFolders: [folder]))
        notifyChange()
    }

    private func handleRemoveFolder(_ folder: ExcludedFolder) {
        var folders = currentExcludedFolders
        folders.removeAll { $0.path.caseInsensitiveCompare(folder.path) == .orderedSame }
        rawHistoryExcludedFolders = HistoryExclusionPolicy.encodeFolders(folders)
        notifyChange()
    }

    private func handleAddDomain(_ domain: String) {
        var domains = currentExcludedDomains
        guard !domains.contains(domain) else { return }
        domains.append(domain)
        rawHistoryExcludedDomains = HistoryExclusionPolicy.encodeList(domains)
        RecentMediaStore.shared.purge(matching: HistoryExclusionPolicy(excludedDomains: [domain]))
        notifyChange()
    }

    private func handleRemoveDomain(_ domain: String) {
        var domains = currentExcludedDomains
        domains.removeAll { $0 == domain }
        rawHistoryExcludedDomains = HistoryExclusionPolicy.encodeList(domains)
        notifyChange()
    }

    var onSettingsChanged: (() -> Void)?

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case video = "Video & HDR"
        case languages = "Languages"
        case controls = "Controls"

        public var id: String { rawValue }

        public var iconName: String {
            switch self {
            case .general:
                return "gearshape"
            case .languages:
                return "globe"
            case .video:
                return "tv"
            case .controls:
                return "slider.horizontal.below.rectangle"
            }
        }
    }

    public init(onSettingsChanged: (() -> Void)? = nil) {
        self.onSettingsChanged = onSettingsChanged
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.iconName)
                }
                .tag(SettingsTab.general)

            videoTab
                .tabItem {
                    Label(SettingsTab.video.rawValue, systemImage: SettingsTab.video.iconName)
                }
                .tag(SettingsTab.video)

            LanguagesSettingsPane(onChange: notifyChange)
                .tabItem {
                    Label(SettingsTab.languages.rawValue, systemImage: SettingsTab.languages.iconName)
                }
                .tag(SettingsTab.languages)

            controlsTab
                .tabItem {
                    Label(SettingsTab.controls.rawValue, systemImage: SettingsTab.controls.iconName)
                }
                .tag(SettingsTab.controls)
        }
        .frame(width: 580, height: 460)
        .onAppear {
            hasSavedPositions = PlaybackHistoryStore.shared.hasSavedPositions
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackHistoryStore.didChangeNotification)) { _ in
            hasSavedPositions = PlaybackHistoryStore.shared.hasSavedPositions
        }
    }

    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Remember playback position", isOn: $resumePlayback)
                        .onChange(of: resumePlayback) { _, _ in
                            notifyChange()
                        }

                    HStack(alignment: .center, spacing: 12) {
                        Text(
                            "Resumes videos from where you left off."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Button("Clear Saved Positions…") {
                            showClearPositionsConfirmation = true
                        }
                        .disabled(!hasSavedPositions)
                        .confirmationDialog(
                            "Clear Saved Playback Positions?",
                            isPresented: $showClearPositionsConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Clear Saved Positions", role: .destructive) {
                                PlaybackHistoryStore.shared.clearAll()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(
                                "Saved resume positions for all videos will be reset."
                            )
                        }
                    }
                }

                if resumePlayback {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Minimum watch time before saving:")
                            Spacer()
                            Text("\(Int(resumeStartThreshold))s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $resumeStartThreshold, in: 5...60, step: 5)
                            .onChange(of: resumeStartThreshold) { _, _ in
                                notifyChange()
                            }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Completion threshold:")
                            Spacer()
                            Text("\(Int(resumeEndThresholdRatio * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $resumeEndThresholdRatio, in: 0.8...0.99, step: 0.01)
                            .onChange(of: resumeEndThresholdRatio) { _, _ in
                                notifyChange()
                            }
                        Text("Playback past this point is considered finished and will not be resumed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Keep recent media list", isOn: $rememberRecentMedia)
                        .onChange(of: rememberRecentMedia) { _, isEnabled in
                            if !isEnabled {
                                RecentMediaActions.clearAll()
                            }
                            notifyChange()
                        }

                    HStack(alignment: .center, spacing: 12) {
                        Text(
                            "Shows recently opened videos in the Welcome window, the File → Open Recent menu, and the Dock. Turning this off clears the recent media list."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Button("Clear Recent Media…") {
                            showClearRecentConfirmation = true
                        }
                        .disabled(RecentMediaStore.shared.items.isEmpty)
                        .confirmationDialog(
                            "Clear Recent Media List?",
                            isPresented: $showClearRecentConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Clear Recent Media", role: .destructive) {
                                RecentMediaActions.clearAll()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(
                                "Removes all recently opened videos from the Welcome window, the File → Open Recent menu, and the Dock. Saved playback positions will not be affected."
                            )
                        }
                    }
                }
            } header: {
                Text("Playback Resume & History")
            }

            Section {
                HistoryExclusionsView(
                    excludedFolders: currentExcludedFolders,
                    excludedDomains: currentExcludedDomains,
                    onAddFolder: handleAddFolder,
                    onRemoveFolder: handleRemoveFolder,
                    onAddDomain: handleAddDomain,
                    onRemoveDomain: handleRemoveDomain
                )
            } header: {
                Text("History Exclusions")
            } footer: {
                Text(
                    "Media inside untracked folders and streams from untracked domains will not appear in recent media and will not save playback positions."
                )
            }

            Section {
                Toggle("Show On-Screen Display (OSD)", isOn: $enableOSD)
                    .onChange(of: enableOSD) { _, _ in
                        notifyChange()
                    }

                if enableOSD {
                    Picker("Display duration", selection: $osdDuration) {
                        ForEach(Self.osdDurations, id: \.self) { seconds in
                            Text(Self.formatSeconds(seconds)).tag(seconds)
                        }
                        if !Self.osdDurations.contains(osdDuration) {
                            Text("Custom (\(Self.formatSeconds(osdDuration)))").tag(osdDuration)
                        }
                    }
                    .onChange(of: osdDuration) { _, _ in
                        notifyChange()
                    }
                }

                Text(
                    "Displays visual feedback badges in the top-left corner for actions like seeking, volume changes, pause/play, and track selection."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Toggle("Show debug messages on screen", isOn: $enableDebugOSD)
                    .onChange(of: enableDebugOSD) { _, _ in
                        notifyChange()
                    }

                if enableDebugOSD {
                    Picker("Minimum level", selection: $debugOSDMinimumLevel) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text(level.rawValue.capitalized).tag(level)
                        }
                    }
                    .onChange(of: debugOSDMinimumLevel) { _, _ in
                        notifyChange()
                    }

                    Picker("Message duration", selection: $debugOSDDuration) {
                        ForEach(Self.debugOSDDurations, id: \.self) { seconds in
                            Text(Self.formatSeconds(seconds)).tag(seconds)
                        }
                        if !Self.debugOSDDurations.contains(debugOSDDuration) {
                            Text("Custom (\(Self.formatSeconds(debugOSDDuration)))").tag(debugOSDDuration)
                        }
                    }
                    .onChange(of: debugOSDDuration) { _, _ in
                        notifyChange()
                    }
                }

                Text(
                    "Mirrors application log messages at or above the selected level below the OSD. Intended for diagnostics; identical consecutive messages are collapsed."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } header: {
                Text("On-Screen Display (OSD)")
            }

            Section {
                Toggle("Automatically add folder media to playlist", isOn: $autoLoadFolderMedia)
                    .onChange(of: autoLoadFolderMedia) { _, _ in
                        notifyChange()
                    }

                Text(
                    "When opening a media file, automatically scan the parent directory and populate the playlist with sibling files in natural alphanumeric order."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } header: {
                Text("Playlist & Folders")
            }

            Section {
                Picker("Show button for", selection: $actionButtonDisplayDuration) {
                    ForEach(Self.actionButtonDurations, id: \.self) { seconds in
                        Text(Self.formatSeconds(seconds)).tag(seconds)
                    }
                    if !Self.actionButtonDurations.contains(actionButtonDisplayDuration) {
                        Text("Custom (\(Self.formatSeconds(actionButtonDisplayDuration)))")
                            .tag(actionButtonDisplayDuration)
                    }
                }
                .onChange(of: actionButtonDisplayDuration) { _, _ in
                    notifyChange()
                }

                Toggle("Press automatically when the time runs out", isOn: $actionButtonAutoPress)
                    .onChange(of: actionButtonAutoPress) { _, _ in
                        notifyChange()
                    }
            } header: {
                Text("Action Buttons")
            } footer: {
                Text(
                    "Buttons such as Skip Intro or Next Episode, offered by the app that opened the video. After this time they show only with the controls. Return presses the button, Esc dismisses it."
                )
            }

            Section {
                Picker("Player window during PiP", selection: $pictureInPictureWindowBehavior) {
                    ForEach(PictureInPictureWindowBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .onChange(of: pictureInPictureWindowBehavior) { _, _ in
                    notifyChange()
                }

                Toggle("Pause when entering Picture in Picture", isOn: $pausesOnPictureInPicture)
                    .onChange(of: pausesOnPictureInPicture) { _, _ in
                        notifyChange()
                    }

                Toggle("Enter Picture in Picture when minimizing the window", isOn: $entersPictureInPictureOnMinimize)
                    .onChange(of: entersPictureInPictureOnMinimize) { _, _ in
                        notifyChange()
                    }
            } header: {
                Text("Picture in Picture")
            } footer: {
                Text(
                    "Hide puts the player window away until Picture in Picture ends; fullscreen and minimized windows always stay as they are. When PiP starts from minimizing, restoring the window from the Dock ends it."
                )
            }

            Section {
                Picker("Arrow seek step", selection: $seekStepSeconds) {
                    ForEach(Self.standardSeekSteps, id: \.self) { step in
                        Text("\(Int(step)) \(step == 1.0 ? "second" : "seconds")").tag(step)
                    }
                    if !Self.standardSeekSteps.contains(seekStepSeconds) {
                        Text("Custom (\(Int(round(seekStepSeconds)))s)").tag(seekStepSeconds)
                    }
                }
                .onChange(of: seekStepSeconds) { _, _ in
                    notifyChange()
                }

                Toggle("Exact video seek on single press", isOn: $exactSeekOnSinglePress)
                    .onChange(of: exactSeekOnSinglePress) { _, _ in
                        notifyChange()
                    }
            } header: {
                Text("Seeking & Navigation")
            } footer: {
                Text(
                    exactSeekOnSinglePress
                        ? "Arrow keys step by the selected interval. For video, a single press seeks to the exact frame; rapid bursts navigate quickly by keyframes. Audio always seeks accurately."
                        : "For video, seeking always jumps to keyframes (fastest, recommended for software decoders like AV1). For audio, seeking uses the selected step interval."
                )
            }
            Section {
                Picker("Network stream thumbnails", selection: $networkThumbnailPolicy) {
                    ForEach(NetworkThumbnailPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .onChange(of: networkThumbnailPolicy) { _, _ in
                    notifyChange()
                }
            } header: {
                Text("Timeline Preview Thumbnails")
            } footer: {
                Text(
                    networkThumbnailPolicy == .localNetworkOnly
                        ? "Thumbnails are generated on local network streams (Emby, Plex, NAS) and skipped for external internet streams to conserve bandwidth."
                        : (networkThumbnailPolicy == .always
                            ? "Thumbnails are generated for all network streams (may consume additional bandwidth on metered connections)."
                            : "Thumbnails are only generated for local files on disk. Network streams will show time badges only.")
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Video Tab
    private var videoTab: some View {
        Form {
            Section {
                Toggle("Enable HDR Tone Mapping on SDR displays", isOn: $enableToneMapping)
                    .onChange(of: enableToneMapping) { _, _ in
                        notifyChange()
                    }

                Text(
                    enableToneMapping
                        ? "When connected to an SDR or external monitor, Metal compute shaders automatically apply ITU-R BT.2390 EETF tone mapping."
                        : "Tone mapping is globally disabled. The player strictly outputs video via Apple's native AVSampleBufferDisplayLayer."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } header: {
                Text("HDR Pipeline")
            }

            Section {
                Picker("Default Scaling", selection: $videoScaling) {
                    ForEach(VideoScaling.allCases) { scaling in
                        Text(scaling.title).tag(scaling)
                    }
                }
                .onChange(of: videoScaling) { _, _ in
                    notifyChange()
                }

                Text(
                    "How the picture fills the window. Change it for the session from the Video menu or with W; aspect ratio and crop are remembered per file."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } header: {
                Text("Picture")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default Sharpness (CAS):")
                        Spacer()
                        Text(String(format: "%.1f", sharpness))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $sharpness, in: 0.0...1.0, step: 0.1)
                        .disabled(!enableToneMapping)
                        .onChange(of: sharpness) { _, _ in
                            notifyChange()
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Target White Scale:")
                        Spacer()
                        Text(String(format: "%.2fx (%.0f%%)", targetNitsScale, targetNitsScale * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $targetNitsScale, in: 0.5...2.0, step: 0.05)
                        .disabled(!enableToneMapping)
                        .onChange(of: targetNitsScale) { _, _ in
                            notifyChange()
                        }
                    Text(
                        "Multiplies the dynamic content-adaptive white level (1.00x = optimal auto). Lower values make dark scenes brighter; higher values increase contrast."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Apply Dolby Vision trims (L2)", isOn: $applyDolbyVisionTrims)
                        .disabled(!enableToneMapping)
                        .onChange(of: applyDolbyVisionTrims) { _, _ in
                            notifyChange()
                        }
                    Text(
                        "Applies the colorist's SDR corrections from Dolby Vision metadata on top of the tone mapping. An approximation of Dolby's own processing: compare on your titles. Off uses the scene brightness metadata (L1) only."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Local Contrast:")
                        Spacer()
                        Text(localContrast > 0 ? String(format: "%.2f", localContrast) : "Off")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $localContrast, in: 0.0...1.0, step: 0.05)
                        .disabled(!enableToneMapping)
                        .onChange(of: localContrast) { _, _ in
                            notifyChange()
                        }
                    Text(
                        "Brings back the texture of bright areas (skies, haze, lit faces) that the tone curve flattens near white. 0.50 matches the HDR picture best; higher values add more detail and may show halos around bright edges. 0 turns it off."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tone Mapping Tuning")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Controls Tab
    private var controlsTab: some View {
        ControlsSettingsPane(controlsConfig: ControlsConfiguration.shared)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        let value = seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return "\(value) \(seconds == 1.0 ? "second" : "seconds")"
    }

    /// Every setting is in `UserDefaults` (`@AppStorage`) by the time this runs, so the host reloads them from there.
    private func notifyChange() {
        onSettingsChanged?()
    }
}
