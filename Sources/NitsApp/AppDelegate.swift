import AppKit
import NitsCore
import NitsKit
import NitsUI
import Observation
import SwiftUI

@Observable
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var isPlayerActive: Bool = false
    var activePlayer: (any PlayerActions)?
    private var welcomeWindowController: WelcomeWindowController?
    private(set) var playerWindowController: PlayerWindowController?
    private var configuration: PlayerConfiguration
    private var settings: AppSettings
    private var launchArguments: LaunchArguments
    /// The saved settings `configuration` and `settings` were made from, to tell which ones Settings changes.
    private var savedConfiguration: PlayerConfiguration
    private var savedSettings: AppSettings
    var rememberRecentMedia: Bool {
        settings.rememberRecentMedia
    }
    private var hasOpenedInitialMedia: Bool = false

    override init() {
        let launchArguments = LaunchArguments()
        let savedConfiguration = PlayerConfiguration.loadFromUserDefaults()
        let savedSettings = AppSettings.loadFromUserDefaults()
        self.launchArguments = launchArguments
        self.savedConfiguration = savedConfiguration
        self.savedSettings = savedSettings
        self.configuration = launchArguments.applied(to: savedConfiguration)
        self.settings = launchArguments.applied(to: savedSettings)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        setupAppIcon()

        if let mediaPath = launchArguments.mediaPath {
            hasOpenedInitialMedia = true
            if MediaURL.isNetworkURL(mediaPath), let url = URL(string: mediaPath) {
                openStream(
                    url: url, headers: launchArguments.headers, startTime: launchArguments.startTime,
                    audioTrack: launchArguments.audioTrack, subtitleTrack: launchArguments.subtitleTrack)
            } else if FileManager.default.fileExists(atPath: mediaPath) {
                openMediaFile(
                    at: URL(fileURLWithPath: mediaPath), startTime: launchArguments.startTime,
                    audioTrack: launchArguments.audioTrack, subtitleTrack: launchArguments.subtitleTrack)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if hasOpenedInitialMedia || isPlayerActive || playerWindowController != nil {
            NSApp.activate()
            return
        }

        showWelcomeWindow()
        NSApp.activate()
    }

    func showWelcomeWindow() {
        guard !isPlayerActive && playerWindowController == nil else { return }
        isPlayerActive = false
        activePlayer = nil
        if welcomeWindowController == nil {
            welcomeWindowController = WelcomeWindowController(
                onOpenURLs: { [weak self] urls in
                    self?.openMediaFiles(at: urls)
                },
                onPromptOpenURL: { [weak self] in
                    self?.promptOpenURL()
                },
                onOpenRecentItem: { [weak self] item in
                    self?.openRecentItem(item)
                },
                isRecentMediaEnabled: { [weak self] in
                    self?.rememberRecentMedia ?? true
                }
            )
        }
        welcomeWindowController?.showWindow(nil)
        welcomeWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openMediaFile(at url: URL, startTime: Double? = nil, audioTrack: String? = nil, subtitleTrack: String? = nil) {
        openMediaFiles(at: [url], startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack)
    }

    func openMediaFiles(
        at urls: [URL], startTime: Double? = nil, audioTrack: String? = nil, subtitleTrack: String? = nil
    ) {
        guard !urls.isEmpty else { return }
        Task {
            let request = await MediaOpenRequest.resolving(urls, source: "Open")
            // With no player on screen, nothing opens and subtitle files have nothing to attach to.
            guard !request.media.isEmpty || playerWindowController?.window?.isVisible == true else {
                NSSound.beep()
                return
            }
            await showPlayer().open(
                request, startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack)
        }
    }

    @discardableResult
    private func ensurePlayerWindowController() -> PlayerWindowController {
        if let controller = playerWindowController {
            return controller
        }
        let controller = PlayerWindowController(
            configuration: configuration, settings: settings, recentMediaStore: .shared)
        controller.onClose = { [weak self] _, _ in
            guard let self else { return }
            self.isPlayerActive = false
            self.activePlayer = nil
            self.playerWindowController = nil
            // Closing the video goes back to the Welcome window, with its recent media.
            self.showWelcomeWindow()
        }
        controller.onKeyStatusChanged = { [weak self] isKey in
            if isKey {
                self?.activePlayer = self?.playerWindowController
            }
        }
        playerWindowController = controller
        return controller
    }

    func openStream(
        url: URL, headers: [String: String], startTime: Double? = nil, audioTrack: String? = nil,
        subtitleTrack: String? = nil
    ) {
        showPlayer().openStream(
            url: url, headers: headers, startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack)
    }

    /// The player window, created if there is none, in place of the Welcome window.
    private func showPlayer() -> PlayerWindowController {
        let controller = ensurePlayerWindowController()
        welcomeWindowController?.window?.orderOut(nil)
        welcomeWindowController?.close()
        welcomeWindowController = nil
        isPlayerActive = true
        activePlayer = controller
        return controller
    }

    func openRecentItem(_ item: RecentMediaItem) {
        if item.isNetwork {
            if let url = URL(string: item.urlString) {
                openStream(url: url, headers: item.headers ?? [:])
            }
        } else {
            openMediaFile(at: URL(fileURLWithPath: item.urlString))
        }
    }

    func clearRecentMedia() {
        RecentMediaActions.clearAll()
    }

    func promptOpenFile() {
        if let playerWC = playerWindowController, playerWC.window?.isVisible == true {
            let urls = MediaOpenPanel.promptForMediaFiles()
            if !urls.isEmpty {
                openMediaFiles(at: urls)
            }
        } else {
            welcomeWindowController?.promptOpenFile()
        }
    }

    func promptOpenURL() {
        let parentWindow: NSWindow? =
            (playerWindowController?.window?.isVisible == true)
            ? playerWindowController?.window
            : welcomeWindowController?.window

        guard let parent = parentWindow else { return }

        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let sheetView = OpenURLSheetView(
            onOpen: { [weak self, weak sheetWindow, weak parent] url, headers in
                if let sheetWindow, let parent {
                    parent.endSheet(sheetWindow)
                }
                self?.openStream(url: url, headers: headers)
            },
            onCancel: { [weak sheetWindow, weak parent] in
                if let sheetWindow, let parent {
                    parent.endSheet(sheetWindow)
                }
            }
        )

        sheetWindow.contentView = NSHostingView(rootView: sheetView)
        parent.beginSheet(sheetWindow)
    }

    /// Settings are saved, so they come back from `UserDefaults`, with the command line's flags on top, except those
    /// whose setting was just changed.
    func settingsDidChange() {
        let newConfiguration = PlayerConfiguration.loadFromUserDefaults()
        launchArguments.dropOverrides(changedFrom: savedConfiguration, to: newConfiguration)
        savedConfiguration = newConfiguration
        configuration = launchArguments.applied(to: newConfiguration)
        let newSettings = AppSettings.loadFromUserDefaults()
        launchArguments.dropOverrides(changedFrom: savedSettings, to: newSettings)
        savedSettings = newSettings
        settings = launchArguments.applied(to: newSettings)
        PlaybackHistoryStore.shared.exclusionPolicy = configuration.historyExclusionPolicy
        playerWindowController?.applyConfiguration(configuration)
        playerWindowController?.applySettings(settings)
    }

    private func setupAppIcon() {
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        playerWindowController?.engine.saveCurrentPlaybackProgress()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWelcomeWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        hasOpenedInitialMedia = true
        guard let firstURL = urls.first else { return }
        if urls.count > 1 {
            AppLog.info(
                .engine, "Received \(urls.count) media URLs to open. Opening first: \(firstURL.lastPathComponent)")
        }

        if firstURL.isFileURL {
            openMediaFiles(at: urls)
        } else {
            openStream(url: firstURL, headers: [:])
        }
    }
}
