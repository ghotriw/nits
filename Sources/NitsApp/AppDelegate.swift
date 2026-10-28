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
    private var initialMediaPath: String?
    private var hasOpenedInitialMedia: Bool = false

    override init() {
        let baseConfig = PlayerConfiguration.loadFromUserDefaults()
        let parsed = PlayerConfiguration.parse(base: baseConfig)
        self.configuration = parsed.configuration
        self.initialMediaPath = parsed.mediaPath
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        setupAppIcon()

        if let mediaPath = initialMediaPath {
            hasOpenedInitialMedia = true
            if MediaURL.isNetworkURL(mediaPath), let url = URL(string: mediaPath) {
                openStream(
                    url: url, headers: configuration.httpHeaders, startTime: configuration.startTime,
                    audioTrack: configuration.audioTrack, subtitleTrack: configuration.subtitleTrack)
            } else if FileManager.default.fileExists(atPath: mediaPath) {
                openMediaFile(
                    at: URL(fileURLWithPath: mediaPath), startTime: configuration.startTime,
                    audioTrack: configuration.audioTrack, subtitleTrack: configuration.subtitleTrack)
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
            let resolution = await MediaURLResolver.resolveAsync(urls, source: "Open")
            guard !resolution.urls.isEmpty else {
                if let player = playerWindowController, player.window?.isVisible == true {
                    player.uiState.osd.show(.custom(symbol: "exclamationmark.triangle", text: "No playable media"))
                } else {
                    NSSound.beep()
                }
                return
            }
            openResolvedMediaFiles(
                at: resolution.urls, startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack)
        }
    }

    private func openResolvedMediaFiles(
        at urls: [URL], startTime: Double?, audioTrack: String?, subtitleTrack: String?
    ) {
        guard let firstURL = urls.first else { return }
        if urls.count > 1 {
            AppLog.info(
                .playlist,
                "Opening \(urls.count) media files. Populating playlist and starting '\(firstURL.lastPathComponent)'")
            ensurePlayerWindowController()
            if let playlist = playerWindowController?.engine.playlist {
                playlist.clear()
                playlist.append(urls: urls)
            }
        }
        openStream(
            url: firstURL, headers: [:], startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack)
    }

    @discardableResult
    private func ensurePlayerWindowController() -> PlayerWindowController {
        if let controller = playerWindowController {
            return controller
        }
        let controller = PlayerWindowController(configuration: configuration)
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
        ensurePlayerWindowController()

        // Close/hide welcome window
        welcomeWindowController?.window?.orderOut(nil)
        welcomeWindowController?.close()
        welcomeWindowController = nil

        // Open stream or file in main player window
        playerWindowController?.openStream(
            url: url, headers: headers, startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack)
        isPlayerActive = true
        activePlayer = playerWindowController
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

    func updateConfiguration(_ newConfig: PlayerConfiguration) {
        self.configuration = newConfig
        self.playerWindowController?.applyConfiguration(self.configuration)
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
