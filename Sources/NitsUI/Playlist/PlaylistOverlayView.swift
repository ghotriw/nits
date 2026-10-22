import AppKit
import NitsCore
import SwiftUI
import UniformTypeIdentifiers
import os

/// Side panel presenting the current playlist, navigation controls,
/// search filter, repeat/shuffle options, and drag-and-drop management.
public struct PlaylistOverlayView: View {
    public let engine: PlayerEngine
    @Bindable public var uiState: PlayerUIState
    /// The tab to show, `.playlist` or `.chapters`. Passed in rather than read from `uiState.sidePanel`: a closing
    /// panel slides out while still observing `uiState`, and with `sidePanel` already `nil` it switched itself to
    /// the playlist tab. The playing row's repeating symbol effect then started inside the removal, which never
    /// finished, so the panel stayed rendered just past the trailing edge (visible once the window grew).
    public let tab: PlayerSidePanel
    public var onClose: () -> Void

    @State private var isShowingAddURLAlert: Bool = false
    @State private var isShowingClearConfirmation: Bool = false
    @State private var inputURLString: String = ""
    @State private var isTargetedForDrop: Bool = false

    public init(
        engine: PlayerEngine, uiState: PlayerUIState, tab: PlayerSidePanel = .playlist,
        onClose: @escaping () -> Void
    ) {
        self.engine = engine
        self.uiState = uiState
        self.tab = tab
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerView

            Divider()
                .overlay(Color.white.opacity(0.1))

            if isShowingChapters {
                ChapterListView(engine: engine)
            } else {
                // MARK: - Filter Bar
                filterBarView

                Divider()
                    .overlay(Color.white.opacity(0.08))

                // MARK: - Body / List
                if engine.playlist.isLoading && engine.playlist.items.isEmpty {
                    loadingStateView
                } else if engine.playlist.items.isEmpty {
                    emptyStateView
                } else if engine.playlist.filteredItems.isEmpty {
                    noMatchStateView
                } else {
                    playlistListView
                }

                Divider()
                    .overlay(Color.white.opacity(0.1))

                // MARK: - Footer Summary
                footerSummaryView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Media without chapters (once loaded) falls back to the playlist tab, or closes the panel without one.
        .onChange(of: !engine.isLoading && engine.media.chapters.isEmpty, initial: true) { _, noChapters in
            if noChapters && uiState.sidePanel == .chapters {
                uiState.sidePanel = uiState.isPlaylistAvailable ? .playlist : nil
            }
        }
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.1))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
        } isTargeted: { targeted in
            isTargetedForDrop = targeted
        }
        .alert("Add Media URL", isPresented: $isShowingAddURLAlert) {
            TextField("https://...", text: $inputURLString)
            Button("Add") {
                let trimmed = inputURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), !trimmed.isEmpty {
                    Task { @MainActor in
                        await engine.playlist.appendAsync(urls: [url])
                    }
                }
                inputURLString = ""
            }
            Button("Cancel", role: .cancel) {
                inputURLString = ""
            }
        } message: {
            Text("Enter a direct streaming URL (HTTP/HTTPS, HLS, or MKV stream) to add to the playlist.")
        }
        .confirmationDialog(
            "Clear Playlist",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Playlist", role: .destructive) {
                engine.playlist.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to remove all items from the playlist?")
        }
    }

    // MARK: - Header View

    /// Chapters tab is open and the media has chapters (or there's no playlist tab to show instead); otherwise the
    /// panel shows the playlist.
    private var isShowingChapters: Bool {
        tab == .chapters && (!engine.media.chapters.isEmpty || !uiState.isPlaylistAvailable)
    }

    private var headerTabs: [SidePanelTab<PlayerSidePanel>] {
        let playlist = engine.playlist
        var tabs: [SidePanelTab<PlayerSidePanel>] = []
        if uiState.isPlaylistAvailable {
            tabs.append(
                SidePanelTab(
                    id: PlayerSidePanel.playlist,
                    title: "Playlist",
                    iconName: "list.bullet",
                    badge: playlist.items.isEmpty ? nil : "\(playlist.items.count)",
                    isBusy: playlist.isLoading
                )
            )
        }
        if !engine.media.chapters.isEmpty {
            tabs.append(
                SidePanelTab(
                    id: PlayerSidePanel.chapters,
                    title: "Chapters",
                    iconName: "list.and.film",
                    badge: "\(engine.media.chapters.count)"
                )
            )
        }
        return tabs
    }

    private var headerView: some View {
        SidePanelTabBar(
            tabs: headerTabs,
            selection: isShowingChapters ? .chapters : .playlist,
            onSelect: { uiState.sidePanel = $0 },
            onClose: onClose,
            accessory: {
                if !isShowingChapters {
                    addMenu
                    clearButton
                }
            }
        )
    }

    private var addMenu: some View {
        Menu {
            Button("Add Media Files…") {
                appendInBackground(MediaOpenPanel.promptForMediaFiles())
            }

            Button("Add Folder…") {
                appendInBackground(MediaOpenPanel.promptForMediaFolders())
            }

            Button("Add URL…") {
                isShowingAddURLAlert = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.8))
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add Media to Playlist")
    }

    private var clearButton: some View {
        Button {
            isShowingClearConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .disabled(engine.playlist.items.isEmpty)
        .help("Clear Playlist")
    }

    // MARK: - Sort Controls

    private var sortKeyMenu: some View {
        let playlist = engine.playlist
        return Menu {
            // Toggles rather than a Picker: choosing the current key again must re-sort too
            // (e.g. once more durations are known).
            ForEach(PlaylistSortKey.allCases) { key in
                Toggle(
                    key.rawValue,
                    isOn: Binding(
                        get: { playlist.sortKey == key },
                        set: { _ in playlist.sort(by: key, ascending: playlist.sortAscending) }
                    )
                )
            }
        } label: {
            HStack(spacing: 3) {
                Text(playlist.sortKey.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.white.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort By")
    }

    private var sortDirectionButton: some View {
        let playlist = engine.playlist
        return Button {
            playlist.sort(by: playlist.sortKey, ascending: !playlist.sortAscending)
        } label: {
            Image(systemName: playlist.sortAscending ? "arrow.up" : "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help("Sort \(playlist.sortKey.directionTitle(ascending: playlist.sortAscending))")
    }

    // MARK: - Filter Bar View

    @MainActor
    fileprivate struct SearchBarView: NSViewRepresentable {
        @Binding var text: String
        var prompt: String = "Filter playlist…"

        func makeNSView(context: Context) -> SearchBarContainerView {
            let view = SearchBarContainerView(prompt: prompt)
            view.onTextChanged = { newText in
                text = newText
            }
            return view
        }

        func updateNSView(_ nsView: SearchBarContainerView, context: Context) {
            nsView.onTextChanged = { newText in
                text = newText
            }
            nsView.updateText(text)
            nsView.updatePrompt(prompt)
        }
    }

    @MainActor
    fileprivate final class SearchBarContainerView: NSView, NSTextFieldDelegate {
        private let iconView = NSImageView()
        private let textField = NSTextField()
        private let clearButton = NSButton()
        var onTextChanged: ((String) -> Void)?

        init(prompt: String) {
            super.init(frame: .zero)
            setupViews(prompt: prompt)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(textField)
        }

        private func setupViews(prompt: String) {
            wantsLayer = true

            // Magnifying glass icon
            iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.4)
            iconView.imageScaling = .scaleProportionallyDown
            addSubview(iconView)

            // Left-aligned NSTextField
            textField.isBordered = false
            textField.drawsBackground = false
            textField.focusRingType = .none
            textField.font = .systemFont(ofSize: 12)
            textField.textColor = .white
            textField.placeholderString = prompt
            textField.delegate = self
            textField.maximumNumberOfLines = 1
            textField.cell?.isScrollable = true
            textField.cell?.wraps = false
            textField.lineBreakMode = .byClipping
            addSubview(textField)

            // Clear button (xmark)
            clearButton.bezelStyle = .regularSquare
            clearButton.isBordered = false
            clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
            clearButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
            clearButton.target = self
            clearButton.action = #selector(clearClicked)
            clearButton.isHidden = true
            addSubview(clearButton)
        }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            let h = bounds.height
            let iconSize: CGFloat = 12
            iconView.frame = NSRect(x: 9, y: round((h - iconSize) / 2), width: iconSize, height: iconSize)

            let clearButtonSize: CGFloat = 20
            let clearX = bounds.width - clearButtonSize - 4
            clearButton.frame = NSRect(
                x: clearX, y: round((h - clearButtonSize) / 2), width: clearButtonSize, height: clearButtonSize)

            let textX: CGFloat = 27
            let textRight = clearButton.isHidden ? (bounds.width - 8) : (clearX - 2)
            let textW = max(0, textRight - textX)
            let textH: CGFloat = 16
            let textY = round((h - textH) / 2) + 0.5
            textField.frame = NSRect(x: textX, y: textY, width: textW, height: textH)
        }

        @objc private func clearClicked() {
            textField.stringValue = ""
            clearButton.isHidden = true
            needsLayout = true
            onTextChanged?("")
            window?.makeFirstResponder(textField)
        }

        func updateText(_ text: String) {
            if textField.stringValue != text {
                textField.stringValue = text
            }
            let shouldHide = text.isEmpty
            if clearButton.isHidden != shouldHide {
                clearButton.isHidden = shouldHide
                needsLayout = true
            }
        }

        func updatePrompt(_ prompt: String) {
            if textField.placeholderString != prompt {
                textField.placeholderString = prompt
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            let text = textField.stringValue
            let shouldHide = text.isEmpty
            if clearButton.isHidden != shouldHide {
                clearButton.isHidden = shouldHide
                needsLayout = true
            }
            onTextChanged?(text)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if !textField.stringValue.isEmpty {
                    clearClicked()
                    return true
                } else {
                    window?.makeFirstResponder(nil)
                    return true
                }
            }
            return false
        }
    }

    private var filterBarView: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                SearchBarView(
                    text: Binding(
                        get: { engine.playlist.searchQuery },
                        set: { engine.playlist.searchQuery = $0 }
                    )
                )
                .frame(height: 28)

                if !engine.playlist.searchQuery.isEmpty {
                    Text("\(engine.playlist.filteredItems.count) of \(engine.playlist.items.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.trailing, 6)
                }
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Sort: key menu + direction toggle; either one re-sorts. Shuffle and repeat live in
            // the control bar.
            sortKeyMenu
            sortDirectionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.1))
    }

    // MARK: - Playlist List View

    private var playlistListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(engine.playlist.filteredItems.enumerated()), id: \.element.id) { index, item in
                        PlaylistRowView(
                            item: item,
                            index: index,
                            isCurrent: engine.playlist.currentItem?.id == item.id,
                            isPlaying: engine.isPlaying && engine.playlist.currentItem?.id == item.id,
                            onSelect: {
                                engine.playPlaylistItem(id: item.id)
                            },
                            onRemove: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    engine.removePlaylistItem(id: item.id)
                                }
                            }
                        )
                        .id(item.id)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .onAppear {
                scrollToActiveItem(using: proxy, animated: false)
            }
            .onChange(of: engine.playlist.currentItem?.id) { _, _ in
                scrollToActiveItem(using: proxy, animated: true)
            }
        }
    }

    private func scrollToActiveItem(using proxy: ScrollViewProxy, animated: Bool = false) {
        guard let currentID = engine.playlist.currentItem?.id else { return }
        Task { @MainActor in
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(currentID, anchor: .center)
                }
            } else {
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }

    // MARK: - Empty & Loading States

    private var loadingStateView: some View {
        VStack(spacing: 12) {
            Spacer()

            ProgressView()
                .controlSize(.regular)

            Text("Loading Playlist…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            Text("Fetching and parsing media tracks…")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "play.square.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.3))

            Text("Playlist is Empty")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text("Drag & drop media files or folders here, or click '+' to add.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                let urls = MediaOpenPanel.promptForMediaFiles()
                if !urls.isEmpty {
                    Task { @MainActor in
                        await engine.playlist.appendAsync(urls: urls)
                        if let firstItem = engine.playlist.currentItem {
                            engine.load(item: firstItem)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Add Media")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchStateView: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.3))

            Text("No Matching Items")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text("No tracks found matching \"\(engine.playlist.searchQuery)\"")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Clear Filter") {
                engine.playlist.searchQuery = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer Summary

    private var footerSummaryView: some View {
        HStack {
            if engine.playlist.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    let totalItems = engine.playlist.items.count
                    let itemLabel = totalItems == 1 ? "item" : "items"
                    Text(totalItems > 0 ? "\(totalItems) \(itemLabel) (loading…)" : "Loading…")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                let totalItems = engine.playlist.items.count
                Text("\(totalItems) \(totalItems == 1 ? "item" : "items")")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            let durations = engine.playlist.items.map(\.duration)
            let totalDuration = durations.compactMap(\.self).reduce(0, +)
            if totalDuration > 0 {
                // "≈" while some items (e.g. internet streams, or ones still being looked up) are unknown.
                let isPartial = durations.contains(nil)
                Text((isPartial ? "≈ " : "") + formatDuration(totalDuration))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .help(isPartial ? "Some items' durations are not known yet" : "Total duration")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    // MARK: - Drag & Drop Handling

    private func handleDrop(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        // Subtitle files are no playlist items: they attach to the media playing.
        let (subtitleURLs, mediaURLs) = SubtitleFileDrop.split(urls)
        SubtitleFileDrop.attach(subtitleURLs, to: engine, osd: uiState.osd)
        guard !mediaURLs.isEmpty else { return true }
        AppLog.info(.playlist, "Dropped \(mediaURLs.count) item(s) onto playlist drawer")
        appendInBackground(mediaURLs)
        return true
    }

    /// Folder scans and playlist reads can take seconds on network volumes; keep them off the main actor.
    private func appendInBackground(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            await engine.playlist.appendAsync(urls: urls)
        }
    }
}
