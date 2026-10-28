import AppKit
import NitsCore
import SwiftUI
import UniformTypeIdentifiers

public struct WelcomeView: View {
    public var onOpenFile: () -> Void
    public var onOpenURL: (() -> Void)?
    public var onFileDropped: ((String) -> Void)?
    public var onFilesDropped: (([URL]) -> Void)?
    public var onOpenRecentItem: ((RecentMediaItem) -> Void)?
    public var onClearRecent: (() -> Void)?
    private let isRecentMediaEnabled: (() -> Bool)?

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PlayerConfiguration.keyRememberRecentMedia) private var rememberRecentMedia: Bool = true
    @AppStorage(PlayerConfiguration.keyResumePlayback) private var resumePlayback: Bool = true
    @AppStorage(PlayerConfiguration.keyResumeStartThreshold) private var resumeStartThreshold: Double = 15.0
    @AppStorage(PlayerConfiguration.keyResumeEndThresholdRatio) private var resumeEndThresholdRatio: Double = 0.95

    @FocusState private var isFocused: Bool
    @State private var recentStore = RecentMediaStore.shared
    @State private var isTargetedForDrop: Bool = false
    @State private var selectedItemID: String? = nil
    @State private var hoveredItemID: String? = nil
    @State private var showClearRecentConfirmation: Bool = false
    @State private var displayState: DisplayState = DisplayState(listItems: [])

    public init(
        onOpenFile: @escaping () -> Void,
        onOpenURL: (() -> Void)? = nil,
        onFileDropped: @escaping (String) -> Void,
        isRecentMediaEnabled: (() -> Bool)? = nil
    ) {
        self.onOpenFile = onOpenFile
        self.onOpenURL = onOpenURL
        self.onFileDropped = onFileDropped
        self.onFilesDropped = nil
        self.onOpenRecentItem = nil
        self.onClearRecent = nil
        self.isRecentMediaEnabled = isRecentMediaEnabled
    }

    public init(
        onOpenFile: @escaping () -> Void,
        onOpenURL: (() -> Void)? = nil,
        onFilesDropped: @escaping ([URL]) -> Void,
        onOpenRecentItem: ((RecentMediaItem) -> Void)? = nil,
        onClearRecent: (() -> Void)? = nil,
        isRecentMediaEnabled: (() -> Bool)? = nil
    ) {
        self.onOpenFile = onOpenFile
        self.onOpenURL = onOpenURL
        self.onFileDropped = nil
        self.onFilesDropped = onFilesDropped
        self.onOpenRecentItem = onOpenRecentItem
        self.onClearRecent = onClearRecent
        self.isRecentMediaEnabled = isRecentMediaEnabled
    }

    private var showsRecentList: Bool {
        rememberRecentMedia && (isRecentMediaEnabled?() ?? true) && !recentStore.items.isEmpty
    }

    private struct DisplayState {
        let listItems: [(item: RecentMediaItem, resume: (position: Double, duration: Double)?)]
    }

    private func updateDisplayState() {
        let listItems = recentStore.items.map { item in
            (
                item: item,
                resume: recentStore.resumeInfo(
                    for: item,
                    resumePlayback: resumePlayback,
                    startThreshold: resumeStartThreshold,
                    endThresholdRatio: resumeEndThresholdRatio
                )
            )
        }
        displayState = DisplayState(listItems: listItems)
    }

    public var body: some View {
        ZStack {
            // Adaptive gradient overlay for depth over vibrancy
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black.opacity(0.15), Color.black.opacity(0.35)]
                    : [Color.white.opacity(0.20), Color.black.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .gesture(WindowDragGesture())

            if showsRecentList {
                recentLayout
            } else {
                emptyHeroLayout
            }

            // Drop highlight border
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .frame(width: 560, height: 420)
        .focusable()
        .focused($isFocused)
        .defaultFocus($isFocused, true)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            guard showsRecentList else { return .ignored }
            return navigateSelection(direction: 1) ? .handled : .ignored
        }
        .onKeyPress(.upArrow) {
            guard showsRecentList else { return .ignored }
            return navigateSelection(direction: -1) ? .handled : .ignored
        }
        .onKeyPress(.return) {
            guard showsRecentList else { return .ignored }
            return openSelectedItem() ? .handled : .ignored
        }
        .onKeyPress(.delete) {
            guard showsRecentList else { return .ignored }
            return removeSelectedItem() ? .handled : .ignored
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            if let onFilesDropped {
                onFilesDropped(urls)
            } else if let firstUrl = urls.first {
                onFileDropped?(firstUrl.path)
            }
            return true
        } isTargeted: { targeted in
            isTargetedForDrop = targeted
        }
        .onAppear {
            updateDisplayState()
        }
        .onChange(of: recentStore.progressRevision) { _, _ in
            updateDisplayState()
        }
        .onChange(of: recentStore.items) { _, _ in
            updateDisplayState()
        }
        .onChange(of: rememberRecentMedia) { _, _ in
            updateDisplayState()
        }
        .onChange(of: resumePlayback) { _, _ in
            updateDisplayState()
        }
        .onChange(of: resumeStartThreshold) { _, _ in
            updateDisplayState()
        }
        .onChange(of: resumeEndThresholdRatio) { _, _ in
            updateDisplayState()
        }
        .confirmationDialog(
            "Clear Recent Media List?",
            isPresented: $showClearRecentConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Recent Media", role: .destructive) {
                if let onClearRecent {
                    onClearRecent()
                } else {
                    RecentMediaActions.clearAll()
                }
                selectedItemID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes all recently opened videos."
            )
        }
    }

    // MARK: - Empty Hero Layout (Original)

    private var emptyHeroLayout: some View {
        VStack(spacing: 28) {
            LogoView(theme: .monterey)
                .frame(width: 80, height: 88)

            VStack(spacing: 6) {
                Text("Nits")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Drop video here or open a file to start watching")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Button(action: onOpenFile) {
                    Label("Open File…", systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 120, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: { onOpenURL?() }) {
                    Label("Open URL…", systemImage: "link")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 120, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
    }

    // MARK: - Recent Media Layout

    private var recentLayout: some View {
        VStack(spacing: 14) {
            // Header Bar
            HStack(alignment: .center, spacing: 14) {
                LogoView(theme: .monterey)
                    .frame(width: 44, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Nits")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Drop video here or choose a recent item")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button(action: onOpenFile) {
                        Label("Open File…", systemImage: "folder")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button(action: { onOpenURL?() }) {
                        Label("Open URL…", systemImage: "link")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            // Scrollable Recent List
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(displayState.listItems, id: \.item.historyKey) { row in
                        recentRow(item: row.item, resumeInfo: row.resume)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: - Recent Row

    private func recentRow(item: RecentMediaItem, resumeInfo: (position: Double, duration: Double)?) -> some View {
        let isSelected = selectedItemID == item.historyKey
        let isHovered = hoveredItemID == item.historyKey

        return HStack(spacing: 0) {
            Button {
                openItem(item)
            } label: {
                HStack(spacing: 12) {
                    mediaIcon(for: item)
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let subtitle = item.displaySubtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if let resumeInfo {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(TimeParser.format(seconds: resumeInfo.position))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)

                            if resumeInfo.duration > 0 {
                                ProgressView(value: min(max(resumeInfo.position / resumeInfo.duration, 0), 1))
                                    .progressViewStyle(.linear)
                                    .tint(Color.accentColor)
                                    .frame(width: 48)
                            }
                        }
                    } else if item.duration > 0 {
                        Text(TimeParser.format(seconds: item.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, isHovered ? 4 : 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered {
                Button {
                    recentStore.remove(id: item.historyKey)
                    if selectedItemID == item.historyKey {
                        selectedItemID = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help("Remove from Recent")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.18)
                        : (isHovered ? Color.white.opacity(0.06) : Color.white.opacity(0.03)))
        )
        .onHover { hovering in
            hoveredItemID = hovering ? item.historyKey : nil
        }
        .contextMenu {
            recentContextMenu(for: item)
        }
    }

    // MARK: - Media Icon

    private func mediaIcon(for item: RecentMediaItem) -> some View {
        Image(systemName: Self.mediaSymbolName(for: item))
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
    }

    /// The kind of media, from the URL alone (no file access): a stream, a playlist, audio or video.
    private static func mediaSymbolName(for item: RecentMediaItem) -> String {
        if item.isNetwork {
            return "globe"
        }
        let ext = URL(fileURLWithPath: item.urlString).pathExtension.lowercased()
        if PlaylistManager.playlistExtensions.contains(ext) {
            return "list.bullet"
        }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) {
            return "music.note"
        }
        return "film"
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func recentContextMenu(for item: RecentMediaItem) -> some View {
        Button("Play") {
            openItem(item)
        }

        if !item.isNetwork {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(item.urlString, inFileViewerRootedAtPath: "")
            }
        } else {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.urlString, forType: .string)
            }
        }

        Divider()

        Button("Remove from Recent") {
            recentStore.remove(id: item.historyKey)
            if selectedItemID == item.historyKey {
                selectedItemID = nil
            }
        }

        Button("Clear Recent Media…") {
            showClearRecentConfirmation = true
        }
    }

    // MARK: - Actions & Keyboard Helpers

    private func openItem(_ item: RecentMediaItem) {
        if let onOpenRecentItem {
            onOpenRecentItem(item)
        } else if item.isNetwork, let url = URL(string: item.urlString) {
            onFilesDropped?([url])
        } else {
            onFileDropped?(item.urlString)
        }
    }

    private func allNavigableItems() -> [RecentMediaItem] {
        recentStore.items
    }

    @discardableResult
    private func navigateSelection(direction: Int) -> Bool {
        let items = allNavigableItems()
        guard !items.isEmpty else { return false }

        guard let current = selectedItemID, let currentIndex = items.firstIndex(where: { $0.historyKey == current })
        else {
            selectedItemID = items.first?.historyKey
            return true
        }

        let nextIndex = min(max(currentIndex + direction, 0), items.count - 1)
        selectedItemID = items[nextIndex].historyKey
        return true
    }

    @discardableResult
    private func openSelectedItem() -> Bool {
        let items = allNavigableItems()
        guard !items.isEmpty else { return false }

        if let selected = selectedItemID, let match = items.first(where: { $0.historyKey == selected }) {
            openItem(match)
            return true
        } else if let first = items.first {
            openItem(first)
            return true
        }
        return false
    }

    @discardableResult
    private func removeSelectedItem() -> Bool {
        guard let selected = selectedItemID else { return false }
        recentStore.remove(id: selected)
        selectedItemID = nil
        return true
    }
}
