import AppKit
import NitsCore
import NitsUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WelcomeWindowController: NSWindowController {
    private let onOpenURLs: ([URL]) -> Void
    private let onPromptOpenURL: (() -> Void)?
    private let onOpenRecentItem: ((RecentMediaItem) -> Void)?
    private let isRecentMediaEnabled: () -> Bool

    init(
        onOpenURLs: @escaping ([URL]) -> Void,
        onPromptOpenURL: (() -> Void)? = nil,
        onOpenRecentItem: ((RecentMediaItem) -> Void)? = nil,
        isRecentMediaEnabled: @escaping () -> Bool = { true }
    ) {
        self.onOpenURLs = onOpenURLs
        self.onPromptOpenURL = onPromptOpenURL
        self.onOpenRecentItem = onOpenRecentItem
        self.isRecentMediaEnabled = isRecentMediaEnabled

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        setupWindow(window)
    }

    convenience init(
        onOpenURL: @escaping (URL) -> Void,
        onPromptOpenURL: (() -> Void)? = nil,
        onOpenRecentItem: ((RecentMediaItem) -> Void)? = nil,
        isRecentMediaEnabled: @escaping () -> Bool = { true }
    ) {
        self.init(
            onOpenURLs: { urls in
                if let first = urls.first {
                    onOpenURL(first)
                }
            },
            onPromptOpenURL: onPromptOpenURL,
            onOpenRecentItem: onOpenRecentItem,
            isRecentMediaEnabled: isRecentMediaEnabled
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        // Background frosted glass visual effect view
        let visualEffectView = NSVisualEffectView()
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .underWindowBackground
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]

        let welcomeView = WelcomeView(
            onOpenFile: { [weak self] in
                self?.promptOpenFile()
            },
            onOpenURL: { [weak self] in
                self?.onPromptOpenURL?()
            },
            onFilesDropped: { [weak self] urls in
                self?.onOpenURLs(urls)
            },
            onOpenRecentItem: { [weak self] item in
                self?.onOpenRecentItem?(item)
            },
            onClearRecent: {
                RecentMediaActions.clearAll()
            },
            isRecentMediaEnabled: isRecentMediaEnabled
        )

        let hostingView = NSHostingView(rootView: welcomeView)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = visualEffectView.bounds

        visualEffectView.addSubview(hostingView)
        window.contentView = visualEffectView
        window.initialFirstResponder = hostingView
    }

    func promptOpenFile() {
        let urls = MediaOpenPanel.promptForMediaFiles()
        guard !urls.isEmpty else { return }
        onOpenURLs(urls)
    }
}
